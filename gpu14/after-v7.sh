#!/usr/bin/env bash
# gpu-14 device queue v7 (2026-10-09 ~05:30Z): after the running g1s13 kit ends:
#   A5b (A-CTS build-3 kit 8178f4e2, pipefail-safe) -> A3-r4 -> A2b-r6-next -> G2D (ec0c5a48) -> A6+A7 (build-4 kit a300c29d, ~8-10 h).
# Each kit is seal-checked on its own; a mismatch skips only that kit (its owner may have resealed).
set -u
G=/home/matt/recovery/gpu14
kit_running() { pgrep -f '^bash (/home/matt/recovery/[^ ]*/kits/[^ ]*/|\./)direct-boot\.sh' >/dev/null; }
seal_ok() { local K=$1 want=$2 mf=${3:-SHA256SUMS}; [ "$(sha256sum < "$K/$mf" | cut -c1-64)" = "$want" ] && (cd "$K" && sha256sum -c --quiet "$mf"); }
note() { echo "$(date -u +%FT%TZ) $*"; echo "$(date -u +%FT%TZ) $*" >> $G/device-queue.txt; }
booted() { ls "$1"/felboot/post* >/dev/null 2>&1 || ls "$1"/felboot/*.json >/dev/null 2>&1 || note "CHAIN_WARN name=$2 reason=no_felboot_posted R=$1"; }
run_kit() {  # name kitdir sha receipt-prefix [args...]
  local name=$1 K=$2 want=$3 prefix=$4; shift 4
  while kit_running; do sleep 20; done
  seal_ok "$K" "$want" || { note "SKIP $name: seal mismatch (want ${want:0:8}); owner may have resealed"; return; }
  local R="$prefix-$(date -u +%Y%m%dT%H%M%SZ)"
  note "$name START R=$R"
  (cd "$K" && bash ./direct-boot.sh "$R" "$@")
  note "$name $(tail -1 "$R/run.log" 2>/dev/null)"
  booted "$R" "$name"
}
run_kit a5b /home/matt/recovery/tsp-mc9m.41.924.24.14/kits/a-cts 8178f4e25a2bccfadc33fa96130a4c5bb7182bf8a93ec8b80aae5941588952ad /home/matt/recovery/tsp-mc9m.41.924.24.14/a5b-build3r33 --caselist ./a5b-recovery-cases-r26.txt
run_kit a3-r4 /home/matt/recovery/tsp-mc9m.41.1000/kits/a3-r4-omnibus 1c2a438186c0020ce5a71198b7dcca09344d75d80888b3ed0c623713c2845089 /home/matt/recovery/tsp-mc9m.41.1000-a3-r4-build3
run_kit a2b-r6-next /home/matt/recovery/tsp-mc9m.41.1000/kits/a2b-r6-next 77e6726a1a262b2336d724cd51999fc5d3efd07c90fc83805342d67a84b958ef /home/matt/recovery/tsp-mc9m.41.1000-a2b-r6-next-build3
run_kit g2d-r1 /home/matt/recovery/tsp-mc9m.41.923.56/kits/g2d-r1 ec0c5a481f012155ec8abfe650d43f4a1892dd48c9ae9ec70553f331b90afdd9 /home/matt/recovery/tsp-mc9m.41.923.56/g2d-r1-build3
run_kit a6a7 /home/matt/recovery/tsp-mc9m.41.924.24.14/kits/a-cts-build4-a6a7 a300c29de1248b0c236059d406c84394f1171fbfbd49ed42c93ad0310c72c17c /home/matt/recovery/tsp-mc9m.41.924.24.14/a6a7-build4 --list gles31-main --list gles31-multisample --list gles3-multisample --list gles2-khr-main --list gles3-khr-main --list gles31-khr-main --list gles32-khr-main --list gles32-khr-glesext --list gles32-khr-single --list noctx
note "QUEUE v7 done"
