#!/usr/bin/env bash
# gpu-14 (2026-09-28): restart ONE managed run's controller that is dead or was TERM'd.
# This is for runs NOT enrolled for pf-task-recover (recover would not bring them back).
# The argv comes from pf-task's own native.launch_environment(), the same forwarding the
# launcher uses. The tmux session name is <run>-<generation>-control. Output goes to
# controller-<id8>.log, followed by a controller_rc line.
# usage: restart-controller.sh <run_id> <generation>
set -euo pipefail
RUN="$1"; GEN="$2"
# 2026-09-30: the implementation MUST be the run's own recorded revision. A hardcoded 3f92e455
# drove a 039d0e00 run (pft-bf6ad3f4): its relay sat undelivered, and a second run's restart
# raced the native controller into "database is locked". run.send already starts the controller
# itself (control.py run_send -> start_controller), so never call this before a run.send; use it
# only for a run whose messages are pending with no controller process.
PFT="$(pf-task --home /home/matt/.pf-task --role coordinator run.status "{\"run_id\":\"$RUN\"}" \
  | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["provenance"]["implementation"]["text"])["source"])')"
[ -x "$PFT/scripts/pf-task" ] || { echo "REFUSE: run implementation not found: $PFT"; exit 2; }
NAME="$RUN-$GEN-control"
ID8="${RUN#pft-}"; ID8="${ID8:0:8}"
LOG="/home/matt/recovery/gpu14/controller-$ID8.log"
if pgrep -f "pf-task --home /home/matt/.pf-task controller $RUN\$" >/dev/null; then
  echo "REFUSE: a controller for $RUN is still alive: $(pgrep -f "pf-task --home /home/matt/.pf-task controller $RUN\$" | tr '\n' ' ')"; exit 2
fi
if tmux has-session -t "=$NAME" 2>/dev/null; then echo "REFUSE: tmux session $NAME exists"; exit 2; fi
ENVARGV="$(python3 - "$PFT/lib" <<'PY'
import shlex, sys
sys.path.insert(0, sys.argv[1])
from pf_task import native
print(shlex.join(native.launch_environment()))
PY
)"
[ -f "$LOG" ] && mv "$LOG" "$LOG.prev-$(date -u +%Y%m%dT%H%M%SZ)"
tmux new-session -d -s "$NAME" \
  "$ENVARGV /usr/bin/python3 $PFT/scripts/pf-task --home /home/matt/.pf-task controller $RUN > $LOG 2>&1; echo controller_rc=\$? at \$(date -u +%FT%TZ) >> $LOG"
for _ in $(seq 1 20); do
  pid="$(pgrep -f "pf-task --home /home/matt/.pf-task controller $RUN\$" || true)"
  [ -n "$pid" ] && { echo "restarted run=$RUN controller_pid=$pid session=$NAME log=$LOG"; exit 0; }
  sleep 0.5
done
echo "FAILED: no controller process for $RUN after 10 s; log:"; cat "$LOG" 2>/dev/null | tail -20; exit 1
