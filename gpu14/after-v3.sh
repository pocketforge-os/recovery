#!/usr/bin/env bash
# gpu-14: after after-g1s13-v3.sh (deploy -> A5b -> G2D -> parity-floor) finishes, run g1s13 (rerun), A3-r4, A2b-r6-next.
set -u
G=/home/matt/recovery/gpu14
while pgrep -f '^bash /home/matt/recovery/gpu14/after-g1s13-v3\.sh$' >/dev/null; do sleep 20; done
bash $G/run-chain2.sh \
  "g1s13|/home/matt/recovery/tsp-98733d6399be82e4f00c.5/kits/g1s13|648b08179c98a317efe6582bd819810d78036107e61fdbe7ada8b08567be4e84|$G/g1s13.current|/home/matt/recovery/tsp-98733d6399be82e4f00c.5/g1s13-build3" \
  "a3-r4|/home/matt/recovery/tsp-mc9m.41.1000/kits/a3-r4-omnibus|1c2a438186c0020ce5a71198b7dcca09344d75d80888b3ed0c623713c2845089|$G/wavea-a3.current|/home/matt/recovery/tsp-mc9m.41.1000-a3-r4-build3" \
  "a2b-r6-next|/home/matt/recovery/tsp-mc9m.41.1000/kits/a2b-r6-next|77e6726a1a262b2336d724cd51999fc5d3efd07c90fc83805342d67a84b958ef|$G/wavea-a2b.current|/home/matt/recovery/tsp-mc9m.41.1000-a2b-r6-next-build3"
