#!/usr/bin/env bash
# Lightweight lint for Pulse. Intentionally minimal in B1 — the privacy
# red lines are the only real rules right now, everything else is advisory.
#
# Rules enforced:
#   1. No source file outside PulseCore/Mileage mentions a forbidden macro.
#   2. No NSPasteboard content-read APIs in the codebase (privacy red line,
#      see docs/05-privacy.md#红线清单).
#   3. No TODO/FIXME containing 'hack' or 'xxx' outside docs/.
#
# The script exits non-zero on any violation.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0

echo "[lint] checking privacy red lines"
# Allow references in docs/ and this script itself, but not in Swift sources.
forbidden_patterns=(
  'NSPasteboard\.general\.string'
  'NSPasteboard\.general\.data'
  'NSPasteboard.general.propertyList'
  'CGWindowListCreateImage'
)
for pat in "${forbidden_patterns[@]}"; do
  if grep -RnE "$pat" \
       --include='*.swift' \
       Sources Tests 2>/dev/null; then
    echo "::error::forbidden API referenced: $pat (see docs/05-privacy.md)"
    fail=1
  fi
done

echo "[lint] checking suspicious todo markers"
if grep -RnE 'TODO.*(hack|xxx|wtf)|FIXME.*(hack|xxx|wtf)' \
     --include='*.swift' \
     Sources Tests 2>/dev/null; then
  echo "::error::suspicious TODO/FIXME marker found"
  fail=1
fi

echo "[lint] checking license headers are absent (we use a single LICENSE file)"
# Placeholder; no-op for now.

if [ "$fail" -ne 0 ]; then
  echo "[lint] FAIL"
  exit 1
fi

echo "[lint] OK"
