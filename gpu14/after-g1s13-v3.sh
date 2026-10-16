#!/usr/bin/env bash
# gpu-14: after g1s13 ends: deploy test-node-farm c13b4a5e (self-refusing preflight), then
# A-CTS A5b (resealed fc1b2e4b), then G2D and parity-floor. v3: waits for the stale capture mutex.
set -u
G=/home/matt/recovery/gpu14
kit_running() { pgrep -f '^bash /home/matt/recovery/[^ ]*/kits/[^ ]*/direct-boot\.sh' >/dev/null; }
while kit_running || pgrep -f 'run-chain2\.sh' >/dev/null; do sleep 15; done
# The A3-r4 capture-boot started 04:02:06Z (2400 s) holds the console-ops per-DUT mutex server-side
# even after its client was killed (tsp-mc9m.41.984.80 item 3); do not touch the device before it expires.
until [ "$(date -u +%s)" -ge "$(date -u -d 2026-10-09T04:43:30Z +%s)" ]; do sleep 15; done
echo "$(date -u +%FT%TZ) deploy c13b4a5e start"
/home/matt/recovery/tsp-mc9m.41.1002/deploy-c13b4a5e.sh --deploy; rc=$?
echo "$(date -u +%FT%TZ) deploy c13b4a5e rc=$rc"; echo "$(date -u +%FT%TZ) DEPLOY tnf c13b4a5e rc=$rc" >> $G/device-queue.txt
[ "$rc" -eq 0 ] || { echo "deploy failed; device chain NOT started"; exit 1; }
K=/home/matt/recovery/tsp-mc9m.41.924.24.14/kits/a-cts
want=fc1b2e4bcd3a1a34c30b0c8108b69934349fe8d5e995fdc07bda82fe83442975
got=$(sha256sum < $K/SHA256SUMS | cut -c1-64)
if [ "$got" = "$want" ] && (cd $K && sha256sum -c --quiet SHA256SUMS); then
  R=/home/matt/recovery/tsp-mc9m.41.924.24.14/a5b-build3r30-$(date -u +%Y%m%dT%H%M%SZ); echo "$R" > $G/acts.current
  echo "$(date -u +%FT%TZ) A5b start R=$R"; echo "$(date -u +%FT%TZ) A5b START (A-CTS fc1b2e4b) R=$R" >> $G/device-queue.txt
  (cd $K && bash $K/direct-boot.sh "$R" --caselist ./a5b-recovery-cases-r26.txt)
  echo "$(date -u +%FT%TZ) A5b $(tail -1 "$R/run.log" 2>/dev/null)"
else
  echo "$(date -u +%FT%TZ) A-CTS seal FAILED (got $got); skipping A5b"
fi
bash $G/run-chain2.sh \
  "g2d-r1|/home/matt/recovery/tsp-mc9m.41.923.56/kits/g2d-r1|5463df8939e043c75bbbe30eea4eaee728eed2fbb9d39d06026d62d8a2117147|$G/g2d.current|/home/matt/recovery/tsp-mc9m.41.923.56/g2d-r1-build3" \
  "parity-floor|/home/matt/recovery/tsp-mc9m.41.1009.4/kits/parity-floor|2d839212810511ada3d96072f18a940ab8a7bd8930a21cb6bb67e5aa02c4fcc7|$G/parity-floor.current|/home/matt/recovery/tsp-mc9m.41.1009.4/parity-floor-build3|kit-files.sha256"
