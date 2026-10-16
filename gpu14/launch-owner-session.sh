#!/usr/bin/env bash
# gpu-14 2026-10-10: launch an owner-attended interactive Claude coordinator session (Remote Control) in tmux.
# usage: launch-owner-session.sh <name> <model> <effort> <window_tokens> <kickoff-file>
# The context window is set with --settings env, NOT only the process env: mission-control/.claude/settings.local.json
# sets CLAUDE_CODE_AUTO_COMPACT_WINDOW=600000, and a settings file overrides the inherited environment. That is why
# tsp-h5ed.46 (exported 750000) came up at 600k. CLI --settings outranks local project settings.
set -euo pipefail
name=$1 model=$2 effort=$3 window=$4 kickoff=$5
[[ $name =~ ^[a-z0-9][a-z0-9.-]{1,40}$ ]] || { echo "LAUNCH refused reason=bad_name"; exit 2; }
[[ $window =~ ^[0-9]{5,7}$ ]] || { echo "LAUNCH refused reason=bad_window"; exit 2; }
[[ $effort =~ ^(low|medium|high|xhigh|max)$ ]] || { echo "LAUNCH refused reason=bad_effort"; exit 2; }
[ -s "$kickoff" ] || { echo "LAUNCH refused reason=kickoff_missing"; exit 2; }
tmux has-session -t "wt-$name" 2>/dev/null && { echo "LAUNCH refused reason=tmux_session_exists name=wt-$name"; exit 2; }
sid=$(cat /proc/sys/kernel/random/uuid)
dir=/home/matt/recovery/gpu14/owner-sessions/$name; mkdir -p "$dir"
cat >"$dir/run.sh" <<RUN
#!/usr/bin/env bash
cd /home/matt/mission-control
export PF_COMMS_NAME=$name PF_COMMS_COORD=gpu-14 PF_COMMS_RECV_MODE=split CLAUDE_CODE_AUTO_COMPACT_WINDOW=$window
exec claude --remote-control --name $name --session-id $sid --no-chrome --permission-mode bypassPermissions \\
  --model '$model' --effort $effort --settings '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"$window"}}' \\
  "\$(cat '$kickoff')"
RUN
cat >"$dir/sidecar.sh" <<RUN
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=$sid PF_COMMS_NAME=$name
exec pf-comms listen --id $name --sidecar
RUN
chmod 0755 "$dir/run.sh" "$dir/sidecar.sh"
tmux new-session -d -s "wt-$name" -c /home/matt/mission-control "exec bash -l '$dir/run.sh'"
tmux new-window -d -t "wt-$name" -c /home/matt/mission-control "exec bash -l '$dir/sidecar.sh'"
echo "LAUNCH ok name=$name tmux=wt-$name session_id=$sid model=$model effort=$effort window=$window run=$dir/run.sh"
