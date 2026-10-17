#!/usr/bin/env bash
# gpu-14 generic lane driver (2026-10-03), replacing cx-drive.sh/sl-drive.sh.
# Waits on each turn of <run> and reads the lane's status line "<TOKEN> state=<S> ...":
#   CONTINUE -> run.send the continue text (counted against max_continues)
#   WAITING  -> the lane waits on NATIVE managed delivery (child results start its next turn).
#               Do NOT continue it; wait until the run turns busy again. If nothing starts a turn
#               within NUDGE_S, send ONE continue (counted) so a lost delivery cannot strand it.
#   anything else (QUESTION, HANDBACK, IDLE, missing line), a supervisor rc!=0, a turn state other
#   than awaiting_release, or a cap -> EXIT, which wakes gpu-14.
# Coordinator-lane runs (the four gpu-14 lanes) are never watched as children.
# usage: lane-drive.sh <run_id> <TOKEN> <continue-file> <approvals-name> <log> [max_continues=10] [wall_hours=30] [nudge_s=9000]
set -u
# 2026-10-13 (witness #2 of detached-lane-drivers-never-notify): a driver started as `( ... ) > /dev/null 2>&1 &` exits
# without notifying gpu-14. Refuse a /dev/null stdout; start drivers as Bash run_in_background tasks (stdout = task output file).
if [ "$(readlink /proc/$$/fd/1 2>/dev/null)" = /dev/null ]; then echo "DRIVER_EXIT reason=detached_start hint=start lane-drive.sh as a run_in_background task" >&2; exit 2; fi
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
# 2026-10-15: helpers moved out of the session scratchpad (lost on reboot/new session) into the durable gpu14 dir.
Sd=$R
run=$1; TOK=$2; cont=$3; A=$R/approvals-$4.jsonl; LOG=$5
resolved_home=$("$R/pf-task-run-home" resolve "$run" --format shell) || { echo "DRIVER_EXIT reason=run_home_unresolved run=$run"; exit 2; }
eval "$resolved_home"
# 2026-10-12 (loginstage): a continue file copied from another lane carried SEEDFIN_STATUS into a LOGINSTAGE run.
# A missing file is generated for this token; one naming any other *_STATUS token refuses before the driver starts.
case "$cont" in /*) cpath=$cont ;; *) cpath=$R/$cont ;; esac
if [ ! -s "$cpath" ]; then
  printf 'gpu-14 driver: continue per the work order and your own plan. Never wait on CI inside your turn. End with exactly one `%s state=...` line.\n' "$TOK" > "$cpath"
  echo "continue_file_generated path=$cpath token=$TOK"
fi
if /usr/bin/grep -oE '[A-Z0-9]+_STATUS' "$cpath" | /usr/bin/grep -vqxF "$TOK"; then
  echo "DRIVER_EXIT reason=continue_file_wrong_token path=$cpath want=$TOK found=$(/usr/bin/grep -oE '[A-Z0-9]+_STATUS' "$cpath" | sort -u | tr '\n' ' ')"; exit 2
fi
# 2026-10-09: one driver per run. On 01:2xZ gpu-14 started a second drive on imgfix while the
# first was still watching it; both would have sent continues. Hold a per-run flock for the
# driver's lifetime and exit if another driver already holds it.
exec 9>"$R/.drive-$run.lock"; if ! flock -n 9; then echo "DRIVER_EXIT reason=already_driven run=$run"; exit 0; fi
# 2026-10-10: children must not inherit the run lock (fd 9). A killed driver left an orphan `sleep 90`
# that held the lock, and the restart exited already_driven. zz sleeps without fd 9 and stays interruptible.
# The trap kills our children on TERM/HUP/INT, so a stopped driver leaves nothing behind.
zz() { local delay=$1; [ "${PF_LANE_DRIVE_FAST_TEST:-0}" = 1 ] && delay=0.02; sleep "$delay" 9>&- & wait $!; }
trap 'pkill -TERM -P $$ 2>/dev/null; exit 143' TERM HUP INT
# 2026-10-05: one owner per child. A lane that lists ANOTHER lane's worker in its status (CX-DEPUTY
# lists every live run) must not be woken for it: on 02:07Z the deputy picked up GPUCAP's #188 worker.
# Ownership = first driver family to watch the child; the family is the approvals name minus -gN.
OWN=$R/child-owners.txt; LANE_FAM=$(printf '%s' "$4" | sed -E 's/-g[0-9]+$//'); touch "$OWN"
max=${6:-10}; wall=$(( $(date +%s) + ${7:-30} * 3600 )); NUDGE_S=${8:-9000}; n=0; nc=0; CHILD_MAX=${CHILD_MAX:-200}; IDLE_S=${IDLE_S:-900}
V2_CAP=0; ROTATE_AT_ENV=${ROTATE_AT:-}; ROTATE_AT=${ROTATE_AT:-88}; ROT_SENT=0
[ "$H" = /home/matt/.pf-task-v2 ] && V2_CAP=1
touch "$A"
rstate() { timeout 200 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["generation"], int((d.get("messages") or {}).get("total") or 0) if sys.argv[1] == "1" else 0)' "$V2_CAP"; }
run_supervisor() {
  PF_TASK_RUN_HOME_RESOLVER="$R/pf-task-run-home" python3 "$R/lane-supervisor.py" "$run" "$1" "$A" 7 400
}
# Hermetic fragment gate: exercise the exact driver-to-supervisor boundary once,
# after this driver has independently resolved and locked the owner run.
if [ "${PF_LANE_DRIVE_SUPERVISOR_CHECK_ONLY:-0}" = 1 ]; then
  PF_LANE_SUPERVISOR_HOME_CHECK_ONLY=1 run_supervisor "$RUN_GENERATION"
  exit $?
fi
# 2026-10-05 19:00Z: child-event wakes (child) have their own cap. The COMPOSITOR driver hit max=12
# at 17:14Z mostly on approval wakes and exited just as a worker needed one more. max bounds only
# lane-driven continues (CONTINUE/nudge/fix), where a runaway loop is possible; child wakes are
# bounded by real child events.
send_cont() {
  if [ "$1" = child ]; then
    nc=$((nc+1)); if [ "$nc" -gt "$CHILD_MAX" ]; then echo "DRIVER_EXIT reason=child_wake_cap nc=$nc"; exit 0; fi
  elif [ "$1" = ci ]; then
    # 2026-10-11 (menu, pf-sim#10): a GREEN result after 4 productive RED rounds hit the continue cap and was
    # never delivered. CI results have their own cap: each one follows a real push, so they cannot spin.
    nci=$(( ${nci:-0} + 1 )); if [ "$nci" -gt "${CI_MAX:-12}" ]; then echo "DRIVER_EXIT reason=ci_result_cap nci=$nci"; exit 0; fi
  else
    n=$((n+1)); if [ "$n" -gt "$max" ]; then echo "DRIVER_EXIT reason=continue_cap n=$n"; exit 0; fi
  fi
  if [ "$(date +%s)" -ge "$wall" ]; then echo "DRIVER_EXIT reason=wall_cap"; exit 0; fi
  # 2026-10-11 (lvc pft-33ce17f6): a lane waiting on a detached build ended 9 turns ~40 s apart with CONTINUE and
  # burned 9 of its 40 messages before the continue cap. After two quick CONTINUE turns in a row (< FAST_CONT_S
  # apart), send ONE instruction to wait inside a single bounded turn instead of the plain continue.
  local use=$cont
  if [ "$1" = cont ]; then
    local now; now=$(date +%s)
    if [ -n "${LAST_CONT_T:-}" ] && [ $((now - LAST_CONT_T)) -lt "${FAST_CONT_S:-150}" ]; then FAST_N=$(( ${FAST_N:-0} + 1 )); else FAST_N=0; fi
    LAST_CONT_T=$now
    if [ "${FAST_N:-0}" -ge 2 ] && [ "${WAIT_SENT:-0}" = 0 ]; then
      WAIT_SENT=1; use="$R/.drv-wait-$run.txt"
      printf 'gpu-14 driver: your last turns ended CONTINUE less than %s s apart, and each one costs a message from your bounded budget. If you are waiting on a build, CI or a remote job, WAIT INSIDE THIS TURN: poll in the foreground (e.g. sleep 60 plus a status check), bounded to about 40 min, then do the next step in the same turn. End CONTINUE only if that bound expires, and give the progress. Continue your work now.\n' "${FAST_CONT_S:-150}" > "$use"
      echo "$(date -u +%FT%TZ) fast-continue x$FAST_N: sending wait-in-turn instruction" >> "$LOG"
    fi
  fi
  s=$($Sd/send.sh "$run" "$use" "drv-$1" 2>&1)
  echo "$(date -u +%FT%TZ) continue#$n/child#$nc ($1) -> ${s:0:160}" >> "$LOG"
  case "$s" in *refused*|*error*|"") echo "$s"; echo "DRIVER_EXIT reason=send_failed"; exit 0 ;; esac
}
rtotal() { timeout 200 $PFT --home $H --role coordinator run.result "{\"run_id\":\"$run\",\"limit\":1}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'; }
# 2026-10-14 (ovl pft-944abc57 results 17-18): an OpenCode/Qwen lane lost its brief to context compaction, ended one turn
# with no status line, and after the generic "continue from where you stopped" nudge answered a long-finished infra-321
# assignment with a bare `HANDBACK` (no reason=). Anchor every recovery nudge in the run's own record: its bead, worktree
# and the last status line this driver recorded for it.
ranchor() { timeout 120 $PFT --home $H --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); w=d.get("worktree") or {}; w=w.get("text") if isinstance(w,dict) else w; print("bead=%s worktree=%s" % (d.get("task") or "?", w or "?"))' 2>/dev/null || echo "bead=? worktree=?"; }
LAST_STL=$(/usr/bin/grep -E "status\(result#[0-9]+\): .{0,4}${TOK} state=[A-Z_]+ .*(reason|pr|head|dir)=" "$LOG" 2>/dev/null | tail -n 1 | sed -E 's/^.*status\(result#[0-9]+\): //' | cut -c1-300)
anchor_text() { printf 'Your run record says: %s. The last status line this driver recorded for you was: %s. If your context was compacted and this does not match what you remember, trust this record: re-read the bead (cd /home/matt/mission-control && bd show <bead>) and the PR/worktree state before acting, and never resume an older assignment from memory.' "$(ranchor)" "${LAST_STL:-none recorded}"; }
# 2026-10-14 (panel window da3e4495): the runner failed the window at 13:54Z (DECLARED_REBOOT_NOT_OBSERVED,
# session_result_invalid) while panel waited on WINDOW_STEP seq=3; a failed window delivers no receipt, so the driver sat
# idle until the board noticed 20 min later. win_state prints "<State> <generation> <failure reason>" for the newest
# window whose active.json names this run ("none - -" if none).
win_state() { python3 -c '
import json,sys,glob,os
run=sys.argv[1]; best=None
for a in glob.glob(os.path.expanduser("~/.local/state/pocketforge/kit-windows/*/active.json")):
    try: s=open(a).read()
    except OSError: continue
    if run not in s: continue
    d=os.path.dirname(a); m=os.path.getmtime(a)
    if best is None or m>best[0]: best=(m,d)
if not best: print("none - -"); sys.exit()
d=best[1]
try: st=json.load(open(d+"/runner.json")).get("State") or "?"
except Exception: st="?"
why="-"
try: why=json.load(open(d+"/failure.json")).get("Reason") or "-"
except Exception: pass
print(st, os.path.basename(d), why)' "$run" 2>/dev/null || echo "? - -"; }
declare -A CBASE CLATE NOTIFIED CST
LAST_TP=$(date +%s); PREV_TP=0; MV=""
# cinfo: "<state> <last_turn.ended_at epoch> <pending permission ids, comma-joined, or ->" for a child run.
cinfo() { timeout 120 $PFT --home $H --role coordinator run.status "{\"run_id\":\"$1\"}" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); lt=d.get("last_turn") or {}; ps=[((x.get("id") or {}).get("text") or "") for x in ((d.get("blocker") or {}).get("permissions") or [])]; print(d.get("state","?"), int(lt.get("ended_at") or 0), ",".join(p for p in ps if p) or "-")' 2>/dev/null || echo "? 0 -"; }
# cunacked: unacknowledged receipt count of a child (0 on any read error).
cunacked() { timeout 120 $PFT --home $H --role coordinator run.status "{\"run_id\":\"$1\"}" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int((d.get("receipts") or {}).get("unacknowledged") or 0))' 2>/dev/null || echo 0; }
ctotal() { timeout 120 $PFT --home $H --role coordinator run.result "{\"run_id\":\"$1\",\"limit\":1}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])' 2>/dev/null || echo -1; }
set_children() {  # every pft id named in the lane's last status block becomes a watched child
  CBASE=(); CLATE=(); CST=()
  for c in $(printf '%s\n' "$1" | /usr/bin/grep -oE 'pft-[0-9a-f]{24}' | sort -u | /usr/bin/grep -v -x -e "$run" -e pft-d4240140775bd97cf4aa1328 -e pft-3488f64e055d4f1514ffb0d4 -e pft-677d07c292dbf2582f356c83 -e pft-0aa716babea7d23028bf3c57 -e pft-fd3bc13a3bc1003c067d6be3 -e pft-1b67604b9476a695d3351bbe -e pft-0ad3c95c9b9561614efd450f -e pft-a42deaf22c26f8d7e7d65951 -e pft-1375791e04a95f3963e11e77 -e pft-2ad95cd0e2737af9b9a60cd9 -e pft-7d6be6260b261e023fd6b8b0 -e pft-da41853729995fd0741c859b -e pft-1a85e668c5f2e4ef366375f1 -e pft-629b31e721bfee792008b9c9 -e pft-e30bc97d53d85fa0cbfca7a0 -e pft-2cbd333e9a4d3b35742a1c16 -e pft-3488f64e055d4f1514ffb0d4 | head -n 16); do
    # 2026-10-05: preserved systemError runs are gpu-14's (systemerror-preserved.txt). Waking a lane
    # with "STUCK, clear it" sent GPUCAP g3 into refused release attempts instead of its queue.
    if awk -v c="$c" '$1==c{f=1} END{exit !f}' "$R/systemerror-preserved.txt" 2>/dev/null; then echo "$(date -u +%FT%TZ) skip $c preserved_systemError" >> "$LOG"; continue; fi
    owner=$(awk -v c="$c" '$1==c{print $2; exit}' "$OWN")
    if [ -n "$owner" ] && [ "$owner" != "$LANE_FAM" ]; then echo "$(date -u +%FT%TZ) skip $c owned_by=$owner" >> "$LOG"; continue; fi
    [ -z "$owner" ] && echo "$c $LANE_FAM" >> "$OWN"
    CBASE[$c]=$(ctotal "$c")
    # 2026-10-04: a child result that landed DURING the lane's turn was folded into this
    # baseline and never woke the lane (QEMU #1219 repair sat 60 min). Flag it once.
    read -r cs ce cp < <(cinfo "$c"); CST[$c]=$cs
    # 2026-10-06: a released run is terminal. COMPOSITOR's driver watched gpu-14's released
    # pft-74435818 and woke the lane for it at 13:09Z (a wasted turn). Never watch released runs.
    if [ "$cs" = released ]; then unset 'CBASE[$c]' 'CST[$c]'; echo "$(date -u +%FT%TZ) skip $c released" >> "$LOG"; continue; fi
    # 2026-10-05: only if a receipt is still unacked. The deputy processes and acks a result in-turn,
    # and flagging it anyway cost a no-op "rechecking" turn (06:53Z).
    if [ "$PREV_TP" -gt 0 ] && [ "$ce" -gt "$PREV_TP" ] && [ "$cs" = awaiting_release ] && [ "$(cunacked "$c")" -gt 0 ]; then CLATE[$c]=1; fi
    # 2026-10-05: a fresh driver (PREV_TP=0) missed .997.22, which finished before the restart and
    # sat 35 min with an unacked receipt. On a first watch, an awaiting child with unacked receipts is late.
    if [ "$PREV_TP" -eq 0 ] && [ "$cs" = awaiting_release ] && [ "$(cunacked "$c")" -gt 0 ]; then CLATE[$c]=1; fi
  done
  echo "$(date -u +%FT%TZ) watching ${#CBASE[@]} children: ${!CBASE[*]} late: ${!CLATE[*]}" >> "$LOG"
}
# child_moved sets MV="<child> <reason>" and returns 0. Called WITHOUT a subshell so the
# NOTIFIED once-guards persist. Reasons: late result, new result, or a stuck child state
# (2026-10-04: two workers sat 'blocked' for 48 min and 2.3 h on leftover REPL children and
# no driver woke their lane, because only the result count was watched).
child_moved() {
  MV=""; local c t cs ce cp k idle=""
  for c in "${!CLATE[@]}"; do
    k="$c:late:${CBASE[$c]}"; [ -n "${NOTIFIED[$k]:-}" ] && continue
    NOTIFIED[$k]=1; MV="$c result_arrived_during_your_last_turn"; return 0
  done
  for c in "${!CBASE[@]}"; do
    t=$(ctotal "$c")
    if [ "$t" -gt "${CBASE[$c]}" ] 2>/dev/null; then MV="$c new_result"; return 0; fi
    read -r cs ce cp < <(cinfo "$c")
    # 2026-10-05: permission_blocked too. Two COMPOSITOR workers (on-request approval policy) sat
    # 1.6 h on a pending commandExecution approval and no driver woke the lane.
    # 2026-10-05 15:10Z: the once-guard key carries the pending request ids. Keyed on the result
    # count alone, pft-d607's SECOND request (:4, same turn) matched the :1 key and sat 38 min.
    case "$cs" in blocked|unavailable|failed|permission_blocked)
      k="$c:$cs:$t:$cp"; [ -n "${NOTIFIED[$k]:-}" ] && continue
      NOTIFIED[$k]=1; MV="$c state_$cs"; return 0 ;;
    esac
    case "$cs" in awaiting_release|released) idle="$idle $c" ;; *) idle="${idle} BUSY" ;; esac
  done
  # 2026-10-05 15:10Z: a lane WAITING on children none of which is running has no wake source.
  # COMPOSITOR listed cache worker pft-42 "in flight" after processing its result, but never
  # continued it: idle 47 min, only the 2.5 h nudge would have woken anyone. Once per lane turn.
  case "$idle" in *BUSY*|"") return 1 ;; esac
  if [ $(( $(date +%s) - LAST_TP )) -ge "$IDLE_S" ]; then
    k="idle:$LAST_TP"; [ -n "${NOTIFIED[$k]:-}" ] && return 1
    NOTIFIED[$k]=1; MV="${idle# } all_children_idle"; return 0
  fi
  return 1
}
# 2026-10-06: a FINISHED child needs an explicit disposition from its lane. CX-DEPUTY carried
# pft-da6eea79 (.995.6, PRs untouched) ~64 h and pft-84b9baae ~26 h in its watch set: the
# all_children_idle check never fired because some other child was always BUSY. At each lane turn
# end, every watched child in awaiting_release must appear on a status line with "disposition=".
# Asked once per child result (NOTIFIED key); reuses set_children's states (no extra run.status).
check_dispositions() {
  case "$TOK" in CX_DEPUTY_STATUS|COMPOSITOR_STATUS|GPUCAP_STATUS|STEAMLINK_STATUS) ;; *) return 0 ;; esac
  local c k nd="" ask=""
  for c in "${!CST[@]}"; do
    [ "${CST[$c]}" = awaiting_release ] || continue
    [ -n "${CLATE[$c]:-}" ] && continue   # its unread result wakes the lane anyway
    printf '%s\n' "$1" | /usr/bin/grep -F -- "$c" | /usr/bin/grep -q 'disposition=' && continue
    nd="$nd $c"
    k="$c:nodisp:${CBASE[$c]}"; [ -n "${NOTIFIED[$k]:-}" ] && continue
    NOTIFIED[$k]=1; ask="$ask $c"
  done
  [ -n "$nd" ] && echo "$(date -u +%FT%TZ) NO_DISPOSITION:$nd" >> "$LOG"
  [ -z "$ask" ] && return 0
  printf 'gpu-14 driver: these children of yours are FINISHED (awaiting_release) but your status gives no decision for them:%s. For EACH one, decide now and write it on a status line as `<full run id> disposition=<review|continue|release|park:<reason>>`: route its next step (review/merge or run.send), verify and release it, or record a deliberate park with its reason on its bead. A finished child with no disposition is a stall. Then continue your normal work in this same turn.\n' "$ask" > "$R/.drv-disp-$run.txt"
  echo "$(date -u +%FT%TZ) asking disposition for:$ask" >> "$LOG"
  cont_save=$cont; cont="$R/.drv-disp-$run.txt"; send_cont fix; cont=$cont_save; zz 20
}
process_status() {
  PREV_TP=$LAST_TP; LAST_TP=$(date +%s)
  last=$(rtotal) || { echo "DRIVER_EXIT reason=result_unreadable"; exit 0; }
  blk=$($Sd/rt2.sh "$run" 30000 2>&1)
  stl=$(printf '%s\n' "$blk" | /usr/bin/grep -E "^\**\`?${TOK}" | tail -n 1)
  # 2026-10-12 (lin gamescope#12): a lane that pushed and found checks still pending ended `HANDBACK reason=CHECKS_PENDING
  # pr=... head=...` instead of CI_WAIT, which woke gpu-14 for a plain wait. Treat that handback as CI_WAIT.
  case "$stl" in *"state=HANDBACK"*"reason=CHECKS_PENDING"*|*"state=HANDBACK"*"reason=CI_PENDING"*)
    if printf '%s' "$stl" | /usr/bin/grep -qiE 'head=[0-9a-f]{40}'; then
      echo "$(date -u +%FT%TZ) HANDBACK for pending checks; handling as CI_WAIT" >> "$LOG"; stl=${stl/state=HANDBACK/state=CI_WAIT}
    fi ;;
  esac
  # 2026-10-16 (pwrcyc automation#1494): lanes also say reason=CI_NOISE for the same case; treated identically.
  # 2026-10-15 (rclone automation#1489, ota #1488): lanes handed back `reason=UNRELATED_CI_FAILURE` / `CI_INFRA_*` with evidence
  # and "rerun CI on the exact head", and gpu-14 re-ran the failed jobs by hand each time. Do it here ONCE per head: re-run the
  # failed/timed-out Actions runs for that head (owner gh creds; the bot token is read-only), then wait as CI_WAIT. A second
  # red on the same head stays a HANDBACK for gpu-14, so a real failure is never retried into green by repetition.
  case "$stl" in *"state=HANDBACK"*"reason=UNRELATED_CI_FAILURE"*|*"state=HANDBACK"*"reason=CI_INFRA_"*|*"state=HANDBACK"*"reason=CI_FLAKE"*|*"state=HANDBACK"*"reason=CI_NOISE"*)
    rr_reason=$(printf '%s' "$stl" | /usr/bin/grep -oE 'reason=[A-Z_]+' | head -n1)
    rr_head=$(printf '%s' "$stl" | /usr/bin/grep -oiE 'head=[0-9a-f]{40}' | head -n1 | cut -d= -f2)
    rr_repo=$(printf '%s' "$stl" | /usr/bin/grep -oE 'pr=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | head -n1 | sed 's/^pr=//; s/#.*//')
    rr_mark="$R/ci-rerun-markers/${rr_head:-none}"
    if [ -n "$rr_head" ] && [ -n "$rr_repo" ] && [ ! -e "$rr_mark" ]; then
      mkdir -p "$R/ci-rerun-markers"; date -u +%FT%TZ > "$rr_mark"
      rr_ids=$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 60 gh run list --repo "$rr_repo" --commit "$rr_head" --limit 100 \
        --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="timed_out") | .databaseId' 2>/dev/null)
      rr_rc=$?; rr_ok=1; [ "$rr_rc" -eq 0 ] || rr_ok=0
      for rr_id in $rr_ids; do
        env -u GH_TOKEN -u GITHUB_TOKEN timeout 60 gh run rerun "$rr_id" --failed --repo "$rr_repo" >/dev/null 2>&1 || rr_ok=0
      done
      if [ "$rr_ok" = 1 ]; then
        echo "$(date -u +%FT%TZ) HANDBACK $rr_reason -> re-ran failed runs [$(echo $rr_ids)] once for $rr_repo head ${rr_head:0:12}; handling as CI_WAIT" >> "$LOG"
        zz 30; stl=${stl/state=HANDBACK/state=CI_WAIT}
      else
        echo "$(date -u +%FT%TZ) HANDBACK $rr_reason: re-run FAILED for head ${rr_head:0:12} (list_rc=$rr_rc ids=[$(echo $rr_ids)]); leaving HANDBACK for gpu-14" >> "$LOG"
      fi
    elif [ -e "$rr_mark" ]; then
      echo "$(date -u +%FT%TZ) HANDBACK $rr_reason: head ${rr_head:0:12} was already re-run once ($(cat "$rr_mark")); leaving HANDBACK for gpu-14" >> "$LOG"
    fi ;;
  esac
  # 2026-10-16 proc-coord for gpu-14 (gsrot, tfar, rtx11 within one hour): lanes reported a LOCAL job as
  # `CI_WAIT ghrun=<repo>/<pid>` or `BUILD_RUNNING run=<pid|unit>`; ghrun-wait returned UNREADABLE and the driver exited to
  # gpu-14 each time. A GitHub Actions run id is numeric with >=10 digits: anything else gets the correction and the driver
  # keeps watching (bounded by the continue cap, so a repeat cannot spin).
  case "$stl" in *"state=BUILD_RUNNING"*|*"state=CI_WAIT"*"ghrun="*)
    lj_bad=""
    case "$stl" in *"state=BUILD_RUNNING"*)
      lj_id=$(printf '%s' "$stl" | /usr/bin/grep -oE '(^|[[:space:]])runs?=[^[:space:]`]+' | head -n1 | sed 's/.*=//; s/,.*//')
      [[ $lj_id =~ ^[0-9]{10,}$ ]] || lj_bad=${lj_id:-none} ;;
    esac
    case "$stl" in *"ghrun="*)
      lj_id=$(printf '%s' "$stl" | /usr/bin/grep -oE 'ghrun=[^[:space:]`]+' | head -n1 | sed 's#.*/##')
      [[ $lj_id =~ ^[0-9]{10,}$ ]] || lj_bad=${lj_id:-none} ;;
    esac
    if [ -n "$lj_bad" ]; then
      printf 'gpu-14 driver: `%s` is not a GitHub Actions run id (those are numeric, 10+ digits), so nothing can wait on it for you. For a LOCAL job (author review, tests or a build running on this machine), end with `%s state=CONTINUE` and read its output file next turn. Use `CI_WAIT ghrun=<owner>/<repo>/<run_id>` or `BUILD_RUNNING run=<run_id>` only for real GitHub Actions runs, and `CI_WAIT pr=<owner>/<repo>#<n> head=<sha>` after a push.\n' "${lj_bad:0:60}" "$TOK" > "$R/.drv-localjob-$run.txt"
      echo "$(date -u +%FT%TZ) local job id '${lj_bad:0:60}' in ${stl:0:120}; sent correction, keep watching" >> "$LOG"
      cont_save=$cont; cont="$R/.drv-localjob-$run.txt"; send_cont fix; cont=$cont_save; zz 20; return 0
    fi ;;
  esac
  # 2026-10-15 (b11 Build 13): `state=BUILD_RUNNING run=<actions run id>` exited the driver, and gpu-14 had to chain
  # ghrun-wait.sh by hand. Treat it as a CI_WAIT on that non-PR Actions run (owned-image-build lives in automation unless
  # the line names repo=<owner>/<repo>), so the lane is re-prompted with the job conclusions when the build finishes.
  case "$stl" in *"state=BUILD_RUNNING"*)
    # 2026-10-16 (b11 Build 15): gpu-14 asked for `runs=<a>,<b>`; only `run=` matched and the driver exited. Accept both;
    # with runs= wait on the FIRST id: the lane is re-prompted at its conclusion and reports the other as BUILD_RUNNING run=.
    br_id=$(printf '%s' "$stl" | /usr/bin/grep -oE '(^|[[:space:]])runs?=[0-9]{6,}' | head -n1 | sed 's/.*=//' | tr -dc '0-9')
    br_repo=$(printf '%s' "$stl" | /usr/bin/grep -oiE 'repo=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -n1 | cut -d= -f2)
    if [ -n "$br_id" ]; then
      echo "$(date -u +%FT%TZ) BUILD_RUNNING run=$br_id; handling as CI_WAIT ghrun" >> "$LOG"
      stl="$TOK state=CI_WAIT ghrun=${br_repo:-pocketforge-os/pocketforge-automation}/$br_id"
    fi ;;
  esac
  set_children "$blk"
  echo "$(date -u +%FT%TZ) status(result#$last): ${stl:0:300}" >> "$LOG"
  case "$stl" in *"state=HANDBACK"*) case "$stl" in *"reason="*) LAST_STL=${stl:0:300} ;; esac ;; *"state="*) LAST_STL=${stl:0:300} ;; esac
  # 2026-10-05 19:00Z: a run id written short (deputy g6 wrote "pft-b56d6dfa") is invisible to
  # set_children, so its result never woke the lane (critical-path result sat 17+ min). Ask once
  # per lane turn for full ids; the lane's next status then makes the child watchable.
  # Only a short id that is NOT a prefix of some full id in the same block is unwatchable: lanes
  # abbreviate in prose (COMPOSITOR "pft-d607") while listing the full id in IN FLIGHT; flagging
  # those looped COMPOSITOR twice at 19:06Z and its "no other action" wording stranded an approval.
  full=$(printf '%s\n' "$blk" | /usr/bin/grep -oE 'pft-[0-9a-f]{24}' | sort -u)
  short=$(printf '%s\n' "$blk" | /usr/bin/grep -oE 'pft-[0-9a-f]+' | awk 'length($0)!=28' | sort -u | while read -r sid; do printf '%s\n' "$full" | /usr/bin/grep -q "^$sid" || printf '%s ' "$sid"; done | head -c 200)
  case "$stl" in *"state=WAITING"*)
    if [ -n "$short" ]; then
      printf 'gpu-14 driver: your status names run ids in SHORT form (%s). The driver can only watch full 24-hex ids, so those runs cannot wake you. Re-derive them with run.status and restate your status block with every in-flight run as a FULL id, AND continue your normal work in this same turn (answer any pending child approval, process any child result).\n' "$short" > "$R/.drv-fix-$run.txt"
      echo "$(date -u +%FT%TZ) short ids in status: $short; asking for full ids" >> "$LOG"
      cont_save=$cont; cont="$R/.drv-fix-$run.txt"; send_cont fix; cont=$cont_save; zz 20
    fi ;;
  esac
  case "$stl" in *"state=WAITING"*) check_dispositions "$blk" ;; esac
  case "$stl" in
    # 2026-10-11: b7p ended `state=WORKING` mid-plan and the driver exited; treat in-progress synonyms as CONTINUE.
    *"state=CONTINUE"*|*"state=WORKING"*|*"state=IN_PROGRESS"*) send_cont cont; zz 20 ;;
    # 2026-10-11 (pwt pft-42672444): a lane that started a detached review/build ends REVIEW_WAIT or BUILD_WAIT;
    # an unknown state exited the driver to gpu-14. Give the detached job 5 min, then continue the lane.
    *"state=REVIEW_WAIT"*|*"state=BUILD_WAIT"*) echo "$(date -u +%FT%TZ) ${stl##*state=}: waiting 300 s then continuing" >> "$LOG"; zz 300; send_cont cont; zz 20 ;;
    *"state=WAITING"*) : ;;
    # 2026-10-13 (fu7/slfl live windows): a window lane ends each turn with WINDOW_STEP seq=<n> after submitting one
    # create-once request; the window runner delivers that receipt to the OwnerRun by pf-task message, which starts the
    # lane's next turn by itself. Keep watching (no message from the driver); the window's own 600 s idle close and the
    # driver's hour bound end a stall, and the lane's HANDBACK (or any other state) exits to gpu-14.
    *"state=WINDOW_WAIT"*) echo "$(date -u +%FT%TZ) WINDOW_WAIT: queued window; waiting for PF_KIT_NETWORK_READY delivery" >> "$LOG" ;;
    # 2026-10-16 proc-coord (gpu-14 answer 1): WINDOW_DONE gen= plan=complete|incomplete records the close for
    # window-queue.sh (complete->success, incomplete->failure) and continues the lane on its own plan; no gpu-14 turn.
    *"state=WINDOW_DONE"*"plan="*)
      wd=$("$R/window-queue.sh" --done-from-status "$stl" 2>&1 9>&-); wdrc=$?
      echo "$(date -u +%FT%TZ) window done rc=$wdrc $(printf '%s' "$wd" | tail -n1 | cut -c1-200)" >> "$LOG"
      if [ "$wdrc" = 0 ]; then send_cont cont; zz 20
      else echo "$stl"; echo "$wd"; echo "DRIVER_EXIT reason=window_done_unrecorded rc=$wdrc"; exit 0; fi ;;
    *"state=WINDOW_STEP"*) echo "$(date -u +%FT%TZ) WINDOW_STEP ${stl##*state=WINDOW_STEP}: waiting for the runner's receipt delivery" >> "$LOG" ;;
    *"state=CI_WAIT"*)
      # 2026-10-10 (owner: fewer mechanical round trips; bead tsp-mc9m.41.995.65): the lane pushed and
      # ended its turn; wait for that exact head's CI here and re-prompt the lane with the outcome.
      # gpu-14 is woken only when the helper cannot decide (head moved, timeout, bad args).
      # 2026-10-12 (cargv pft-1f4ded9d): a lane wrote `PR=<url> HEAD=<sha>` in caps and the driver exited ci_wait_needs_gpu14; match keys case-insensitively.
      ciw_pr=$(printf '%s' "$stl" | /usr/bin/grep -oiE 'pr=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | head -n1 | cut -d= -f2)
      # 2026-10-11 (psu2): a lane wrote pr=https://github.com/<owner>/<repo>/pull/<n>; normalize the URL form.
      [ -n "$ciw_pr" ] || ciw_pr=$(printf '%s' "$stl" | /usr/bin/grep -oiE 'pr=https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | head -n1 | sed -E 's#^[Pp][Rr]=https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#\1/\2\#\3#')
      # 2026-10-12 (lvc-g2 pft-474266ce): a lane wrote `repo=<owner>/<repo> pr=<n>`; accept that split form too.
      if [ -z "$ciw_pr" ]; then
        ciw_r=$(printf '%s' "$stl" | /usr/bin/grep -oiE 'repo=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -n1 | cut -d= -f2)
        ciw_n=$(printf '%s' "$stl" | /usr/bin/grep -oiE '(^|[[:space:]])pr=#?[0-9]+([[:space:]]|$)' | head -n1 | tr -dc '0-9')
        [ -n "$ciw_r" ] && [ -n "$ciw_n" ] && ciw_pr="$ciw_r#$ciw_n"
      fi
      # 2026-10-12 (seedfin pft-4742a8e7): `PR: https://github.com/<o>/<r>/pull/<n> | HEAD: <sha>`; accept a bare PR URL and HEAD:.
      [ -n "$ciw_pr" ] || ciw_pr=$(printf '%s' "$stl" | /usr/bin/grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | head -n1 | sed -E 's#^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#\1/\2\#\3#')
      ciw_head=$(printf '%s' "$stl" | /usr/bin/grep -oiE 'head=[0-9a-f]{40}' | head -n1 | cut -d= -f2)
      [ -n "$ciw_head" ] || ciw_head=$(printf '%s' "$stl" | /usr/bin/grep -oiE 'head[=:][[:space:]]*[0-9a-f]{40}' | head -n1 | /usr/bin/grep -oE '[0-9a-f]{40}')
      ciw_msg="$R/.drv-ciw-$run.txt"; rm -f "$ciw_msg"
      echo "$(date -u +%FT%TZ) CI_WAIT pr=$ciw_pr head=$ciw_head" >> "$LOG"
      # 2026-10-11: run helpers in the background and `wait`, never inside $(...): bash defers the TERM
      # trap while blocked reading a command substitution, so a stopped driver (syno 02:05Z) lived on.
      # 2026-10-11 (rlab canary): a CI_WAIT on a NON-PR Actions run names it as ghrun=<owner>/<repo>/<run_id>;
      # watch that run instead of a PR (ghrun-wait.sh writes the continue message with each job's conclusion).
      ciw_ghrun=$(printf '%s' "$stl" | /usr/bin/grep -oE 'ghrun=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[0-9]+' | head -n1 | cut -d= -f2)
      if [ -z "$ciw_pr" ] && [ -n "$ciw_ghrun" ]; then
        echo "$(date -u +%FT%TZ) CI_WAIT ghrun=$ciw_ghrun" >> "$LOG"
        "$R/ghrun-wait.sh" "${ciw_ghrun%/*}" "${ciw_ghrun##*/}" "$TOK" "$ciw_msg" > "$R/.drv-ciwout-$run.txt" 2>>"$LOG" 9>&- &
      else
        "$R/ci-wait-continue.sh" "$ciw_pr" "$ciw_head" "$TOK" "$ciw_msg" > "$R/.drv-ciwout-$run.txt" 2>>"$LOG" 9>&- &
      fi
      # 2026-10-13 (pool1 + a67): a gpu-14 message during CI_WAIT starts a new lane turn, but this driver sat in
      # `wait` on the CI waiter (a stalled pool never finishes CI), so the new turn's status went unseen. Poll the
      # run's result count; a new result abandons this CI wait and the main loop processes the newer status.
      ciw_pid=$!
      while kill -0 "$ciw_pid" 2>/dev/null; do
        ciw_nt=$(rtotal 2>/dev/null) || ciw_nt=$last
        if [ "${ciw_nt:-0}" -gt "$last" ] 2>/dev/null; then
          echo "$(date -u +%FT%TZ) CI_WAIT abandoned: new lane result #$ciw_nt arrived (gpu-14 message turn)" >> "$LOG"
          kill "$ciw_pid" 2>/dev/null; wait "$ciw_pid" 2>/dev/null; return 0
        fi
        zz 30
      done
      wait "$ciw_pid"; ciw_rc=$?; ciw=$(cat "$R/.drv-ciwout-$run.txt")
      echo "$(date -u +%FT%TZ) $ciw" >> "$LOG"
      if [ "$ciw_rc" -eq 0 ] && [ -s "$ciw_msg" ]; then
        # 2026-10-14 (qreb pft-56746590, qemu-tsp#27): 7 consecutive RED rounds in 20 min, each fixing one compile
        # error by hand-editing .patch files, before the lane itself said the loop was unsustainable. Owner rule:
        # redesign after 2-3 patch rounds. After CI_RED_MAX (default 4) consecutive REDs on one PR, stop and hand
        # the method to gpu-14 instead of forwarding another RED. A GREEN resets the count; restart the driver
        # to continue deliberately.
        ci_pr=$(printf '%s' "$ciw" | /usr/bin/grep -oE 'pr=[^ ]+' | head -n1)
        if printf '%s' "$ciw" | /usr/bin/grep -q 'result=RED'; then
          [ "$ci_pr" = "${red_pr:-}" ] && red_n=$(( ${red_n:-0} + 1 )) || { red_pr=$ci_pr; red_n=1; }
        else red_n=0; red_pr=""; fi
        if [ "${red_n:-0}" -ge "${CI_RED_MAX:-4}" ]; then
          echo "$stl"; echo "$ciw"; echo "DRIVER_EXIT reason=ci_red_churn ${ci_pr} consecutive_red=$red_n hint=read the failures and redesign the method before another round"; exit 0
        fi
        cont_save=$cont; cont=$ciw_msg; send_cont ci; cont=$cont_save; zz 20
      elif printf '%s' "$ciw" | /usr/bin/grep -q 'result=HEAD_MOVED' && [ "${hm_n:-0}" -lt 3 ]; then
        # 2026-10-11 (kitfix twice): a gpu-14 message gave the lane a new turn, it pushed, and this driver
        # exited on HEAD_MOVED. Keep driving: if the run is mid-turn, wait for its status; otherwise ask it once
        # to confirm the new head is its own push and restate CI_WAIT on it (never push over a foreign head).
        hm_n=$(( ${hm_n:-0} + 1 ))
        hm_now=$(printf '%s' "$ciw" | /usr/bin/grep -oE 'now=[0-9a-f]{40}' | head -n1 | cut -d= -f2)
        hm_st=$(rstate 2>/dev/null | awk '{print $1}')
        if [ "$hm_st" = busy ]; then
          echo "$(date -u +%FT%TZ) HEAD_MOVED to ${hm_now:0:12} while the run is busy: waiting for its status" >> "$LOG"; zz 20
        else
          printf 'gpu-14 driver: %s moved from %s to %s after your CI_WAIT. If that push is yours, confirm your tests ran at the new head and end with `%s state=CI_WAIT pr=%s head=%s`. If it is NOT yours, say so and stop; never push over it.\n' "$ciw_pr" "${ciw_head:0:12}" "$hm_now" "$TOK" "$ciw_pr" "$hm_now" > "$R/.drv-hm-$run.txt"
          cont_save=$cont; cont="$R/.drv-hm-$run.txt"; send_cont fix; cont=$cont_save; zz 20
        fi
      elif printf '%s' "$ciw" | /usr/bin/grep -q 'result=BAD_ARGS' && [ "${ba_n:-0}" -lt 2 ]; then
        # 2026-10-12 (nodedeploy pft-e8a8c04e: no pr; etc2 pft-ce50b550: `pr=209`): both drivers exited BAD_ARGS at
        # 09:17Z and the lanes sat undriven ~50 min. One parser patch per new format did not converge; ask the lane
        # to restate the exact form (twice at most), then exit to gpu-14.
        ba_n=$(( ${ba_n:-0} + 1 ))
        printf 'gpu-14 driver: your CI_WAIT line could not be parsed (got pr=%s head=%s). Restate it exactly as `%s state=CI_WAIT pr=<owner>/<repo>#<number> head=<40-hex sha>` for the PR you pushed, with no other change. If you have NOT opened a PR yet, open it now (or say why you cannot) and then end with that line.\n' "${ciw_pr:-none}" "${ciw_head:-none}" "$TOK" > "$R/.drv-ba-$run.txt"
        echo "$(date -u +%FT%TZ) CI_WAIT BAD_ARGS (#$ba_n): asking the lane to restate pr/head" >> "$LOG"
        cont_save=$cont; cont="$R/.drv-ba-$run.txt"; send_cont fix; cont=$cont_save; zz 20
      else
        echo "$stl"; echo "$ciw"; echo "DRIVER_EXIT reason=ci_wait_needs_gpu14"; exit 0
      fi ;;
    "")
      # 2026-10-11 (glm pft-0549e8cb result 1): a Qwen turn ended after DESCRIBING its next edits, with no
      # status line, and the driver exited to gpu-14 for a one-line nudge. Nudge it here, twice at most.
      NOSTAT_N=$(( ${NOSTAT_N:-0} + 1 ))
      if [ "$NOSTAT_N" -le 2 ]; then
        printf 'gpu-14 driver: your last turn ended WITHOUT a `%s state=...` line. Usually the 1 h turn limit aborted you mid-work: continue from where you stopped, and keep this turn well under 1 h (start long test runs in the background with output to a file; if they are still running, end with `%s state=CONTINUE` and read the file next turn). If you described edits or steps you had not yet carried out, carry them out now. Then end with exactly one `%s state=...` line (CI_WAIT pr=<owner/repo>#<n> head=<40-hex> after a push; HANDBACK for merge-ready, decisions or blockers).\n' "$TOK" "$TOK" "$TOK" > "$R/.drv-nostat-$run.txt"
        anchor_text >> "$R/.drv-nostat-$run.txt"; echo >> "$R/.drv-nostat-$run.txt"
        echo "$(date -u +%FT%TZ) no $TOK line; nudging #$NOSTAT_N" >> "$LOG"
        cont_save=$cont; cont="$R/.drv-nostat-$run.txt"; send_cont fix; cont=$cont_save; zz 20
      else
        echo "<no $TOK line> (after $((NOSTAT_N-1)) nudges)"; $Sd/rt2.sh "$run" 3000; echo "DRIVER_EXIT reason=lane_status"; exit 0
      fi ;;
    *"state=HANDBACK"*)
      # 2026-10-16 proc-coord (owner D2, tsp-mc9m.41.1030): a MERGE_READY is merged by merge-ready.sh, which then sends the
      # lane its next bead from fleet-board/lane-queue/<lane>.txt. Only a HOLD or an empty queue wakes gpu-14 (report D: lanes
      # idled ~2 h after MERGE_READY although the merge took <5 min). MERGE_READY_AUTO=0 restores the plain exit.
      # 2026-10-16 gpu-14 (owner D3 queues): a queued bead found already done is recorded for close at release and the
      # lane gets its next queue item without a gpu-14 turn. Empty queue or send failure exits to gpu-14 as before.
      case "$stl" in *"reason=ALREADY_COMPLETE"*|*"reason=ALREADY_MERGED"*)
        ab=$(printf '%s' "$stl" | grep -oE 'bead=[A-Za-z0-9._-]+' | head -n1 | cut -d= -f2)
        printf '%s\t%s\t-\t-\tmet\t%s\n' "${ab:-unknown}" "$run" "$(date -u +%FT%TZ)" >> "$R/fleet-board/close-pending.tsv"
        ao=$("$R/assign-next.sh" "$LANE_FAM" "$run" "$TOK" 2>>"$LOG" 9>&-); arc=$?
        echo "$(date -u +%FT%TZ) auto-advance rc=$arc $(printf '%s' "$ao" | tail -n1)" >> "$LOG"
        if [ "$arc" = 0 ]; then zz 20; return 0; fi ;;
      esac
      # 2026-10-16 proc-coord (owner D4a): a BOOT_READY naming pkg= gen= steps= label= is appended to the always-on window
      # queue (window-queue.sh) and the driver keeps watching: the window's bundle/receipts start the lane's next turn, so
      # the lane stays driven through the window (gpu-14: battsafe r2 had no driver at netready). Missing fields or a
      # refused add exit to gpu-14 as before. WINDOW_QUEUE_AUTO=0 restores the plain exit.
      case "$stl" in *"reason=BOOT_READY "*|*"reason=BOOT_READY")
        if [ "${WINDOW_QUEUE_AUTO:-1}" = 1 ] && printf '%s' "$stl" | grep -q 'gen=[0-9a-f]\{32\}'; then
          wq=$("$R/window-queue.sh" --add-from-status "$LANE_FAM" "$run" "$TOK" "$stl" 2>&1 9>&-); wqrc=$?
          echo "$(date -u +%FT%TZ) window-queue add rc=$wqrc $(printf '%s' "$wq" | tail -n1 | cut -c1-200)" >> "$LOG"
          if [ "$wqrc" = 0 ]; then zz 20; return 0; fi
        fi ;;
      esac
      case "$stl" in *"reason=MERGE_READY"*|*"reason=merge_ready"*)
        if [ "${MERGE_READY_AUTO:-1}" = 1 ]; then
          "$R/merge-ready.sh" "$run" "$TOK" "$LANE_FAM" "$stl" > "$R/.drv-mr-$run.txt" 2>>"$LOG" 9>&- &
          wait $!; mrc=$?; mr=$(tail -n 1 "$R/.drv-mr-$run.txt")
          echo "$(date -u +%FT%TZ) merge-ready rc=$mrc $mr" >> "$LOG"
          if [ "$mrc" = 0 ]; then zz 20; return 0; fi
          echo "$stl"; echo "$mr"; $Sd/rt2.sh "$run" 3000; echo "DRIVER_EXIT reason=lane_status merge_ready_rc=$mrc"; exit 0
        fi ;;
      esac
      case "$stl" in *"reason="*) echo "$stl"; $Sd/rt2.sh "$run" 3000; echo "DRIVER_EXIT reason=lane_status"; exit 0 ;; esac
      HBNR_N=$(( ${HBNR_N:-0} + 1 ))
      if [ "$HBNR_N" -le 1 ]; then
        { printf 'gpu-14 driver: your HANDBACK line has no reason= field, so gpu-14 cannot act on it. '; anchor_text; printf ' Then end with exactly one `%s state=...` line that names reason= (and pr=/head= when a PR is involved).\n' "$TOK"; } > "$R/.drv-hbnr-$run.txt"
        echo "$(date -u +%FT%TZ) HANDBACK without reason=; anchored restate #$HBNR_N" >> "$LOG"
        cont_save=$cont; cont="$R/.drv-hbnr-$run.txt"; send_cont fix; cont=$cont_save; zz 20
      else
        echo "$stl (no reason= after 1 anchored restate)"; $Sd/rt2.sh "$run" 3000; echo "DRIVER_EXIT reason=lane_status"; exit 0
      fi ;;
    *) echo "${stl:-<no $TOK line>}"; $Sd/rt2.sh "$run" 3000; echo "DRIVER_EXIT reason=lane_status"; exit 0 ;;
  esac
}
last=$(rtotal) || { echo "DRIVER_EXIT reason=result_unreadable"; exit 0; }
# 2026-10-11 (kitlint #8): the lane answered gpu-14's message in the seconds before this driver started, so
# result #$last was never processed and the driver waited forever for #$((last+1)). If no driver has logged
# result #$last for this run, treat it as new.
if [ "${last:-0}" -gt 0 ] 2>/dev/null && ! /usr/bin/grep -q "status(result#$last)" "$LOG" 2>/dev/null; then
  echo "$(date -u +%FT%TZ) result #$last was never processed by a driver; handling it now" >> "$LOG"; last=$((last-1))
fi
# 2026-10-12 (cargv pft-1f4ded9d idle 2.5 h; lin pft-fe54e79f idle 34 min): gpu-14 fixed why the previous driver
# exited and restarted it WITHOUT sending a message. Result #$last was already processed, so this driver waited for a
# turn nothing would start. After a grace period for a just-sent message, if the run is still idle on that result:
# re-handle a status the driver acts on (CI_WAIT, CONTINUE...), and exit at once on any other status.
if [ "${last:-0}" -gt 0 ] 2>/dev/null && /usr/bin/grep -q "status(result#$last)" "$LOG" 2>/dev/null; then
  zz "${RESTART_GRACE_S:-90}"
  read -r st0 _g0 _m0 < <(rstate) || st0="?"
  if [ "$st0" = awaiting_release ] && [ "$(rtotal)" = "$last" ]; then
    stl0=$($Sd/rt2.sh "$run" 30000 2>&1 | /usr/bin/grep -E "^\**\`?${TOK}" | tail -n 1)
    case "$stl0" in
      *"state=CI_WAIT"*|*"state=CONTINUE"*|*"state=WORKING"*|*"state=IN_PROGRESS"*|*"state=REVIEW_WAIT"*|*"state=BUILD_WAIT"*|*"reason=CHECKS_PENDING"*|*"reason=CI_PENDING"*|*"reason=UNRELATED_CI_FAILURE"*|*"reason=CI_INFRA_"*|*"reason=CI_FLAKE"*|*"reason=CI_NOISE"*)
        echo "$(date -u +%FT%TZ) restarted on processed result #$last with no new turn; re-handling: ${stl0:0:160}" >> "$LOG"; last=$((last-1)) ;;
      *"state=WAITING"*|*"state=WINDOW_STEP"*|*"state=WINDOW_WAIT"*) : ;;
      *) echo "$(date -u +%FT%TZ) restarted on processed result #$last with no new turn and no message; exiting" >> "$LOG"
         echo "${stl0:-<no $TOK line>}"; echo "DRIVER_EXIT reason=restarted_without_message hint=lane-msg the run first, then start its driver"; exit 0 ;;
    esac
  fi
fi
echo "$(date -u +%FT%TZ) driver start run=$run last_result=$last" >> "$LOG"
if [ "$V2_CAP" = 1 ]; then
  # v2 still enforces max_messages.  Discover that run's actual admission bound
  # and rotate before refusal.  v3 never enters this count-based path.
  if [ -z "$ROTATE_AT_ENV" ]; then
    rb=$(python3 - "$R" "$run" <<'PYB'
import json, pathlib, sys
r, run = pathlib.Path(sys.argv[1]), sys.argv[2]
vals = set()
for adm in r.glob("admission-*.json"):
    try:
        if json.loads(adm.read_text()).get("run_id") != run: continue
        m = (json.loads((r / ("run-" + adm.name[len("admission-"):])).read_text()).get("bounds") or {}).get("max_messages")
        if isinstance(m, int): vals.add(m)
    except Exception: pass
print(vals.pop() if len(vals) == 1 else "")
PYB
)
    if [ -z "$rb" ]; then
      rb=$(awk -F'\t' -v r="$run" '$1==r && $2 ~ /^[0-9]+$/ {print $2}' "$R/run-bounds.tsv" 2>/dev/null | sort -u)
      [ "$(printf '%s\n' "$rb" | grep -c .)" -le 1 ] || rb=""
    fi
    if [ -n "$rb" ] && [ "$rb" -gt 8 ]; then ROTATE_AT=$((rb - 4)); fi
  fi
  echo "$(date -u +%FT%TZ) rotate_at=$ROTATE_AT home=v2" >> "$LOG"
else
  echo "$(date -u +%FT%TZ) rotation=not_applicable home=v3" >> "$LOG"
fi
set_children "$($Sd/rt2.sh "$run" 30000 2>&1)"
t0=$(date +%s)
while :; do
  # 2026-10-14 17:29Z: a transient pf-task "database is locked" (gpu-14's own read-only journal scan) made rstate fail
  # once and killed the a1w3 (window owner) and rlint drivers. Retry before giving up.
  rs_ok=0; for rs_try in 1 2 3 4 5 6; do
    if read -r st G MSGS < <(rstate) && [ -n "${st:-}" ]; then rs_ok=1; break; fi
    echo "$(date -u +%FT%TZ) rstate unreadable (try $rs_try/6); retrying in 20 s" >> "$LOG"; sleep 20
  done
  [ "$rs_ok" = 1 ] || { echo "DRIVER_EXIT reason=status_unreadable"; exit 0; }
  if [ "$V2_CAP" = 1 ] && [ "$st" = awaiting_release ] && [ "${MSGS:-0}" -ge "$ROTATE_AT" ]; then
    if [ "$ROT_SENT" -eq 0 ]; then
      printf 'gpu-14 driver: messages.total=%s has reached the rotation threshold (%s). Do NOT start new work. Coordinator: run checkpoint.update now with the full live state (every in-flight run as a FULL id). Worker: commit and push your branch, then post a bd comment on your bead with the pushed head SHA, what is done, what remains and the exact next step. Then end with your status line state=HANDBACK reason=message_budget_rotation. gpu-14 will start your next generation.\n' "$MSGS" "$ROTATE_AT" > "$R/.drv-rot-$run.txt"
      echo "$(date -u +%FT%TZ) rotation due msgs=$MSGS; sending rotation instruction" >> "$LOG"
      ROT_SENT=1; ROT_T=$(date +%s); cont_save=$cont; cont="$R/.drv-rot-$run.txt"; send_cont fix; cont=$cont_save; zz 20; continue
    elif [ "$(rtotal)" -gt "$last" ] 2>/dev/null; then
      :
    elif [ $(( $(date +%s) - ROT_T )) -ge 300 ]; then
      echo "DRIVER_EXIT reason=rotation_due msgs=$MSGS"; exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$wall" ] && { echo "DRIVER_EXIT reason=wall_cap"; exit 0; }
  if [ "$st" = awaiting_release ]; then
    tot=$(rtotal) || { echo "DRIVER_EXIT reason=result_unreadable"; exit 0; }
    if [ "$tot" -gt "$last" ]; then process_status; t0=$(date +%s); continue; fi
    if child_moved; then
      mv_c=${MV% *}; why=${MV##* }
      case "$why" in
        state_permission_blocked) what="is waiting on YOUR APPROVAL (permission_blocked). Read its pending request in run.status/rollout and answer it with run.permission (once/reject) now" ;;
        state_blocked|state_unavailable|state_failed) what="is STUCK (${why#state_}). Read its run.status blocker (e.g. child_processes_after_turn: leftover REPL children) and clear or route it now" ;;
        all_children_idle) what="are ALL idle (awaiting_release, no turn running) while you report WAITING, so nothing will wake you. For EACH: continue it with run.send for its remaining acceptance, verify+release it, or record it explicitly parked. If nothing is left in flight, end with state=IDLE (that wakes gpu-14), not WAITING" ;;
        result_arrived_during_your_last_turn) what="has a result that landed DURING your last turn and may be unprocessed. Process it now (verify, release, record, next)" ;;
        *) what="has a NEW RESULT (its turn ended). Process it now (verify, release, record, next)" ;;
      esac
      printf 'gpu-14 driver: watched run %s %s, then continue under your contract/brief. End with your status block; keep listing every in-flight run id.\n' "$mv_c" "$what" > "$R/.drv-child-$run.txt"
      echo "$(date -u +%FT%TZ) child $mv_c moved ($why); restarting lane" >> "$LOG"
      cont_save=$cont; cont="$R/.drv-child-$run.txt"; send_cont child; cont=$cont_save; t0=$(date +%s); zz 20; continue
    fi
    case "$LAST_STL" in *"state=WINDOW_STEP"*)
      read -r wst wgen wwhy < <(win_state)
      case "$wst" in failed|closed)
        echo "$(date -u +%FT%TZ) window $wgen is $wst ($wwhy) while the lane waits on WINDOW_STEP" >> "$LOG"
        echo "$LAST_STL"; echo "DRIVER_EXIT reason=window_$wst gen=$wgen detail=$wwhy"; exit 0 ;;
      esac
      # 2026-10-14 (slfl SSH-only window dadf9109): the lane ended a turn with WINDOW_STEP seq=1 after PLAN step 1, but
      # submitted no inbox step, so this driver waited 12 min for a receipt that could never come while the window
      # burned. If no inbox request for that seq exists after 120 s, nudge ONCE per status line with the exact fact.
      wseq=$(printf '%s' "$LAST_STL" | /usr/bin/grep -oE 'seq=[0-9]+' | head -n 1 | cut -d= -f2)
      if [ "$wst" = open ] && [ -n "$wseq" ] && [ "${WS_NUDGED:-}" != "$LAST_STL" ] && [ $(( $(date +%s) - t0 )) -ge 120 ] \
         && ! ls "$HOME/.local/state/pocketforge/kit-windows/$wgen/inbox/request-$(printf '%06d' "$wseq")-"*.json >/dev/null 2>&1; then
        printf 'gpu-14 driver: you reported WINDOW_STEP seq=%s, but window %s has NO inbox request for seq %s, so no receipt will ever arrive. WINDOW_STEP is only for an inbox step you submitted. If you meant a plan/SSH step, continue your plan now in this turn and do not end the turn between plan steps; end with WINDOW_DONE (or WINDOW_STEP only after a real submission).\n' "$wseq" "$wgen" "$wseq" > "$R/.drv-wsnudge-$run.txt"
        echo "$(date -u +%FT%TZ) WINDOW_STEP seq=$wseq has no inbox request in $wgen; nudging" >> "$LOG"
        WS_NUDGED=$LAST_STL; cont_save=$cont; cont="$R/.drv-wsnudge-$run.txt"; send_cont wsnudge; cont=$cont_save; t0=$(date +%s); zz 20; continue
      fi
      # 2026-10-15 (gwin batch12 27f16b6a): the seq=1 receipt landed at 22:04:26Z, 44 s BEFORE the lane's turn ended, so
      # its delivery was absorbed into that turn and no new turn ever started. The lane idled 25 min toward the window's
      # 1 h idle close while this driver "waited for delivery" (NUDGE_S is 2.5 h). If a receipt for the awaited seq
      # exists and no new turn came within 120 s, send its path ONCE per status line.
      wrc=$(ls "$HOME/.local/state/pocketforge/kit-windows/$wgen/receipts/receipt-$(printf '%06d' "${wseq:-x}")-"*.json 2>/dev/null | head -n 1)
      if [ "$wst" = open ] && [ -n "$wrc" ] && [ "${WR_NUDGED:-}" != "$LAST_STL" ] && [ $(( $(date +%s) - t0 )) -ge 120 ]; then
        printf 'gpu-14 driver: the receipt for your WINDOW_STEP seq=%s already exists (%s, sha256 %s) but no new turn started, so you never processed it. Verify it and continue your window plan NOW in this turn. End with your status block.\n' "$wseq" "$wrc" "$(sha256sum "$wrc" | cut -c1-64)" > "$R/.drv-wrnudge-$run.txt"
        echo "$(date -u +%FT%TZ) WINDOW_STEP seq=$wseq receipt exists ($wrc) but no new turn; nudging" >> "$LOG"
        WR_NUDGED=$LAST_STL; cont_save=$cont; cont="$R/.drv-wrnudge-$run.txt"; send_cont wrnudge; cont=$cont_save; t0=$(date +%s); zz 20; continue
      fi ;;
    esac
    if [ $(( $(date +%s) - t0 )) -ge "$NUDGE_S" ]; then
      echo "$(date -u +%FT%TZ) no new turn in ${NUDGE_S}s; nudging" >> "$LOG"; send_cont nudge; t0=$(date +%s); zz 20; continue
    fi
    zz 60; continue
  fi
  run_supervisor "$G" > "$R/.drv-supout-$run.txt" 2>&1 9>&- &
  wait $!; rc=$?; out=$(cat "$R/.drv-supout-$run.txt")
  te=$(printf '%s\n' "$out" | /usr/bin/grep -E '^TURN_END' | tail -n 1)
  echo "$(date -u +%FT%TZ) rc=$rc $te" >> "$LOG"
  # 2026-10-10: rc 11 = COMPLETED_UNRECORDED (tsp-mwo3a no_timeout variant). The supervisor saved the turn's
  # final text; print the lane's own status line from it so the wake carries the real handback, not a bare rc.
  if [ "$rc" -eq 11 ]; then
    ft=$(printf '%s\n' "$out" | /usr/bin/grep -oE 'final_text=[^ ]+' | tail -n 1 | cut -d= -f2-)
    if [ -n "$ft" ] && [ -f "$ft" ]; then
      st=$(/usr/bin/grep -E "^${TOK}[[:space:]]+state=" "$ft" | tail -n 1)
      echo "$(date -u +%FT%TZ) unrecorded_final=$ft ${st:-no_status_line}" >> "$LOG"
      echo "UNRECORDED_FINAL file=$ft"; echo "${st:-${TOK} state=UNKNOWN reason=no_status_line_in_final_text}"
    fi
  fi
  # 2026-10-11: rc 12 = RECONCILER_DEAD. An OpenCode run's pf-task reconciler died and its native session
  # is idle, so pf-task never recorded the turn end (qwm 2.4 h, dsk 25 min). run.send restarts the
  # reconciler; the message asks the lane to restate its last status block. At most 3 per driver.
  if [ "$rc" -eq 12 ] && [ "${RECON_N:-0}" -lt 3 ]; then
    RECON_N=$(( ${RECON_N:-0} + 1 )); rd=$(printf '%s\n' "$out" | /usr/bin/grep -E '^RECONCILER_DEAD' | tail -n 1)
    printf 'gpu-14 driver: your last turn ended natively but pf-task did not record it (its reconciler had died); this message re-opens the run. If that turn already ended with a `%s state=...` line, restate that status block exactly and end, doing no new work. Otherwise continue your current task and end with your status line.\n' "$TOK" > "$R/.drv-recon-$run.txt"
    echo "$(date -u +%FT%TZ) $rd; sending reconcile #$RECON_N" >> "$LOG"
    cont_save=$cont; cont="$R/.drv-recon-$run.txt"; send_cont fix; cont=$cont_save; t0=$(date +%s); zz 30; continue
  fi
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" | tail -n 5; echo "DRIVER_EXIT reason=supervisor_rc_$rc"; exit 0; }
  # 2026-10-06: a pf-task turn_timeout shows `blocked` for a moment and then auto-continues
  # (pft-29096f03 at 03:20Z: blocked -> busy within seconds). Recheck before exiting.
  case "$te" in *"state=awaiting_release"*) ;; *)
    # A turn that timed out while a bounded command still runs stays `blocked:
    # child_processes_after_turn` until that command exits (pft-e3a47929 03:39Z: a 1200 s
    # timeout-wrapped CI job). Wait up to 30 min for it; any other blocker exits as before.
    rs=""; for _i in $(seq 1 30); do zz 60; rs=$(rstate | awk '{print $1}')
      # 2026-10-06 23:2xZ: a transient `pending` right after an auto-continue exited the .924.29.16 driver.
      case "$rs" in busy|awaiting_release) break ;; pending|admitted|starting) continue ;; blocked)
        rb=$(timeout 200 $PFT --home $H --role coordinator run.status "{\"run_id\":\"$run\"}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("blocker") or {}).get("blocker") or {}).get("text",""))' 2>/dev/null)
        case "$rb" in child_processes_after_turn*) [ "$_i" = 1 ] && echo "$(date -u +%FT%TZ) blocked on bounded children after turn; waiting (<=30m): $(printf %s "$rb" | tr "\n" " " | cut -c1-400)" >> "$LOG" ;; *) break ;; esac ;;
      *) break ;; esac; done
    if [ "$rs" = busy ] || [ "$rs" = awaiting_release ]; then echo "$(date -u +%FT%TZ) turn_state $te then busy (auto-continued); keep watching" >> "$LOG"; t0=$(date +%s); continue; fi
    echo "$te"; echo "DRIVER_EXIT reason=turn_state now=$rs"; exit 0 ;; esac
  process_status; t0=$(date +%s)
done
