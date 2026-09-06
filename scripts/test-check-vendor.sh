#!/usr/bin/env bash
# Committed negative control: prove the staleness guard rejects lock-only drift.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pocketforge-vendor-check.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/surface" "$tmp/vendor"
cp "$root/scripts/check-vendor.sh" "$tmp/scripts/"
cp "$root/surface/Cargo.lock" "$tmp/surface/Cargo.lock"
cp "$root/vendor/.pocketforge-vendor-lock" "$tmp/vendor/"
printf '\n# synthetic lock drift\n' >> "$tmp/surface/Cargo.lock"

if "$tmp/scripts/check-vendor.sh" >"$tmp/output" 2>&1; then
  echo "test-check-vendor: synthetic lock drift unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'Cargo.lock changed without a vendor refresh' "$tmp/output" || {
  cat "$tmp/output" >&2
  echo "test-check-vendor: guard failed for the wrong reason" >&2
  exit 1
}
echo "test-check-vendor: synthetic lock drift rejected"
