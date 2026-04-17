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
# Bundle.module inside the app looks them up via Bundle.main.resourceURL,
# so they belong in Contents/Resources/.
shopt -s nullglob
for b in "$BUILD_DIR"/*.bundle; do
    cp -R "$b" "$RESOURCES/"
done
shopt -u nullglob

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

echo "==> ad-hoc sign"
# --force overwrites any existing signature from swift build; --deep walks
# the embedded resource bundles so nothing inside the .app is unsigned
# when Gatekeeper scans it on first run.
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

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
