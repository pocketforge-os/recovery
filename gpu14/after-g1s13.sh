#!/usr/bin/env bash
# gpu-14: after g1s13 ends, deploy test-node-farm c13b4a5e to pf-node-01 (its own preflight refuses
# while a device task/place/console connection is active), then run G2D and parity-floor.
set -u
G=/home/matt/recovery/gpu14
kit_running() { pgrep -f '^bash /home/matt/recovery/[^ ]*/kits/[^ ]*/direct-boot\.sh' >/dev/null; }
while kit_running || pgrep -f 'run-chain2\.sh' >/dev/null; do sleep 15; done
echo "$(date -u +%FT%TZ) deploy c13b4a5e start"
/home/matt/recovery/tsp-mc9m.41.1002/deploy-c13b4a5e.sh --deploy; rc=$?
echo "$(date -u +%FT%TZ) deploy c13b4a5e rc=$rc"
echo "$(date -u +%FT%TZ) DEPLOY tnf c13b4a5e rc=$rc" >> $G/device-queue.txt
[ "$rc" -eq 0 ] || { echo "deploy failed; device chain NOT started"; exit 1; }
bash $G/run-chain2.sh \
  "g2d-r1|/home/matt/recovery/tsp-mc9m.41.923.56/kits/g2d-r1|5463df8939e043c75bbbe30eea4eaee728eed2fbb9d39d06026d62d8a2117147|$G/g2d.current|/home/matt/recovery/tsp-mc9m.41.923.56/g2d-r1-build3" \
  "parity-floor|/home/matt/recovery/tsp-mc9m.41.1009.4/kits/parity-floor|2d839212810511ada3d96072f18a940ab8a7bd8930a21cb6bb67e5aa02c4fcc7|$G/parity-floor.current|/home/matt/recovery/tsp-mc9m.41.1009.4/parity-floor-build3|kit-files.sha256"
