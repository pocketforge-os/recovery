#!/usr/bin/env bash
# gpu-14: after after-v4.sh (A5b, g1s13, A3-r4, A2b-r6-next) finishes: g2d-r1 live (ec0c5a48), run from its kit dir.
set -u
G=/home/matt/recovery/gpu14
while pgrep -f '^bash /home/matt/recovery/gpu14/after-v4\.sh$' >/dev/null || pgrep -f '^bash /home/matt/recovery/[^ ]*/kits/[^ ]*/direct-boot\.sh' >/dev/null; do sleep 20; done
K=/home/matt/recovery/tsp-mc9m.41.923.56/kits/g2d-r1
want=ec0c5a481f012155ec8abfe650d43f4a1892dd48c9ae9ec70553f331b90afdd9
got=$(sha256sum < $K/SHA256SUMS | cut -c1-64)
[ "$got" = "$want" ] && (cd $K && sha256sum -c --quiet SHA256SUMS) || { echo "$(date -u +%FT%TZ) g2d seal FAILED (got $got)"; exit 1; }
R=/home/matt/recovery/tsp-mc9m.41.923.56/g2d-r1-build3-$(date -u +%Y%m%dT%H%M%SZ); echo "$R" > $G/g2d.current
echo "$(date -u +%FT%TZ) g2d-r1 start R=$R"; echo "$(date -u +%FT%TZ) G2D START (g2d-r1 ec0c5a48) R=$R" >> $G/device-queue.txt
(cd $K && bash ./direct-boot.sh "$R")
echo "$(date -u +%FT%TZ) g2d-r1 $(tail -1 "$R/run.log" 2>/dev/null)"
ls "$R"/felboot/*.json >/dev/null 2>&1 || ls "$R"/felboot/post* >/dev/null 2>&1 || echo "$(date -u +%FT%TZ) CHAIN_WARN name=g2d-r1 reason=no_felboot_posted"
