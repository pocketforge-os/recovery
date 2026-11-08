# gpu14

## Mirrored from pocketforge-automation

These files are copies of pocketforge-automation `scripts/coord/` files. Their tests live there, not here.
Change them in automation first, then copy the bytes here.

| File | Automation source | Blob | State (verified 2026-11-08) |
| --- | --- | --- | --- |
| `window-close.sh` | `scripts/coord/window-close.sh` | `74b7e74674250249ed995610ce27ba360cfb1a44` | identical to automation main `766e7d381` |
| `window-queue.sh` | `scripts/coord/window-queue.sh` | `a74eed67b91ccfdbfe8590e8560a6355f0147cb6` | identical to automation main `766e7d381` |

The recovery copies of their tests (`gpu14/tests/window-close-auto-test.sh`, `gpu14/tests/window-queue-test.sh`) pinned the
10-16..10-20 pre-fork behaviour and were retired on 2026-11-08 (tsp-6ae92df428b96774b063). Automation tests: `scripts/coord/tests/test-window-close-auto-first-step.sh`, `scripts/coord/tests/test-window-queue-*.sh`,
`scripts/tests/pf-window-queue-order-test.py`, `scripts/tests/pf-window-throughput-test.py`.
