#!/usr/bin/env bash
# gpu-14: after after-v5.sh (G2D) finishes: A6+A7 in ONE boot on CTS build 4 (kit c993a290, no lib workaround). ~8-10 h.
set -u
G=/home/matt/recovery/gpu14
while pgrep -f '^bash /home/matt/recovery/gpu14/after-v[45]\.sh$' >/dev/null || pgrep -f '^bash /home/matt/recovery/[^ ]*/kits/[^ ]*/direct-boot\.sh' >/dev/null || pgrep -f '^bash \./direct-boot\.sh' >/dev/null; do sleep 30; done
K=/home/matt/recovery/tsp-mc9m.41.924.24.14/kits/a-cts-build4-a6a7
want=c993a290a70072e70758239f6782bfbf402643c281124da955c210b321e1ae76
got=$(sha256sum < $K/SHA256SUMS | cut -c1-64)
[ "$got" = "$want" ] && (cd $K && sha256sum -c --quiet SHA256SUMS) || { echo "$(date -u +%FT%TZ) A6A7 seal FAILED (got $got)"; exit 1; }
R=/home/matt/recovery/tsp-mc9m.41.924.24.14/a6a7-build4-$(date -u +%Y%m%dT%H%M%SZ); echo "$R" > $G/acts.current
echo "$(date -u +%FT%TZ) A6A7 start R=$R"; echo "$(date -u +%FT%TZ) A6+A7 START (build 4 kit c993a290, 62317 cases, ~8-10 h) R=$R" >> $G/device-queue.txt
(cd $K && bash ./direct-boot.sh "$R" --list gles31-main --list gles31-multisample --list gles3-multisample --list gles2-khr-main --list gles3-khr-main --list gles31-khr-main --list gles32-khr-main --list gles32-khr-glesext --list gles32-khr-single --list noctx)
echo "$(date -u +%FT%TZ) A6A7 $(tail -1 "$R/run.log" 2>/dev/null)"
ls "$R"/felboot/post* >/dev/null 2>&1 || echo "$(date -u +%FT%TZ) CHAIN_WARN name=a6a7 reason=no_felboot_posted"
