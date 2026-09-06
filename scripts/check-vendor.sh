#!/usr/bin/env bash
# Fail when Cargo.lock and the committed Cargo vendor tree are not one atomic input.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

marker=vendor/.pocketforge-vendor-lock
test -f "$marker" || { echo "check-vendor: missing $marker; run scripts/refresh-vendor.sh" >&2; exit 1; }

want="$(sed -n 's/^cargo_lock_sha256=//p' "$marker")"
have="$(sha256sum surface/Cargo.lock | cut -d' ' -f1)"
test -n "$want" || { echo "check-vendor: marker has no Cargo.lock hash" >&2; exit 1; }
test "$have" = "$want" || {
  echo "check-vendor: Cargo.lock changed without a vendor refresh" >&2
  echo "check-vendor: run scripts/refresh-vendor.sh" >&2
  exit 1
}

cargo metadata --manifest-path surface/Cargo.toml --offline --locked --format-version 1 >/dev/null
echo "check-vendor: vendor tree matches Cargo.lock"
