#!/usr/bin/env bash
# Package PulseApp into an ad-hoc-signed .app bundle suitable for local
# development on the builder's own Mac. No Apple Developer account
# required; macOS will still prompt for Input Monitoring + Accessibility
# the first time the bundle runs (signed identity is stable across
# rebuilds as long as the bundle id stays the same).
#
# Usage:
#   scripts/package.sh                    # release, native arch
#   CONFIG=debug scripts/package.sh       # debug build (faster iteration)
#   UNIVERSAL=1 scripts/package.sh        # arm64 + x86_64 fat binary
#   VERSION=1.0.0-rc2 scripts/package.sh  # override marketing version
#
# Output: dist/Pulse.app
#
# First-run gatekeeper dance:
#   1. Finder → right-click Pulse.app → Open → "Open" to bypass the
#      quarantine prompt once. Subsequent launches work normally.
#   2. Grant Input Monitoring + Accessibility when the app asks. The
#      recovery assistant inside the app deep-links into the right
#      System Settings panes.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: scripts/package.sh must run on macOS (needs codesign + swift)." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
UNIVERSAL="${UNIVERSAL:-0}"
APP_NAME="Pulse"
EXEC_NAME="PulseApp"
BUNDLE_ID="${BUNDLE_ID:-dev.pulse.Pulse}"
VERSION="${VERSION:-1.0.0-rc1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

BUILD_ARGS=(-c "$CONFIG")
if [[ "$UNIVERSAL" == "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"

BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
if [[ ! -x "$BUILD_DIR/$EXEC_NAME" ]]; then
    echo "error: expected executable at $BUILD_DIR/$EXEC_NAME" >&2
    exit 1
fi

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> clean $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

echo "==> copy executable"
cp "$BUILD_DIR/$EXEC_NAME" "$MACOS/$EXEC_NAME"
chmod +x "$MACOS/$EXEC_NAME"

echo "==> copy resource bundles"
# SPM emits <PackageName>_<TargetName>.bundle next to the executable.
# Canonical location inside an .app is Contents/Resources/. Our own
# `Bundle.pulse` accessor (Sources/*/ResourceBundle.swift) is what
# looks these up at runtime, intentionally replacing SPM's auto-
# generated `Bundle.module` — the latter ships an accessor that only
# probes `Bundle.main.bundleURL/<name>.bundle` + a hardcoded CI build
# path, neither of which exists inside a shipped .app. dev-latest 111
# crashed on launch with exactly that fatalError; see git log for
# details.
shopt -s nullglob
for b in "$BUILD_DIR"/*.bundle; do
    cp -R "$b" "$RESOURCES/"
done
shopt -u nullglob

echo "==> compile xcstrings into per-language .lproj"
# SPM's resource pipeline COPIES `.xcstrings` files into the bundle
# verbatim instead of compiling them into per-language
# `<lang>.lproj/Localizable.strings`. The runtime `NSBundle` lookup
# only consults `.strings` / `.stringsdict` files — `.xcstrings` is
# inert at runtime — so without this step zh-Hans translations never
# reach the user, and dot-separated keys like
# `mileage.comparison.multi` leak through as raw strings on the
# Dashboard. Run Xcode's `xcstringstool` to generate the tables that
# SPM should have generated.
#
# Idempotent: if SPM ever starts compiling xcstrings itself, this loop
# becomes a no-op (the `.xcstrings` file is gone, the loop body is
# skipped).
shopt -s nullglob
for bundle in "$RESOURCES"/*.bundle; do
    xcs="$bundle/Localizable.xcstrings"
    if [[ -f "$xcs" ]]; then
        echo "    compiling: $xcs"
        # `xcrun xcstringstool compile` writes one `Localizable.strings`
        # per declared language under matching `.lproj` directories.
        # Output dir is the bundle root — same layout the runtime
        # NSBundle expects.
        xcrun xcstringstool compile "$xcs" -o "$bundle"
        # The .xcstrings itself isn't useful at runtime; remove it so
        # the bundle stays small and doesn't ship the source catalog.
        rm -f "$xcs"
    fi
done
shopt -u nullglob

echo "==> verify each resource bundle carries the declared localizations"
# Hard-fail if any expected `<lang>.lproj/Localizable.strings` is
# missing. Catches both the pre-fix bug ("xcstrings not compiled at
# all") and any future regression where xcstringstool stops emitting
# a language we declared.
expected_langs=(en zh-Hans)
shopt -s nullglob
for bundle in "$RESOURCES"/*.bundle; do
    # Only check bundles that actually carry a strings catalog.
    if compgen -G "$bundle"/*.lproj/Localizable.strings >/dev/null \
        || compgen -G "$bundle"/*.lproj/Localizable.stringsdict >/dev/null; then
        for lang in "${expected_langs[@]}"; do
            file="$bundle/$lang.lproj/Localizable.strings"
            if [[ ! -f "$file" ]]; then
                echo "error: missing $file" >&2
                exit 1
            fi
        done
    fi
done
shopt -u nullglob

echo "==> embed Sparkle.framework"
# Sparkle ships as a binary `.xcframework` via SPM. `swift build` writes
# the framework into its artifacts cache and links the executable with
# an `@rpath/Sparkle.framework/…` load command, but it does **not**
# copy the framework next to the executable — so a bare `swift run`
# works (SPM patches DYLD_FRAMEWORK_PATH at launch), but a standalone
# `.app` bundle crashes immediately because dyld can't resolve the
# framework. Fix: copy the right slice into `Contents/Frameworks/`
# and ensure the executable has `@executable_path/../Frameworks` in
# its rpath list before the ad-hoc codesign at the bottom of this
# script seals everything in.
FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS"
# The xcframework layout puts each arch slice in its own subdir. For
# Sparkle 2.5+ the combined fat slice lives at
# `macos-arm64_x86_64/Sparkle.framework`. Fall back to any macos-*
# slice so this survives Sparkle reshipping a split-slice layout.
sparkle_fw=""
if [[ -d "$ROOT/.build/artifacts" ]]; then
    sparkle_fw=$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos-arm64_x86_64*' 2>/dev/null | head -1)
    if [[ -z "$sparkle_fw" ]]; then
        sparkle_fw=$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)
    fi
fi
if [[ -z "$sparkle_fw" || ! -d "$sparkle_fw" ]]; then
    echo "error: Sparkle.framework not found under .build/artifacts/; did SPM resolve Sparkle? Try 'swift package resolve'." >&2
    exit 1
fi
echo "    source: $sparkle_fw"
# Preserve the Versions/A + Current symlink structure — ditto is the
# Apple-recommended copy tool for .framework because it keeps the
# extended attributes, ad-hoc codesign state, and symlinks intact.
ditto "$sparkle_fw" "$FRAMEWORKS/Sparkle.framework"

# SPM-linked executables get a @loader_path rpath into SPM's own
# artifact cache but not the Frameworks dir of a .app. Add one.
# Idempotent — install_name_tool errors harmlessly on duplicate add,
# so the grep guard keeps repeat runs clean.
if ! otool -l "$MACOS/$EXEC_NAME" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS/$EXEC_NAME" 2>/dev/null || true
fi

echo "==> generate + embed app icon"
# Every build regenerates the .icns so a palette tweak in
# scripts/generate-icon.swift propagates on the very next run without
# anyone having to remember to commit a binary blob.
swift "$ROOT/scripts/generate-icon.swift"
iconutil -c icns "$ROOT/apple/Pulse.iconset" -o "$ROOT/apple/Pulse.icns"
cp "$ROOT/apple/Pulse.icns" "$RESOURCES/Pulse.icns"

echo "==> write Info.plist"
python3 - "$ROOT/apple/Info.plist" "$CONTENTS/Info.plist" \
    "$APP_NAME" "$EXEC_NAME" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" <<'PY'
import sys, pathlib
src, dst, name, exec_, bundle_id, version, build = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = (text.replace("__NAME__", name)
            .replace("__EXEC__", exec_)
            .replace("__BUNDLE_ID__", bundle_id)
            .replace("__VERSION__", version)
            .replace("__BUILD__", build))
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY

echo "==> ad-hoc sign (pass 1: deep-seal helpers + frameworks)"
# --force overwrites any existing signature from swift build; --deep walks
# the embedded resource bundles so nothing inside the .app is unsigned
# when Gatekeeper scans it on first run.
codesign --force --deep --sign - --timestamp=none "$APP"

echo "==> ad-hoc sign (pass 2: outer bundle w/ stable designated requirement)"
# macOS TCC (Input Monitoring / Accessibility grants) identifies an app by
# its designated requirement (DR). The ad-hoc codesign default DR is
#   identifier "dev.pulse.Pulse" and cdhash H"…"
# where cdhash hashes the executable. Every rebuild produces a different
# cdhash, so every Sparkle update looks like a new app to TCC and wipes
# the user's grants — forcing them to re-authorize Input Monitoring and
# Accessibility each time.
#
# Fix: re-sign the outer bundle with an identifier-only DR. TCC then
# matches on bundle id alone and grants survive updates.
#
# Trade-off: any ad-hoc signed binary declaring the same bundle id can
# match this DR too. Acceptable until we get a Developer ID cert — at
# which point codesign will automatically add an `anchor apple generic`
# + team-id clause that only real Pulse builds can satisfy, closing the
# hole without any further code change here.
#
# Timing note: this only helps for the *next* update onward. TCC already
# has a cdhash-bound DR recorded for previously installed versions, so
# the first update that lands this change will still prompt for re-auth;
# from then on grants persist.
codesign --force \
    --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" \
    --sign - \
    --timestamp=none \
    "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> verify designated requirement is identifier-only"
# Hard-fail if the DR ever drifts back to including cdhash — the whole
# point of pass 2 is that `codesign -d -r -` reports exactly:
#   designated => identifier "dev.pulse.Pulse"
# If a future edit drops `-r=…`, this check catches it before the
# broken bundle ships and silently resets everyone's permissions.
dr_line=$(codesign --display --requirements - "$APP" 2>&1 | awk '/^designated =>/ {print; exit}')
expected="designated => identifier \"$BUNDLE_ID\""
if [[ "$dr_line" != "$expected" ]]; then
    echo "error: designated requirement drifted — TCC will reset on update" >&2
    echo "  got:      $dr_line" >&2
    echo "  expected: $expected" >&2
    exit 1
fi

cat <<EOF

Built: $APP

Run it:
  open "$APP"

If macOS blocks first launch with "Apple cannot check it for malicious
software", right-click the app in Finder and choose Open → Open once.
From then on, normal double-click works.

To nuke the Gatekeeper quarantine flag non-interactively:
  xattr -dr com.apple.quarantine "$APP"
EOF
