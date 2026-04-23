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
#   MIN_MAC         — "14.0" default, matches Info.plist LSMinimumSystemVersion
#   CHANNEL         — "stable" (default) or "dev". See "Channels" below.
#
# Channels:
# -----------------------------------------------------------------------
# Pulse uses **two separate feed URLs** rather than a single appcast with
# `<sparkle:channel>` filter tags. History of the channel-tag approach:
# pre-v1.1.6 appcasts emitted `<sparkle:channel>stable</sparkle:channel>`
# on every item, and because no client shipped with a matching
# `SUAllowedChannels` / `allowedChannels(for:)` declaration, every
# release was silently skipped — the "you're on the latest" dialog at
# 1.1.4 → 1.1.5 was this bug. The 1.1.6 fix stripped channel tags
# entirely.
#
# To avoid re-stepping into that trap the dev channel now lives on its
# own feed URL (`releases/download/dev-latest/appcast.xml`), selected
# client-side by `SPUUpdaterDelegate.feedURLString(for:)` when the user
# opts into dev builds. That means:
#   - CHANNEL=stable → enclosure points at the tagged release zip; no
#     `<sparkle:channel>` tag emitted. Visible to every client, exactly
#     like the pre-channel flow.
#   - CHANNEL=dev    → enclosure points at the rolling `dev-latest`
#     release zip. A `<sparkle:channel>dev</sparkle:channel>` tag is
#     emitted as defensive signposting even though this appcast lives
#     on a separate URL — it prevents a client that accidentally points
#     at the dev feed from mistaking a dev build for a stable one.
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

MIN_MAC="${MIN_MAC:-14.0}"
CHANNEL="${CHANNEL:-stable}"

pub_date="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"
case "$CHANNEL" in
    stable)
        # Stable items sit on each vX.Y.Z release. No channel tag — old
        # clients without SUAllowedChannels still see them.
        enclosure_url="https://github.com/${REPO}/releases/download/v${VERSION}/${ZIP_NAME}"
        release_notes_url="https://github.com/${REPO}/releases/tag/v${VERSION}"
        item_title="Version ${VERSION}"
        channel_tag=""
        ;;
    dev)
        # Dev items live on the rolling `dev-latest` release. ZIP_NAME
        # is "Pulse.zip" (stable filename, see PR #83) so the URL is
        # bookmarkable across merges.
        enclosure_url="https://github.com/${REPO}/releases/download/dev-latest/${ZIP_NAME}"
        release_notes_url="https://github.com/${REPO}/releases/tag/dev-latest"
        item_title="Dev ${VERSION}"
        channel_tag="      <sparkle:channel>dev</sparkle:channel>"
        ;;
    *)
        echo "generate_appcast.sh: unknown CHANNEL=${CHANNEL} (expected stable|dev)" >&2
        exit 1
        ;;
esac

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pulse</title>
    <link>https://github.com/${REPO}</link>
    <description>Pulse — local-first macOS self-tracking app.</description>
    <language>en</language>
    <item>
      <title>${item_title}</title>
${channel_tag:+${channel_tag}
}      <sparkle:version>${BUILD}</sparkle:version>
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
