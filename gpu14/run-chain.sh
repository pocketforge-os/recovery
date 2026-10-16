#!/usr/bin/env bash
# gpu-14: run sealed device kits one after another.
# usage: run-chain.sh name|kitdir|manifest_sha256|pointer_file|receipt_prefix [...]
# Before each kit: wait for no other kit smoke on this host (binfmt race, tsp-mc9m.41.1000.3),
# re-verify the seal, write the pointer, run direct-boot.sh, print its RESULT line.
# The smoke pattern is anchored on "bash <path>/kits/<kit>/smoke.sh" so it never matches this script.
set -u
smoke_running() { pgrep -f '^(/usr/bin/)?bash /home/matt/recovery/[^ ]*/kits/[^ ]*/smoke\.sh' >/dev/null; }
for spec in "$@"; do
  IFS='|' read -r name K want ptr prefix <<<"$spec"
  while smoke_running; do sleep 5; done
  got=$(sha256sum < "$K/SHA256SUMS" | cut -c1-64)
  if [ "$got" != "$want" ] || ! (cd "$K" && sha256sum -c --quiet SHA256SUMS); then
    echo "$(date -u +%FT%TZ) $name seal FAILED (manifest $got); chain stops"; exit 1
  fi
  R="$prefix-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "$R" > "$ptr.new" && mv "$ptr.new" "$ptr"
  echo "$(date -u +%FT%TZ) $name start R=$R"
  bash "$K/direct-boot.sh" "$R"
  echo "$(date -u +%FT%TZ) $name $(tail -1 "$R/run.log" 2>/dev/null)"
done
