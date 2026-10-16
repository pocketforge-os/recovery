#!/usr/bin/env bash
# One-shot gate: halts the queue runner (rc 3) so gpu-14 restarts it on the new code (@R@ args + self re-exec).
echo "RUNNER_HALT_FOR_REEXEC $(date -u +%FT%TZ): restart queue-runner.sh; this row is in queue.done and will not repeat"
exit 3
