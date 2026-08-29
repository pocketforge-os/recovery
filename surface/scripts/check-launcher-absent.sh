#!/bin/sh
set -eu
manifest_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
metadata=$(cargo metadata --locked --format-version 1 --manifest-path "$manifest_dir/Cargo.toml")
if printf '%s\n' "$metadata" | grep -E '"name":"[^"]*(launcher|theme)[^"]*"' >/dev/null; then
  echo "FAIL: launcher/theme package present in recovery dependency graph" >&2
  exit 1
fi
echo "PASS: recovery dependency graph contains no launcher or theme package"
