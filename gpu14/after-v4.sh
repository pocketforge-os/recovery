#!/usr/bin/env bash
# gpu-14: after after-g1s13-v3.sh (parity-floor) finishes: A5b (A-CTS e8a4f711, locale-pinned), then g1s13 rerun, A3-r4, A2b-r6-next.
set -u
G=/home/matt/recovery/gpu14
while pgrep -f '^bash /home/matt/recovery/gpu14/after-g1s13-v3\.sh$' >/dev/null || pgrep -f '^bash /home/matt/recovery/[^ ]*/kits/[^ ]*/direct-boot\.sh' >/dev/null; do sleep 20; done
K=/home/matt/recovery/tsp-mc9m.41.924.24.14/kits/a-cts
want=e8a4f7118274e0bee372a585abb4767eeb1995cb493ec1ad186073723482523e
got=$(sha256sum < $K/SHA256SUMS | cut -c1-64)
if [ "$got" = "$want" ] && (cd $K && sha256sum -c --quiet SHA256SUMS); then
  R=/home/matt/recovery/tsp-mc9m.41.924.24.14/a5b-build3r31-$(date -u +%Y%m%dT%H%M%SZ); echo "$R" > $G/acts.current
  echo "$(date -u +%FT%TZ) A5b start R=$R"; echo "$(date -u +%FT%TZ) A5b START (A-CTS e8a4f711) R=$R" >> $G/device-queue.txt
  (cd $K && bash $K/direct-boot.sh "$R" --caselist ./a5b-recovery-cases-r26.txt)
  echo "$(date -u +%FT%TZ) A5b $(tail -1 "$R/run.log" 2>/dev/null)"
  ls "$R"/felboot/post* >/dev/null 2>&1 || echo "$(date -u +%FT%TZ) CHAIN_WARN name=a5b reason=no_felboot_posted"
else
  echo "$(date -u +%FT%TZ) A-CTS seal FAILED (got $got); skipping A5b"
fi
bash $G/run-chain3.sh \
  "g1s13|/home/matt/recovery/tsp-98733d6399be82e4f00c.5/kits/g1s13|648b08179c98a317efe6582bd819810d78036107e61fdbe7ada8b08567be4e84|$G/g1s13.current|/home/matt/recovery/tsp-98733d6399be82e4f00c.5/g1s13-build3" \
  "a3-r4|/home/matt/recovery/tsp-mc9m.41.1000/kits/a3-r4-omnibus|1c2a438186c0020ce5a71198b7dcca09344d75d80888b3ed0c623713c2845089|$G/wavea-a3.current|/home/matt/recovery/tsp-mc9m.41.1000-a3-r4-build3" \
  "a2b-r6-next|/home/matt/recovery/tsp-mc9m.41.1000/kits/a2b-r6-next|77e6726a1a262b2336d724cd51999fc5d3efd07c90fc83805342d67a84b958ef|$G/wavea-a2b.current|/home/matt/recovery/tsp-mc9m.41.1000-a2b-r6-next-build3"
