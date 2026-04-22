#!/usr/bin/env bash
# Package dist/Pulse.app into a DMG ready for GitHub Release upload.
# The produced image opens to a tiny Finder window containing
# `Pulse.app` and a symlink to `/Applications`, so users drag the
# app across — the canonical Mac install affordance.
#
# Runs on macOS only (needs hdiutil). Called from
# `.github/workflows/package.yml` after `scripts/package.sh` has
# already produced `dist/Pulse.app`.
#
# Usage:
#   bash scripts/build_dmg.sh           # uses dist/Pulse.app + VERSION=1.0.0
#   VERSION=1.2.3 bash scripts/build_dmg.sh
#
# Output:
#   dist/Pulse-<version>.dmg
#   dist/Pulse-<version>.dmg.sha256
#
# Sparkle notes: appcast.xml still references the .zip asset for
# auto-update — DMG is for first-install only. Sparkle can handle
# DMG updates, but .zip is simpler + faster for the
# download-and-replace path. See scripts/generate_appcast.sh and
# the `Sign update zip` step in package.yml for the update flow.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: build_dmg.sh must run on macOS (needs hdiutil)." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Pulse"
VERSION="${VERSION:-1.0.0}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

if [[ ! -d "$APP" ]]; then
    echo "error: expected $APP — run scripts/package.sh first." >&2
    exit 1
fi

DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG="$DIST/$DMG_NAME"
VOLNAME="$APP_NAME $VERSION"

# Stage a clean directory holding exactly what we want on the
# mounted image — the .app + an `Applications` symlink. The symlink
# is what turns the mounted DMG into a one-drag install.
STAGE="$(mktemp -d -t pulse-dmg-stage)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> stage contents for DMG"
# `ditto` preserves extended attributes (including the ad-hoc
# codesign signature) that a naive `cp -R` would strip.
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG_NAME"
# UDZO = compressed read-only, the standard format for distributed
# DMGs. `-ov` overwrites any previous build so this script is
# idempotent. No `-fs` flag so hdiutil picks APFS/HFS+ based on the
# host macOS.
rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -quiet \
    "$DMG"

echo "==> sha256"
cd "$DIST"
shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256"

cat <<EOF

Built: $DMG

Install flow (for testers):
  1. Double-click $DMG_NAME — Finder mounts it as "$VOLNAME".
  2. Drag Pulse.app onto the Applications symlink.
  3. Eject the mounted volume.
  4. First open: right-click /Applications/Pulse.app → Open → Open
     (ad-hoc signing, Gatekeeper still complains on first launch).
EOF
