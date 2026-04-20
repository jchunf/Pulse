#!/usr/bin/env bash
# Emits a one-item Sparkle appcast.xml to stdout.
#
# Designed to be called from `.github/workflows/package.yml` after
# `sign_update` has produced the EdDSA attributes string. Every
# input is passed through an environment variable so CI can pipeline
# this cleanly without shell-escaping quirks.
#
# Required env vars:
#   VERSION         — semver shortVersionString (e.g. "1.0.0")
#   BUILD           — numeric build / revision; Sparkle uses this for
#                     "is newer" comparison. GITHUB_RUN_NUMBER works.
#   ZIP_NAME        — filename of the signed .zip release asset
#   SIGN_ATTRIBUTES — raw output of `sign_update`, e.g.
#                     'sparkle:edSignature="…" length="…"'
#   REPO            — GitHub slug owner/repo, used to build the
#                     enclosure URL that points at the release asset.
#
# Optional:
#   CHANNEL         — "stable" by default; fills <sparkle:channel>
#   MIN_MAC         — "14.0" default, matches Info.plist LSMinimumSystemVersion
#
# The appcast intentionally only carries one <item>: the release that
# just built. Sparkle clients pick the newest `sparkle:version` they
# can install, so yesterday's item doesn't need to live in the same
# XML — GitHub Releases already holds the history.

set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${BUILD:?BUILD is required}"
: "${ZIP_NAME:?ZIP_NAME is required}"
: "${SIGN_ATTRIBUTES:?SIGN_ATTRIBUTES is required}"
: "${REPO:?REPO is required}"

CHANNEL="${CHANNEL:-stable}"
MIN_MAC="${MIN_MAC:-14.0}"

pub_date="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"
enclosure_url="https://github.com/${REPO}/releases/download/v${VERSION}/${ZIP_NAME}"
release_notes_url="https://github.com/${REPO}/releases/tag/v${VERSION}"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pulse</title>
    <link>https://github.com/${REPO}</link>
    <description>Pulse — local-first macOS self-tracking app.</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:channel>${CHANNEL}</sparkle:channel>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_MAC}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${release_notes_url}</sparkle:releaseNotesLink>
      <pubDate>${pub_date}</pubDate>
      <enclosure url="${enclosure_url}"
                 type="application/octet-stream"
                 ${SIGN_ATTRIBUTES} />
    </item>
  </channel>
</rss>
XML
