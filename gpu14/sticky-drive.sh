#!/usr/bin/env bash
# sticky-drive.sh (gpu-14, 2026-10-07): drive a managed run whose state is stuck at `blocked:
# turn_timeout_continuations_exhausted` (pf-task d2a68320 never clears that blocker, but run.send
# messages ARE still delivered and run: pft-6d98ed00 ran a full codex_completed turn at 00:59Z while
# still showing `blocked`). state can't tell turn end, so this keys turn completion on
# last_turn.message_id == the message we sent.
# usage: sticky-drive.sh <run_id> <TOKEN> <continue-file> <log> [max_continues=10] [turn_cap_s=14400] [owner/repo#PR]
# With [owner/repo#PR]: a CONTINUE whose reason mentions ci/check/await waits on `gh pr checks --watch` (no model
# turns) before continuing. 2026-10-07 02:38Z: 5 consecutive ~1.5-min "await CI" turns in 5 minutes otherwise.
# Exits (waking gpu-14) on: TOKEN state=HANDBACK|QUESTION, no status line, permission_blocked,
# released/failed, turn cap, or max continues. Prints one final line: STICKY_EXIT reason=...
set -u
RUN=$1; TOK=$2; CF=$3; LOG=$4; MAX=${5:-10}; CAP=${6:-14400}; PRREF=${7:-}
export PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-host.json
P=(/home/matt/.pf-task-v2/bin/pf-task --home /home/matt/.pf-task-v2 --role coordinator)
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
out() { log "STICKY_EXIT $*"; echo "STICKY_EXIT $*"; exit 0; }
status() { timeout 200 "${P[@]}" run.status "{\"run_id\":\"$RUN\"}" 2>/dev/null; }
last_token() { # status line of the newest result
  local t; t=$(timeout 200 "${P[@]}" run.result "{\"run_id\":\"$RUN\",\"limit\":1}" 2>/dev/null | jq -r '.total // 0')
  [ "$t" -gt 0 ] || return 0
  timeout 200 "${P[@]}" run.result "{\"run_id\":\"$RUN\",\"offset\":$((t-1)),\"limit\":1}" 2>/dev/null \
    | jq -r '.results[0].final_text | if type == "object" then (.text // "") else (. // "") end' | /usr/bin/grep -E "^${TOK} state=" | tail -1
}
n=0
while :; do
  s=$(status); st=$(jq -r '.state // "unknown"' <<<"$s")
  case "$st" in permission_blocked|released|failed|unavailable) out "reason=state_$st run=$RUN";; esac
  line=$(last_token); log "status: ${line:-<none>}"
  case "$line" in
    # A CONTINUE that waits on another PR/bead landing is a park, not work: hand back instead of looping
    # model turns (2026-10-07 03:46Z: await_995_35_merge got continue#6 sent).
    *"state=CONTINUE"*"reason=await_"*"_merge"*|*"state=CONTINUE"*"reason=park"*) out "reason=parked run=$RUN line=$line";;
    *"state=CONTINUE"*) ;;
    *"state=HANDBACK"*|*"state=QUESTION"*) out "reason=handback_or_question run=$RUN line=$line";;
    *) out "reason=no_status_line run=$RUN";;
  esac
  if [ -n "$PRREF" ] && printf '%s' "$line" | /usr/bin/grep -qiE 'reason=[a-z_]*(ci|check|await)'; then
    log "waiting on GitHub checks for $PRREF (no model turns)"
    # pf-pr-merge stays pending until the guarded merge itself (2026-10-07 03:15Z), so it is excluded.
    t1=$(date +%s); while [ $(( $(date +%s) - t1 )) -lt 3900 ]; do
      np=$(gh pr checks "${PRREF#*#}" --repo "${PRREF%#*}" 2>/dev/null | awk -F'\t' '$2=="pending" && $1!="pf-pr-merge"' | wc -l)
      [ "$np" = 0 ] && break; sleep 60; done
    log "checks settled: $(gh pr checks "${PRREF#*#}" --repo "${PRREF%#*}" 2>/dev/null | awk -F'\t' '{print $2}' | sort | uniq -c | tr -s ' \n' ' ')"
  fi
  [ "$n" -lt "$MAX" ] || out "reason=max_continues n=$n run=$RUN"
  n=$((n+1))
  j=$(python3 -c 'import json,sys; print(json.dumps({"run_id":sys.argv[1],"key":sys.argv[2],"text":open(sys.argv[3]).read()}))' "$RUN" "sticky-cont-$n-$(date -u +%s)" "$CF")
  before=$(status | jq -r '.last_turn.message_id // ""')
  mid=$(timeout 180 "${P[@]}" run.send "$j" 2>/dev/null | jq -r '.message_id // empty')
  [ -n "$mid" ] || out "reason=send_failed n=$n run=$RUN"
  log "continue#$n sent message_id=$mid"
  t0=$(date +%s)
  # Done when OUR message's turn ended, or (2026-10-07 02:05Z, 32 min idle) when a LATER queued message's
  # turn ended (FIFO: ours is done too), nothing is pending, and the runtime has been quiet for > 120 s.
  done_yet() { local x; x=$(status); [ "$(jq -r '.last_turn.message_id // ""' <<<"$x")" = "$mid" ] && return 0
    jq -e --arg b "$before" '(.last_turn.message_id // "") != $b and .messages.pending == 0 and (.native_activity_age_seconds // 0) > 120' <<<"$x" >/dev/null; }
  until done_yet; do
    [ $(( $(date +%s) - t0 )) -lt "$CAP" ] || out "reason=turn_cap n=$n mid=$mid run=$RUN"
    st=$(status | jq -r '.state // "unknown"')
    case "$st" in permission_blocked|released|failed) out "reason=state_$st n=$n run=$RUN";; esac
    sleep 60
  done
  log "continue#$n turn ended reason=$(status | jq -r '.last_turn.reason // ""')"
done
