# gpu14

## Mirrored from pocketforge-automation

These files are copies of pocketforge-automation `scripts/coord/` files. Their tests live there, not here.
Change them in automation first, then copy the bytes here.

| File | Automation source | Blob | State (verified 2026-11-08) |
| --- | --- | --- | --- |
| `window-close.sh` | `scripts/coord/window-close.sh` | `74b7e74674250249ed995610ce27ba360cfb1a44` | identical to automation main `766e7d381` |
| `window-queue.sh` | `scripts/coord/window-queue.sh` | `2635b83e4a5fb5bf65b17c41f67f0d16eea372a8` | identical to automation `9beeabb19`; main `766e7d381` has two later commits (`68134091e`, `e06b5b011`) not copied here |

Automation tests: `scripts/coord/tests/test-window-close-auto-first-step.sh`, `scripts/coord/tests/test-window-queue-*.sh`,
`scripts/tests/pf-window-queue-order-test.py`, `scripts/tests/pf-window-throughput-test.py`.
