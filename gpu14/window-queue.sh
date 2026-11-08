#!/usr/bin/env bash
# proc-coord 2026-10-16 (tsp-mc9m.41.1030; owner decision D4a): always-on kit-window queue. gpu-14 hand-ran every
# BOOT_READY -> preflight -> window-chain -> wait -> close by hand (gpu14-window-checklist.md), so each window cost a
# gpu-14 turn at both ends and the bench idled between them. This loop pops the head row of
# fleet-board/window-queue.tsv, runs kit-preflight.sh, runs window-chain.sh exactly as gpu-14 calls it, waits for the
# window to end, closes it with window-close.sh, and takes the next row. It wakes gpu-14 (its run_in_background exit)
# only on a stop. What stays with gpu-14: queue ORDER (edit the tsv), Build-16/lockup-last judgement, FEL diagnosis.
#
# usage: window-queue.sh [--once|--drain] [--dry-run]     run the loop (default: forever, idles on an empty queue)
#        window-queue.sh --add [--supersedes <gen-prefix>] <lane-fam> <owner-run> <TOKEN> <pkg-dir> <gen> <steps> <label> [note]
#        window-queue.sh --add-from-status [--supersedes <gen-prefix>] <lane-fam> <owner-run> <TOKEN> "<HANDBACK reason=BOOT_READY ... line>"
#                       (without the flag, a supersedes=<gen-prefix> token anywhere in the status line is used)
#        window-queue.sh --done <gen> success|failure|complete|incomplete   (gpu-14 or the lane-drive hook: the plan ended)
#        window-queue.sh --resume complete|incomplete   (after diagnosing a STOP: records the stopped window, archives pause+active)
#        window-queue.sh --done-from-status <owner-run> '<lane WINDOW_DONE line with gen= plan=>'
#        window-queue.sh --has <gen>     rc 0 queued, 4 active, 3 NEEDS file exists, 1 unknown/finished
#        window-queue.sh --status
#        window-queue.sh --recheck  right after a runner redeploy: re-run kit-preflight (read-only) over every queued and
#                                   attended-held row, print one RECHECK line per row, tell each failing lane once per
#                                   (gen, deployed sha), write one NEEDS summary; never edits/fails/removes a row.
#                                   rc 0 done; 2 refused (usage, no preflight, runner tree unknown, dirty or not the
#                                   recorded pa-<sha8>); 5 another recheck runs; 6 NEEDS/ledger state not persisted
# Row (tab-separated): ts lane-fam owner-run TOKEN package-dir generation steps label note. First non-comment = next.
# Loop rc: 0 done (--once/--drain/paused-drain), 1 dry-run preflight FAIL, 2 usage, 5 refused (already running,
#          paused at start, another window open, unresolved active item), 10 STOP (pause file + NEEDS written).
# Stop rules (no retry loops, memory no-retry-loops-in-fel-device-entry): a second consecutive ordinary boot-open
# failure, any node/FEL, power-safety or unreadable boot-open failure, window open but handoff failed, close failed,
# teardown failed, unknown chain outcome, or window wait timeout.  A successful boot-open resets the breaker.
# 2026-10-26 (tsp-mc9m.41.1030.56.54): warm-reuse refusals (REUSE_*, except REUSE_RECOVERY_FORCE_OFF_FAILED) and runner
# contract/request refusals (RESUME_ADAPTER_*, RESUME_REQUEST_*, RESUME_ANCHOR_*, RESUME_SCHEMA_*, the receipt-exists/path
# codes) are ordinary boot-open failures: 36.7 of 166 DUT-hours (10-20..10-26) were STOPs, and after 31 of 52 boot STOPs the
# next chain opened with no change.  --add/--add-from-status may name a supersedes=<gen-prefix>: the same owner run's one
# QUEUED row with that prefix is withdrawn in the add's own rewrite (an active window is the runner's, never the queue's).
# A preflight FAIL or a pre-boot CHAIN_STOP only fails that row (failed.tsv + needs/window-<kind>-<gen>.txt) and the
# loop continues: nothing reached the device.
# A WINDOW_DONE plan=incomplete (--done failure, owner_blocked) close is the normal end of a window: once window-close
# rc 0 + State=closed + the post-close USB gate pass it is recorded DONE closed:failure and the loop continues. A runner
# that closed ITSELF with a non-success reason (timeout/abort/unknown) still STOPs.
# Startup reconciliation classifies, gates and may STOP only for the generation the queue owns (ACTIVE or a queued
# row). Receipts and runner dirs under the kit-windows root are never removed, so everything else is history: a
# missing verdict is recorded exactly once (reconciled_at_start) and never re-trips the breaker or a resumed STOP.
# Test seams: GPU14_ROOT, WQ_BOARD, PF_KIT_WINDOWS_DIR, WQ_PREFLIGHT, WQ_ADMISSION_CHECK, WQ_CHAIN, WQ_CLOSE, WQ_POST_CLOSE_USB,
#             WQ_POLL_S, WQ_WINDOW_MAX_S,
#             WQ_PROBE, WQ_OWNER_MODEL, WQ_DRIVER_ALIVE, WQ_DISPOSITION, WQ_COMMS, WQ_NOTE_FROM, WQ_NOTE_TO,
#             WQ_BASE_AFFINITY, WQ_ORDER_TOOL, WQ_LANE_SEND, WQ_RECHECK_PREFLIGHT_S, WQ_AUTOMATION_TOOL,
#             WQ_SYSTEMCTL, PF_WINDOW_RUNNER_REPO (--recheck test seam), PF_KIT_ACTIVE_RUNNER_PUBLICATION,
#             WQ_OWNER_SAMPLE_S, WQ_OWNER_TRANSIENT_MAX_S,
#             WQ_OWNER_TRANSIENT_REASONS (owner-blocked sampling, below).
# 2026-10-26 (tsp-mc9m.41.1030.78): an OwnerRun `blocked` sample no longer closes a live window by itself. pf-task
# reports `blocked` for a bounded, self-clearing reason too (child_processes_after_turn: a timed-out turn's child
# command still runs; lane-drive.sh waits it out for up to 30 min), and a single-sample close destroyed gen 5b59a359
# at 13:15:59Z after the block had cleared on its own about 3 min later. The reason is run.status
# .blocker.blocker.text (the token before the first ':'). Transient reason: keep the window, re-sample, close with
# failure only once the same block has persisted WQ_OWNER_TRANSIENT_MAX_S (1800 s). Known non-transient reason:
# close on the first blocked sample as before. Missing or unreadable reason: fail safe for the device, close on the
# second consecutive blocked sample (WQ_OWNER_SAMPLE_S, 300 s, apart). Every decision is one typed log line:
# OWNER_BLOCKED_TRANSIENT (kept) / OWNER_BLOCKED (closed) / OWNER_BLOCKED_CLEARED, with gen= reason= age=.
# 2026-10-20 (tsp-mc9m.41.1030.56.2): a failed close gets ONE runner-validated first step (window-close.sh
# --auto-first-step: de-energized safe teardown -> acknowledge-safe; stale pinned adapter -> recover-close). The queue
# never decides safety: it advances only on AUTO_RECOVERED + rc 0 + runner State=closed + disposition RUN, logs
# AUTO_RECOVERED, appends window-queue.auto-recovered.tsv and sends proc-coord a pf-comms note. Anything else: STOP.
#        window-queue.sh --next     refresh capacity holds; print the generation that would open next (rc 6 = all held)
# 2026-10-19 (drc window 14759329 lost to a gpt-5.6-sol retry_limit_429 mid-window): before choosing a row, owners whose
# Codex model probe says full are HELD (fleet-board/window-queue.held) and skipped; later rows still run. A probe error
# does not hold (the probe must not wedge the queue); only a positive 'full' does.
set -uo pipefail
unset -f grep 2>/dev/null || true
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTOMATION_SCRIPTS=$(cd "$SELF/.." && pwd)
FB_INPUT=${WQ_BOARD:-$R/fleet-board}
FB=$(realpath -m -- "$FB_INPUT") \
  || { echo "WINDOW_QUEUE_EXIT reason=board_path_unresolvable path=$FB_INPUT"; exit 5; }
# A sibling lock exists before the board and excludes archive's final read/delete.
Q=$FB/window-queue.tsv; QL=$FB.lock; RL=$FB/.window-queue.run.lock; PAUSE=$FB/window-queue.pause
COMPAT=$FB/.window-queue.archive-compatible.lock
FAILED=$FB/window-queue.failed.tsv; DONE=$FB/window-queue.done.tsv; ACTIVE=$FB/window-queue.active
REQUEUE=$FB/window-queue.requeue.tsv
BOOT_STREAK=$FB/window-queue.boot-open-streak
PREFER=$FB/window-queue.prefer; NEEDS=$FB/needs; MARK=$FB/window-done; LOGD=$FB/window-queue-logs; OVR=$FB/window-queue.overrides.tsv; LOG=$FB/window-queue.log
WIN=${PF_KIT_WINDOWS_DIR:-$HOME/.local/state/pocketforge/kit-windows}
PROBE=${WQ_PROBE:-$R/model-capacity-probe.sh}; OWNER_MODEL=${WQ_OWNER_MODEL:-$R/owner-model.sh}; HELD=$FB/window-queue.held
DRIVER_ALIVE=${WQ_DRIVER_ALIVE:-}
PREFLIGHT=${WQ_PREFLIGHT:-$SELF/kit-preflight.sh}; ADMISSION_CHECK=${WQ_ADMISSION_CHECK:-$SELF/kit-admission-check.sh}
CHAIN=${WQ_CHAIN:-$R/window-chain.sh}; CLOSE=${WQ_CLOSE:-$R/window-close.sh}
# Dynamic-scope call inputs for run_preflight: per-generation overrides, runner
# authority env and an optional timeout prefix, exactly as each caller passed them.
declare -a ovenv=() runner_env=() preflight_timeout=()
ACTIVE_RUNNER_PUBLICATION=${PF_KIT_ACTIVE_RUNNER_PUBLICATION:-$HOME/.local/state/pocketforge/kit-window-runner/active-clone.json}
POST_CLOSE_USB=${WQ_POST_CLOSE_USB:-$SELF/post-close-usb-check.sh}
POLL=${WQ_POLL_S:-30}; MAXWIN=${WQ_WINDOW_MAX_S:-10800}
# runner_deploy_pending (a coordinator runner deploy is draining boot-opens) is a WAIT: retry every DEPLOY_PENDING_S,
# give up (normal boot_open_failed STOP) after DEPLOY_PENDING_MAX (the drain marker's own 3 h ceiling).
DEPLOY_PENDING_S=${WQ_DEPLOY_PENDING_S:-30}; DEPLOY_PENDING_MAX=${WQ_DEPLOY_PENDING_MAX_S:-10800}; DEPLOY_PENDING_SINCE=
OB_SAMPLE_S=${WQ_OWNER_SAMPLE_S:-300}; OB_TRANSIENT_MAX_S=${WQ_OWNER_TRANSIENT_MAX_S:-1800}
OB_TRANSIENT_REASONS=${WQ_OWNER_TRANSIENT_REASONS:-child_processes_after_turn}  # the one bounded wait lane-drive.sh waits out
[[ $OB_SAMPLE_S =~ ^[0-9]+$ ]] || OB_SAMPLE_S=300; [[ $OB_TRANSIENT_MAX_S =~ ^[0-9]+$ ]] || OB_TRANSIENT_MAX_S=1800
DISPOSITION=${WQ_DISPOSITION:-$R/window-disposition.sh}; COMMS=${WQ_COMMS:-pf-comms}
NOTE_FROM=${WQ_NOTE_FROM:-gpu-14}; NOTE_TO=${WQ_NOTE_TO:-gpu-14}; AUTOREC=$FB/window-queue.auto-recovered.tsv
BASE_AFFINITY=${WQ_BASE_AFFINITY:-0}
ORDER_TOOL=${WQ_ORDER_TOOL:-$AUTOMATION_SCRIPTS/pf-window-queue-order.py}
SYSTEMCTL=${WQ_SYSTEMCTL:-systemctl}
# Measured over 127 success-closed kit windows (n=928 idle waits: p50=54s p95=210s
# max=1884s).  5400s is the owner's attended-bench cap and the largest IdleSeconds
# any queued lane declares; the fixed 600s bound rejected every row on 2026-10-26.
UNATTENDED_IDLE_MIN=300; UNATTENDED_IDLE_MAX=5400
ROW_INVALID_FAILURES=0
SUPERSEDE_REPO=
SUPERSEDE_TRUSTED=
SUPERSEDES=
declare -A LOGGED_ONCE=()
BACKTICK=$(printf '\140')
ts() { date -u +%FT%TZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
say_once() {  # say_once <key> <line...>: log the line the first time this process sees the key (wait-loop polls repeat refusals)
  local k
  k=$(printf '%s' "$1" | md5sum | cut -d' ' -f1); shift
  [ -z "${LOGGED_ONCE[$k]:-}" ] || return 0
  LOGGED_ONCE[$k]=1
  say "$@"
}
board_lock() {  # fd 7 means the caller already holds QL; otherwise use fd 9.
  [ -e "/proc/$BASHPID/fd/7" ] && return 0
  exec 9>>"$QL" || return 1
  flock -w 30 9 || { exec 9>&-; return 1; }
}
board_unlock() {
  [ -e "/proc/$BASHPID/fd/7" ] || exec 9>&-
}
mkdir -p "$(dirname "$FB")"
exec 7>>"$QL"; flock -w 30 7 || { echo "WINDOW_QUEUE_EXIT reason=queue_lock_timeout"; exit 5; }
mkdir -p "$FB" "$NEEDS" "$MARK" "$LOGD"
[ -f "$Q" ] || printf '# ts\tlane-fam\towner-run\tTOKEN\tpackage-dir\tgeneration\tsteps\tlabel\tnote  (first non-comment row is next; gpu-14 reorders by editing)\n' > "$Q"
exec 7>&-
snooze() { sleep "$1" 8>&-; }

validate() {  # validate <lane> <owner> <TOKEN> <pkg> <gen> <steps> <label>; prints reason on failure
  [[ $1 =~ ^[A-Za-z0-9._-]{1,40}$ ]] || { echo lane_fam_invalid; return 1; }
  [[ $2 =~ ^pft-[0-9a-f]{24}$ ]] || { echo owner_run_invalid; return 1; }
  [[ $3 =~ ^[A-Z0-9_]{2,40}$ ]] || { echo token_invalid; return 1; }
  [[ $4 == /* && -d $4 ]] || { echo package_dir_invalid; return 1; }
  [[ $5 =~ ^[0-9a-f]{32}$ ]] || { echo generation_invalid; return 1; }
  [[ $6 =~ ^[0-9]{1,3}$ ]] || { echo steps_invalid; return 1; }
  [[ $7 =~ ^[A-Za-z0-9._-]{1,40}$ ]] || { echo label_invalid; return 1; }
}
known_gen() { awk -F'\t' -v g="$1" '(!/^#/ || /^#withdrawn-/) && $6==g {f=1} END {exit !f}' "$Q" 2>/dev/null \
  || awk -F'\t' -v g="$1" '$2==g || $9==g {f=1} END {exit !f}' "$DONE" "$FAILED" 2>/dev/null \
  || grep -qx "gen=$1" "$ACTIVE" 2>/dev/null; }
running() { ( exec 8>>"$RL"; ! flock -n 8 ); }

package_request() {  # package_request <package>: sealed boot-open request path
  local f
  # Native packages seal only boot-open-request.template.json (FelBootRequest=
  # @STAGE_FROM_SEED_KIT@); window-chain.sh stages stage/boot-open-request.json
  # at chain time, so validation before the chain must fall back to the template,
  # which carries the same IdleSeconds/Generation/Window fields.
  for f in "$1/stage/boot-open-request.json" "$1/boot-open-request.json" "$1/boot-open-request.template.json"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}
validate_unattended_request() {  # validate_unattended_request <package> <generation>; prints request path or reason
  local request idle request_gen
  request=$(package_request "$1") \
    || { echo boot_open_request_missing; return 1; }
  idle=$(jq -er '.IdleSeconds | select(type == "number" and floor == .)' "$request" 2>/dev/null) \
    || { echo "unattended_idle_seconds_invalid idle_seconds=unreadable max=$UNATTENDED_IDLE_MAX"; return 1; }
  if [ "$idle" -lt "$UNATTENDED_IDLE_MIN" ] || [ "$idle" -gt "$UNATTENDED_IDLE_MAX" ]; then
    echo "unattended_idle_seconds_invalid idle_seconds=$idle max=$UNATTENDED_IDLE_MAX"; return 1
  fi
  # Identity is the Generation only.  Window.Lane carries the package label
  # (e.g. kleaf2-batch-3f59e5d9 for queue lane kleaf2) and never matched the
  # LANE column by design; requiring it rejected healthy rows on 2026-10-26.
  request_gen=$(jq -r '.Generation // empty' "$request" 2>/dev/null)
  if [ "$request_gen" != "$2" ]; then
    echo boot_open_request_identity_mismatch; return 1
  fi
  printf '%s\n' "$request"
}
clean_runner_reason() {
  case "$1" in success|lane_done|superseded_by_new_generation) return 0 ;; esac
  return 1
}
canonical_repo_is_trusted() {  # <literal-repo> <colon-separated-literal-trust>; rc 10 repo, 12 trust, 13 untrusted
  local repo=$1 trust=$2 repo_id entry entry_id found=0
  local -a entries=()
  [[ $repo == /* ]] || return 10
  repo_id=$(realpath -e -- "$repo" 2>/dev/null) || return 10
  [ -d "$repo_id" ] || return 10
  case "$trust" in :*|*::*|*:) return 12 ;; esac
  IFS=: read -r -a entries <<< "$trust"
  [ "${#entries[@]}" -gt 0 ] || return 12
  for entry in "${entries[@]}"; do
    [[ $entry == /* ]] || return 12
    entry_id=$(realpath -e -- "$entry" 2>/dev/null) || return 12
    [ -d "$entry_id" ] || return 12
    [ "$entry_id" != "$repo_id" ] || found=1
  done
  [ "$found" = 1 ] || return 13
}
resolve_supersede_repo() {  # results in SUPERSEDE_REPO and SUPERSEDE_TRUSTED
  # The runner service can be repaired or redeployed while this long-lived
  # queue process is polling one active/successor pair. Resolve every attempt;
  # say_once below suppresses repeated refusal log lines without
  # turning either a missing or previously valid path into stale state.
  local unit_env
  unit_env=$("$SYSTEMCTL" --user show pf-kit-window-runner.service \
    -p Environment --value 2>/dev/null | tr ' ' '\n')
  SUPERSEDE_REPO=$(printf '%s\n' "$unit_env" \
    | sed -n 's/^PF_KIT_AUTOMATION_REPO=//p' | head -1)
  SUPERSEDE_TRUSTED=$(printf '%s\n' "$unit_env" \
    | sed -n 's/^PF_KIT_TRUSTED_AUTOMATION_REPOS=//p' | head -1)
  [[ $SUPERSEDE_REPO == /* && -d $SUPERSEDE_REPO ]] || SUPERSEDE_REPO=
}
try_supersede() {  # try_supersede <old-gen> <successor-request> <active-label>; best effort, runner decides authority
  local old=$1 request=$2 label=${3:-} successor out rc key last why runner trust_rc
  # The runner supersedes only inside one package label (successor Window.Lane == active.json Lane) and refuses the
  # rest as supersede_different_lane, so a differing label is not sent.  There is no queue-side substitute: window-close.sh
  # takes success|failure only and, unlike supersede, does not refuse while a step is in flight.  The window stays with
  # its lane until WINDOW_DONE or idle expiry.
  successor=$(jq -r '.Window.Lane // empty' "$request" 2>/dev/null)
  if [ -n "$label" ] && [ "$successor" != "$label" ]; then
    say_once "skipped $old $request" "SUPERSEDE_SKIPPED reason=label_mismatch gen=$old active_label=$label successor_label=${successor:-none}"
    return 0
  fi
  key="$old $request"
  resolve_supersede_repo
  if [ -z "$SUPERSEDE_REPO" ]; then
    say_once "refused $key runner_repo_unresolved" "SUPERSEDE_REFUSED gen=$old reason=runner_repo_unresolved"
    return 0
  fi
  if [ -z "$SUPERSEDE_TRUSTED" ]; then
    say_once "refused $key runner_trust_configuration_missing" \
      "SUPERSEDE_REFUSED gen=$old reason=runner_trust_configuration_missing"
    return 0
  fi
  canonical_repo_is_trusted "$SUPERSEDE_REPO" "$SUPERSEDE_TRUSTED"; trust_rc=$?
  case "$trust_rc" in
    0) ;;
    10)
      say_once "refused $key runner_repo_unresolved" \
        "SUPERSEDE_REFUSED gen=$old reason=runner_repo_unresolved"
      return 0 ;;
    12)
      say_once "refused $key runner_trust_path_unresolved" \
        "SUPERSEDE_REFUSED gen=$old reason=runner_trust_path_unresolved"
      return 0 ;;
    *)
      say_once "refused $key runner_repo_not_deployed" \
        "SUPERSEDE_REFUSED gen=$old reason=runner_repo_not_deployed"
      return 0 ;;
  esac
  runner=$SUPERSEDE_REPO/scripts/pf-kit-window-runner
  if [ ! -x "$runner" ]; then
    say_once "refused $key deployed_runner_missing" \
      "SUPERSEDE_REFUSED gen=$old reason=deployed_runner_missing"
    return 0
  fi
  out=$(PF_KIT_AUTOMATION_REPO="$SUPERSEDE_REPO" \
    PF_KIT_TRUSTED_AUTOMATION_REPOS="$SUPERSEDE_TRUSTED" \
    "$runner" supersede "$old" --request "$request" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    say "SUPERSEDE_CLOSED gen=$old request=$request"
  else
    # The wait loop offers the same pair every poll and the runner answers the same way (supersede_different_bead: 89 lines in
    # an hour on 10-26): one line per (old generation, successor request, reason); a changed reason is new information.
    last=$(printf '%s' "$out" | tail -1 | cut -c1-240)
    why=$(printf '%s' "$out" | grep -oE 'reason=[A-Za-z0-9_]+' | tail -1)
    say_once "refused $key rc=$rc ${why:-$last}" "SUPERSEDE_REFUSED gen=$old rc=$rc $last"
  fi
  return 0
}
supersede_open_lane() {  # supersede_open_lane <queue-family> <successor-gen> <request>
  local lane=$1 successor=$2 request=$3 d old state active_lane ag al
  # The queue family (kleaf2) is not the runner's lane identity: active.json Lane is the package label
  # (kleaf2-batch-3f59e5d9).  The queue's own record of its active row (window-queue.active) maps family -> window;
  # any open window whose label already equals the family still matches.
  ag=$(sed -n 's/^gen=//p' "$ACTIVE" 2>/dev/null | head -1); al=$(sed -n 's/^lane=//p' "$ACTIVE" 2>/dev/null | head -1)
  for d in "$WIN"/*/; do
    [ -f "$d/active.json" ] && [ -f "$d/runner.json" ] || continue
    old=$(basename "$d"); [ "$old" != "$successor" ] || continue
    state=$(jq -r '.State // empty' "$d/runner.json" 2>/dev/null)
    [ "$state" = open ] || continue
    active_lane=$(jq -r '.Lane // empty' "$d/active.json" 2>/dev/null)
    [ "$active_lane" = "$lane" ] || { [ "$old" = "$ag" ] && [ "$al" = "$lane" ]; } || continue
    try_supersede "$old" "$request" "$active_lane"
  done
}
retry_queued_supersede() {  # retry_queued_supersede <old-gen> <queue-family>
  local old=$1 lane=$2 queued pkg successor request why
  queued=$(awk -F'\t' -v l="$lane" -v g="$old" \
    '!/^[[:space:]]*(#|$)/ && $2==l && $6!=g {print $5 "\t" $6; exit}' "$Q")
  [ -n "$queued" ] || return 0
  IFS=$'\t' read -r pkg successor <<< "$queued"
  if ! request=$(validate_unattended_request "$pkg" "$successor"); then
    why=$request
    say_once "refused $old $successor invalid $why" "SUPERSEDE_REFUSED gen=$old successor=$successor reason=$why"
    return 0
  fi
  try_supersede "$old" "$request" "$(jq -r '.Lane // empty' "$WIN/$old/active.json" 2>/dev/null)"
}

add_row() {  # add_row <lane> <owner> <TOKEN> <pkg> <gen> <steps> <label> <note>
  local why note request new_label now new_row row row_lane old_pkg old_gen old_request old_label
  local replace_row="" replace_gen="" different_gen="" tmp withdrawn
  local sup_row="" sup_gen="" sup_lane="" sup_skip="" sup_withdrawn="" sup_show="" sup_foreign=0 sup_n=0
  local -a sup_rows=()
  why=$(validate "$1" "$2" "$3" "$4" "$5" "$6" "$7") || { echo "WINDOW_QUEUE_ADD_REFUSED reason=$why"; return 2; }
  request=$(validate_unattended_request "$4" "$5") \
    || { echo "WINDOW_QUEUE_ADD_REFUSED reason=$request"; return 2; }
  if [ -e "$WIN/$5" ] || [ -e "$WIN/boot-open-$5.json" ] || [ -e "$WIN/boot-open-$5.failed.json" ]; then echo "WINDOW_QUEUE_ADD_REFUSED reason=generation_consumed gen=$5"; return 2; fi
  note=$(printf '%s' "${8:-}" | tr -d '\r\n' | tr '\t' ' ' | cut -c1-400)
  exec 7>>"$QL"; flock -w 30 7 || { echo "WINDOW_QUEUE_ADD_REFUSED reason=queue_lock_timeout"; return 2; }
  if known_gen "$5"; then exec 7>&-; echo "WINDOW_QUEUE_ADD_REFUSED reason=duplicate_generation gen=$5"; return 2; fi
  new_label=$(jq -r '.Window.Lane // empty' "$request" 2>/dev/null)
  if [ -n "$SUPERSEDES" ]; then
    # The lane's own re-seal names the generation it replaces (gen prefix, 7+ hex).  Match only a QUEUED row of the same
    # owner run, and only when exactly one row matches; the ACTIVE window is not in $Q and stays the runner's decision.
    sup_show=$(printf '%s' "$SUPERSEDES" | tr -c 'A-Za-z0-9' '_' | cut -c1-40)
    if [[ $SUPERSEDES =~ ^[0-9a-f]{7,32}$ ]]; then
      mapfile -t sup_rows < <(awk -F'\t' -v p="$SUPERSEDES" -v o="$2" -v n="$5" \
        '!/^[[:space:]]*(#|$)/ && $3==o && $6!=n && index($6,p)==1' "$Q")
      sup_foreign=$(awk -F'\t' -v p="$SUPERSEDES" -v o="$2" -v n="$5" \
        '!/^[[:space:]]*(#|$)/ && $3!=o && $6!=n && index($6,p)==1 {c++} END {print c+0}' "$Q")
      sup_n=${#sup_rows[@]}
      case $sup_n in
        0) sup_skip="no_queued_match prefix=$sup_show gen=$5 matches=0 other_owner_rows=$sup_foreign" ;;
        1) sup_row=${sup_rows[0]}; sup_gen=$(printf '%s' "$sup_row" | cut -f6); sup_lane=$(printf '%s' "$sup_row" | cut -f2) ;;
        *) sup_skip="ambiguous prefix=$sup_show gen=$5 matches=$sup_n other_owner_rows=$sup_foreign" ;;
      esac
    else
      sup_skip="prefix_invalid prefix=$sup_show gen=$5"
    fi
  fi
  while IFS= read -r row; do
    IFS=$'\t' read -r _ row_lane _ _ old_pkg old_gen _ _ _ <<< "$row"
    [ "$row_lane" = "$1" ] || continue
    old_request=$(package_request "$old_pkg" 2>/dev/null) || continue
    old_label=$(jq -r '.Window.Lane // empty' "$old_request" 2>/dev/null)
    if [ -n "$new_label" ] && [ "$old_label" = "$new_label" ]; then
      if [ -z "$replace_row" ]; then replace_row=$row; replace_gen=$old_gen; fi
    elif [ -z "$different_gen" ] && [ "$row" != "$sup_row" ]; then  # a row this add withdraws is no longer "queued"
      different_gen=$old_gen
    fi
  done < <(awk '!/^[[:space:]]*(#|$)/' "$Q")
  now=$(ts)
  new_row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$now" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$note")
  # The same-label reseal below already withdraws that very row in place: one withdrawal per row.
  [ -z "$sup_row" ] || [ "$sup_row" != "$replace_row" ] || { sup_row=; sup_gen=; }
  if [ -n "$replace_row" ] || [ -n "$sup_row" ]; then
    # Match the queue's other lock-held rewrites: a same-directory process-unique
    # temporary keeps the queue's normal umask/group readability after mv.
    # One awk pass, one mv: the same-label reseal (new row takes the old row's place), the supersedes withdrawal (the old
    # row stays in place as a comment, the new row is appended) or both.  A refused add rewrites nothing.
    tmp=$Q.tmp.$$
    withdrawn="#withdrawn-auto-${now//[-:]/} superseded-by-$5 same_label_reseal $replace_row"
    sup_withdrawn="#withdrawn-auto-${now//[-:]/} superseded-by-${5:0:8} $sup_row"
    if ! WQ_OLD_ROW="$replace_row" WQ_NEW_ROW="$new_row" WQ_WITHDRAWN_ROW="$withdrawn" \
      WQ_SUP_ROW="$sup_row" WQ_SUP_WITHDRAWN_ROW="$sup_withdrawn" \
      awk 'BEGIN {rr = ENVIRON["WQ_OLD_ROW"]; sr = ENVIRON["WQ_SUP_ROW"]}
           rr != "" && !rd && $0 == rr {print ENVIRON["WQ_WITHDRAWN_ROW"]; print ENVIRON["WQ_NEW_ROW"]; rd=1; next}
           sr != "" && !sd && $0 == sr {print ENVIRON["WQ_SUP_WITHDRAWN_ROW"]; sd=1; next}
           {print}
           END {if (rr == "") print ENVIRON["WQ_NEW_ROW"]; exit !((rr == "" || rd) && (sr == "" || sd))}' \
        "$Q" > "$tmp" || ! mv -f "$tmp" "$Q"; then
      rm -f "$tmp"
      exec 7>&-
      echo "WINDOW_QUEUE_ADD_REFUSED reason=queue_rewrite_failed"
      return 2
    fi
  else
    printf '%s\n' "$new_row" >> "$Q" \
      || { exec 7>&-; echo "WINDOW_QUEUE_ADD_REFUSED reason=queue_write_failed"; return 2; }
  fi
  exec 7>&-
  [ -z "$replace_gen" ] \
    || say "WITHDRAWN gen=$replace_gen superseded_by=$5 lane=$1 label=$new_label reason=same_label_reseal"
  [ -z "$sup_row" ] \
    || say "WITHDRAW gen=$sup_gen lane=${sup_lane:-$1} by=window-queue reason=superseded-by-${5:0:8} supersedes=$sup_show"
  [ -z "$sup_skip" ] || say "SUPERSEDE_QUEUED_SKIPPED reason=$sup_skip"
  [ -z "$different_gen" ] \
    || say "ADD_SAME_LANE_DIFFERENT_LABEL gen=$5 queued=$different_gen"
  say "ADD gen=$5 lane=$1 label=$7 depth=$(grep -cvE '^[[:space:]]*(#|$)' "$Q")"
  supersede_open_lane "$1" "$5" "$request"
  if running && [ ! -f "$PAUSE" ]; then echo "WINDOW_QUEUE_ADDED gen=$5 running=1"; return 0; fi
  echo "WINDOW_QUEUE_ADDED gen=$5 running=$(running && echo 1 || echo 0) paused=$([ -f "$PAUSE" ] && echo 1 || echo 0) hint=gpu-14 must start/unpause window-queue.sh"; return 11
}
field() { printf '%s' "$2" | grep -oE "(^|[[:space:]])$1=[^[:space:]]+" | head -n1 | sed -E "s/^[[:space:]]*$1=//; s/[$BACKTICK*,;]+\$//"; }

# 2026-10-25 (gpu-14; runner redeploy to 7579ae8b at 08:37Z): 6 of 20 queued packages, sealed from checkouts older than
# #1799 (which made Step.Files[].SHA256 required at submission), failed kit-preflight C3 only when their turn came
# (f90a7704 and 1e7ce5e7 at 11:06Z), and nothing had told their lanes. --recheck runs the real kit-preflight.sh
# (read-only: no stage, node, device or runner state) over every queued and attended-held row right after
# runner-redeploy.sh, prints one RECHECK line per row, tells each failing lane's run ONCE per (generation, deployed
# automation sha) what failed and how to re-seal, and writes one NEEDS summary for gpu-14. It never edits, fails or
# removes a row, takes no queue lock (both files are replaced atomically by the loop), and is safe beside a running loop.
# A pin "lacking a commit the runner requires" is a recheck reason only for SESSION-side code (C9 floor): prepare verbs
# run from the deployed tree (window fe39d8ec 11:24Z: the watcher ran network-ready from the session checkout; fixed).
# Lanes are pf-task runs, not pf-comms agents (roster 2026-10-25: no pft- id), so the lane message goes through the
# coordinator's send.sh (run.send) like lane-drive.sh and lane-msg.sh; the one summary note to gpu-14 goes over pf-comms.
ATTENDED=$FB/window-queue.attended-held.tsv
RECHECK_LEDGER=$FB/window-queue.recheck.tsv; RECHECK_LOCK=$FB/.window-queue.recheck.lock
LANE_SEND=${WQ_LANE_SEND:-$R/send.sh}; RECHECK_PREFLIGHT_S=${WQ_RECHECK_PREFLIGHT_S:-900}
recheck_message() {  # recheck_message <sha> <clone> <gen> <TOKEN> <label> <pkg> <reason> <fail-lines> <needs-file>
  local sha256_hint="" floor_hint=""
  case "$8" in *step_shape_invalid*) sha256_hint=" Sealed step requests older than #1799 lack SHA256 and are refused step_shape_invalid; the deployed scripts/pf-kit-step --check names the exact field." ;; esac
  # C9 is the SESSION-side floor: the runner runs pf-kit-session/pf_bench_live from a checkout at the kit's AutomationSHA.
  # Every prepare verb (stage, fill-bundle, network-ready) runs from the deployed tree (fe39d8ec 11:24Z fixed the watcher),
  # so stage layout is never a pin concern and never a recheck reason.
  case "$8" in *"check=C9 result=FAIL"*) floor_hint=" C9 lists session-side commits (kit-automation-floor.txt) your AutomationSHA pin must contain, because the runner runs pf-kit-session/pf_bench_live from a checkout at that pin; prepare verbs (stage, fill-bundle, network-ready) run from the deployed tree, so stage layout is not a pin concern." ;; esac
  cat <<EOF
window-queue RECHECK after the kit-window runner redeploy (deployed pocketforge-automation $1, clone $2): your queued kit gen=$3 label=$5 pkg=$6 now FAILS kit-preflight at the deployed runner and would be refused at window time, so it will not run as sealed ($7).
Failing checks:
$8
Re-seal a NEW package and generation (a generation is write-once; do not edit the sealed package or the queue file):
1. In your pocketforge-automation worktree: git fetch origin main && git merge origin/main (the deployed runner is $1; prepare the kit from a checkout that contains it).$floor_hint
2. Re-seal with kit declarations (prepare --kit-purpose/--kit-mutation/--kit-hazards). Every push/push-exec Step.Files[] entry must carry Source, Name and SHA256 (render requests with pf-kit-step <gen> --render-plan, or add the sha256sum of each file beside Source/Name).$sha256_hint
3. Verify every sealed request from that worktree: python3 -B scripts/pf-kit-step --check <request.json> must print PF_KIT_STEP_CHECK result=PASS for each one (fill the @...@ identity placeholders with format-valid dummies in a scratch copy, as kit-preflight C3 does).
4. Hand the new package back in your status line: $4 state=HANDBACK reason=BOOT_READY pkg=<new package dir> gen=<new 32-hex> steps=<n> label=$5
gpu-14 withdraws the old row once the new one is queued. Recheck receipt: $9
EOF
}
# Read-only identity of the deployed runner tree against the deployed sha recorded at the start of the run: echoes ok,
# or a typed refusal (runner_clone_sha_mismatch head= recorded= | runner_clone_dirty changes= first=). Every preflight
# reads its code from this tree, so a result counts only while HEAD is the recorded sha AND tracked and untracked files
# are clean. GIT_OPTIONAL_LOCKS=0: git status must not even refresh the live clone's index (never modify the runner).
recheck_tree() {  # recheck_tree <repo> <recorded-sha>
  local h st first
  h=$(GIT_OPTIONAL_LOCKS=0 git -C "$1" rev-parse HEAD 2>/dev/null)
  [ "$h" = "$2" ] || { echo "runner_clone_sha_mismatch head=${h:-unreadable} recorded=$2"; return 1; }
  st=$(GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain --untracked-files=all 2>/dev/null) \
    || { echo "runner_clone_dirty changes=status_failed first=-"; return 1; }
  [ -z "$st" ] && { echo ok; return 0; }
  first=${st%%$'\n'*}; first=${first:3}; first=${first//[^A-Za-z0-9._\/-]/_}  # porcelain XY-space-path, as one token
  echo "runner_clone_dirty changes=$(printf '%s\n' "$st" | wc -l | tr -d ' ') first=${first:0:96}"; return 1
}
recheck_binding() {  # recheck_binding <repo> <sha> <publication-or-empty> <publication-sha-or-empty>
  local tree current
  tree=$(recheck_tree "$1" "$2") || { printf '%s\n' "$tree"; return 1; }
  if [ -n "$3" ]; then
    current=$(sha256sum "$3" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$current" ] || [ "$current" != "$4" ]; then
      echo "active_clone_publication_changed expected=$4 current=${current:-unreadable}"
      return 1
    fi
  fi
  echo ok
}
recheck_write_needs() {  # recheck_write_needs <header>: header + the caller's needs_rows, atomically at $needs; rc 1 = not written
  local tmp
  tmp=$(mktemp "$NEEDS/.window-queue-recheck-$sha8.XXXXXX" 2>/dev/null) || return 1
  # mv -T: a directory (or anything but a file) at the summary path fails the write instead of receiving the file.
  if { printf '%s\n' "$1" && printf '%s' "$needs_rows"; } > "$tmp" 2>/dev/null && mv -T -f "$tmp" "$needs" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null; return 1
}
recheck_refuse_tree() {  # recheck_refuse_tree <recheck_tree output>: stop the whole recheck; no further row, no further lane message
  local why=${1%% *} detail=${1#* } state=$needs
  recheck_write_needs "$(printf '%s NEEDS gpu-14 recheck REFUSED reason=%s deployed=%s clone=%s repo=%s %s rows_checked=%s notified=%s: the runner tree is not the clean tree at the recorded deployed sha, so a kit-preflight result read from it would not describe the runner that will judge the queue. No further row was checked and no further lane was told (rows listed below were checked before the refusal). Never clean or reset the clone (it is the live runner tree): deploy a clean pa-<sha8> clone with runner-redeploy.sh, then rerun window-queue.sh --recheck.' \
    "$(ts)" "$why" "$sha" "$clone" "$D" "$detail" "$rows" "$sent")" || state=write_failed
  echo "$(ts) RECHECK_REFUSED reason=$why deployed=$sha $detail rows_checked=$rows notified=$sent needs=$state" >> "$LOG"
  echo "WINDOW_QUEUE_RECHECK_REFUSED reason=$why repo=$D deployed=$sha $detail rows_checked=$rows notified=$sent needs=$state"
}
# #2066 review: runner request admission is ONE EXTRA check composed after the
# live lane preflight (the hand-maintained C1-C21 kit-preflight.sh), never a
# replacement.  The live script keeps image/denylist/owner/step-shape/policy
# checks; this add-on only asks the deployed runner's request admission.  Callers
# supply `ovenv`, `runner_env` and `preflight_timeout` by bash dynamic scope.
run_preflight() {  # run_preflight <pkg> <gen> <owner> <steps>; stdout = composed report
  local pkg=$1 gen=$2 owner=$3 steps=$4 live prc summary admout adrc adsum adcheck
  live=$(env "${ovenv[@]}" "${runner_env[@]}" "${preflight_timeout[@]}" \
    "$PREFLIGHT" "$pkg" "$gen" "$owner" "$steps" 2>&1); prc=$?
  summary=$(printf '%s\n' "$live" | grep '^KIT_PREFLIGHT result=' | tail -1)
  # Admission decides nothing unless the live preflight exited 0 and passed.
  if [ "$prc" -ne 0 ] || [[ $summary != "KIT_PREFLIGHT result=PASS"* ]]; then
    printf '%s\n' "$live"; return "$prc"
  fi
  if [ ! -x "$ADMISSION_CHECK" ]; then
    printf '%s\n' "$live"
    printf 'KIT_PREFLIGHT check=ADMISSION result=FAIL reason=admission_check_missing typed_cause=-\n'
    printf 'KIT_PREFLIGHT result=REFUSED failed=ADMISSION reason=admission_check_missing typed_cause=- gen=%s\n' "$gen"
    return 1
  fi
  admout=$(env "${ovenv[@]}" "${runner_env[@]}" \
    "$ADMISSION_CHECK" "$pkg" "$gen" "$owner" "$steps" 2>&1); adrc=$?
  adsum=$(printf '%s\n' "$admout" | grep '^KIT_PREFLIGHT result=' | tail -1)
  adcheck=$(printf '%s\n' "$admout" | grep 'KIT_PREFLIGHT check=ADMISSION result=PASS')
  if [ "$adrc" -eq 0 ] && [ -n "$adcheck" ]; then
    # Insert the admission PASS line BEFORE the live final summary, so the
    # image=/overrides=/chain_paths_ok= fields still come from the live script.
    printf '%s\n' "$live" | awk -v adm="$admout" '
      { lines[NR] = $0; if ($0 ~ /^KIT_PREFLIGHT result=/) last = NR }
      END {
        for (i = 1; i <= NR; i++) { if (i == last) printf "%s\n", adm; print lines[i] }
        if (!last) printf "%s\n", adm
      }'
    return 0
  fi
  # Keep the live lines for context, then the admission failure.  The final
  # KIT_PREFLIGHT result= line is the admission REFUSED line (parsers take the last).
  printf '%s\n' "$live"
  printf '%s\n' "$admout"
  case $adsum in
    "KIT_PREFLIGHT result=REFUSED"*) ;;
    *) printf 'KIT_PREFLIGHT check=ADMISSION result=FAIL reason=admission_unreadable typed_cause=-\n'
       printf 'KIT_PREFLIGHT result=REFUSED failed=ADMISSION reason=admission_unreadable typed_cause=- gen=%s\n' "$gen" ;;
  esac
  return 1
}

# Identity-only mismatch (tsp-mc9m.60.29.84.43): the live kit-preflight PASSED and the composed admission refused ONLY
# because the sealed request names a runner that is no longer the live one. Those rows are rebound onto the live runner
# (pf-kit-window-runner rebind --to-live; the sealed request is never edited) instead of being sent back for a reseal.
recheck_identity_only() {  # recheck_identity_only <composed report>: rc 0 = live PASS + ADMISSION runner_authority_mismatch (identity typed cause)
  local out=$1 summary
  summary=$(printf '%s\n' "$out" | grep '^KIT_PREFLIGHT result=' | tail -1)
  printf '%s\n' "$out" | grep -q '^KIT_PREFLIGHT result=PASS' || return 1
  case $summary in
    "KIT_PREFLIGHT result=REFUSED failed=ADMISSION reason=runner_authority_mismatch typed_cause=automation_repository_mismatch "*|\
    "KIT_PREFLIGHT result=REFUSED failed=ADMISSION reason=runner_authority_mismatch typed_cause=automation_head_mismatch "*|\
    "KIT_PREFLIGHT result=REFUSED failed=ADMISSION reason=runner_authority_mismatch typed_cause=execution_runner_env_not_live "*|\
    "KIT_PREFLIGHT result=REFUSED failed=ADMISSION reason=runner_authority_mismatch typed_cause=execution_runner_not_live "*) return 0 ;;
  esac  # tsp-mc9m.60.29.84.61: a request COMMAND through the old clone is text the rebind rewrites; package code
        # through it (package_runner_not_live:<file>) is not, so that one goes back to the lane
  return 1
}
recheck_request_file() {  # recheck_request_file <pkg>: the single sealed DEVICE_REQUEST.md, resolved as kit-admission-check.sh L2 does
  local c found="" n=0
  for c in "$1/DEVICE_REQUEST.md" "$1-request/DEVICE_REQUEST.md" "$(dirname "$1")/$(basename "$1")-request/DEVICE_REQUEST.md"; do
    [ -f "$c" ] && [ ! -L "$c" ] || continue
    [ "$c" = "$found" ] && continue
    found=$c; n=$((n + 1))
  done
  [ "$n" -eq 1 ] || return 1
  printf '%s\n' "$found"
}
recheck() {
  local D sha sha8 clone src row _ts lane owner token pkg gen steps label note why out prc summary failed result reason typed typed_suffix
  local fail_lines notify msg log needs needs_rows="" line sout src_rc og oc orsn head tree state note_state=none prefix
  local publication="" publication_sha="" rbreq rbout rbrc rbstate rbreceipt rbreason rbtyped out2 rb_pass="" rb_note=""
  local -a rbenv=()
  local rows=0 pass=0 fail=0 sent=0 prior=0 nfail=0 lfail=0
  local -a qrows=() arows=() ovenv=() perr=() runner_env=() preflight_timeout=()
  [ $# -eq 0 ] || { echo "WINDOW_QUEUE_RECHECK_REFUSED reason=usage hint='--recheck takes no arguments'"; return 2; }
  [ -x "$PREFLIGHT" ] || { echo "WINDOW_QUEUE_RECHECK_REFUSED reason=preflight_missing path=$PREFLIGHT"; return 2; }
  # Production binds to the deploy-published active clone.  PF_WINDOW_RUNNER_REPO
  # remains an explicit hermetic test seam and never consults MainPID.
  if [ -n "${PF_WINDOW_RUNNER_REPO:-}" ]; then
    D=$PF_WINDOW_RUNNER_REPO
    runner_env=("PF_WINDOW_RUNNER_REPO=$D")
  else
    publication=$ACTIVE_RUNNER_PUBLICATION
    publication_sha=$(sha256sum "$publication" 2>/dev/null | cut -d' ' -f1)
    [ -n "$publication_sha" ] || { echo "WINDOW_QUEUE_RECHECK_REFUSED reason=runner_authority_unreadable typed_cause=active_clone_publication_invalid"; return 2; }
    D=$(jq -er '.Repository | select(type == "string" and startswith("/"))' "$publication" 2>/dev/null) \
      || { echo "WINDOW_QUEUE_RECHECK_REFUSED reason=runner_authority_unreadable typed_cause=active_clone_publication_invalid"; return 2; }
    runner_env=("PF_KIT_ACTIVE_RUNNER_PUBLICATION=$publication")
  fi
  rbenv=("PF_KIT_AUTOMATION_REPO=$D" "PF_KIT_TRUSTED_AUTOMATION_REPOS=${PF_KIT_TRUSTED_AUTOMATION_REPOS:-$D}")
  sha=""; [ -n "$D" ] && sha=$(GIT_OPTIONAL_LOCKS=0 git -C "$D" rev-parse HEAD 2>/dev/null)
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "WINDOW_QUEUE_RECHECK_REFUSED reason=runner_clone_unknown repo=${D:-unset}"; return 2; }
  sha8=${sha:0:8}; clone=$(basename "$D"); needs=$NEEDS/window-queue-recheck-$sha8.txt
  exec 9>>"$RECHECK_LOCK"; flock -n 9 || { echo "WINDOW_QUEUE_RECHECK_REFUSED reason=already_running"; return 5; }
  # The recorded deployed sha: runner-redeploy.sh names each clone pa-<sha8>, so that name must agree with HEAD; then
  # the tree must be clean at that sha before any row is checked (and again after every preflight, below).
  if [[ $clone =~ ^pa-([0-9a-f]{8,40})$ ]] && [[ $sha != "${BASH_REMATCH[1]}"* ]]; then
    tree="runner_clone_sha_mismatch head=$sha recorded=${BASH_REMATCH[1]}"
  else
    tree=$(recheck_binding "$D" "$sha" "$publication" "$publication_sha")
  fi
  [ "$tree" = ok ] || { recheck_refuse_tree "$tree"; return 2; }
  # Snapshot both files first: the loop replaces them atomically, so a row popped meanwhile is still reported here.
  mapfile -t qrows < <(awk '!/^[[:space:]]*(#|$)/' "$Q" 2>/dev/null)
  [ -f "$ATTENDED" ] && mapfile -t arows < <(awk '!/^[[:space:]]*(#|$)/' "$ATTENDED")
  echo "$(ts) RECHECK_START deployed=$sha clone=$clone queued=${#qrows[@]} attended_held=${#arows[@]}" >> "$LOG"
  for src in queue attended-held; do
    if [ "$src" = queue ]; then set -- "${qrows[@]}"; else set -- "${arows[@]}"; fi
    for row in "$@"; do
      rows=$((rows + 1)); IFS=$'\t' read -r _ts lane owner token pkg gen steps label note <<< "$row"
      result=FAIL; fail_lines=""; notify=none; log=-
      if ! why=$(validate "${lane:-}" "${owner:-}" "${token:-}" "${pkg:-}" "${gen:-}" "${steps:-}" "${label:-}"); then
        reason="row_invalid:$why"; gen=${gen:-unknown}; token=${token:-unknown}
      else
        # Per-generation overrides exactly as process_row applies them (gpu-14's file only; gen<TAB>check<TAB>reason).
        ovenv=()
        while IFS=$'\t' read -r og oc orsn; do [ "$og" = "$gen" ] && [[ $oc =~ ^C[0-9]$ ]] && ovenv+=("KIT_PREFLIGHT_OVERRIDE_$oc=$orsn"); done < <(cat "$OVR" 2>/dev/null)
        log=$LOGD/$gen-recheck-$sha8.txt
        preflight_timeout=(timeout "$RECHECK_PREFLIGHT_S")
        out=$(run_preflight "$pkg" "$gen" "$owner" "$steps"); prc=$?
        rb_pass=""; rb_note=""
        if [ "$prc" -ne 0 ] && recheck_identity_only "$out" && rbreq=$(recheck_request_file "$pkg"); then
          # The rebind output is DATA (jq-parsed, charset-checked), never evaluated.
          rbout=$(env "${ovenv[@]}" "${runner_env[@]}" "${rbenv[@]}" \
            timeout "$RECHECK_PREFLIGHT_S" "$D/scripts/pf-kit-window-runner" rebind "$rbreq" --to-live 2>&1); rbrc=$?
          rbstate=$(printf '%s\n' "$rbout" | jq -r '.State // empty' 2>/dev/null | grep -E '^[A-Z_]+$' | head -1)
          rbreceipt=$(printf '%s\n' "$rbout" | jq -r '.Receipt // empty' 2>/dev/null | grep -E '^/[A-Za-z0-9_./+@:-]+$' | head -1)
          rbreason=$(printf '%s\n' "$rbout" | jq -r '.Reason // empty' 2>/dev/null | grep -E '^[A-Za-z0-9_.:-]+$' | head -1)
          rbtyped=$(printf '%s\n' "$rbout" | jq -r '.TypedCause // empty' 2>/dev/null | grep -E '^[A-Za-z0-9_.:-]+$' | head -1)
          printf '%s rebind rc=%s request=%s\n%s\n' "$(ts)" "$rbrc" "$rbreq" "$(printf '%s' "$rbout" | head -c 4000)" > "$log.rebind" 2>/dev/null
          if [ "$rbrc" -eq 0 ] && [ "$rbstate" = REBOUND ] && [ -n "$rbreceipt" ]; then
            out=$(run_preflight "$pkg" "$gen" "$owner" "$steps"); prc=$?
            if [ "$prc" -eq 0 ]; then rb_pass=$rbreceipt; else rb_note=" rebound_receipt=$rbreceipt"; fi
          elif [ "$rbstate" = REFUSED ] && [ -n "$rbreason" ]; then
            rb_note=" rebind_refused=$rbreason${rbtyped:+ rebind_typed_cause=$rbtyped}"
          else
            rb_note=" rebind_unreadable rc=$rbrc"
          fi
        fi
        printf '%s recheck deployed=%s clone=%s rc=%s\n%s\n' "$(ts)" "$sha" "$clone" "$prc" "$out" > "$log"
        # A result counts only if the tree was still the clean recorded sha when the preflight finished.
        tree=$(recheck_binding "$D" "$sha" "$publication" "$publication_sha")
        if [ "$tree" != ok ]; then
          line="RECHECK gen=$gen lane=$token result=UNKNOWN reason=$tree log=$log owner=${owner:-unknown} label=${label:-unknown} source=$src notify=none"
          echo "$line"; echo "$(ts) $line" >> "$LOG"; needs_rows+="$line pkg=${pkg:-unknown}"$'\n'
          recheck_refuse_tree "$tree"; return 2
        fi
        summary=$(printf '%s\n' "$out" | grep '^KIT_PREFLIGHT result=' | tail -1)
        if [ "$prc" = 0 ] && [[ $summary == "KIT_PREFLIGHT result=PASS"* ]]; then
          result=PASS; reason="preflight_pass failed=-"
          [ -z "$rb_pass" ] || reason="rebound receipt=$rb_pass"
        elif [ -z "$summary" ]; then reason="preflight_unreadable rc=$prc log=$log${rb_note}"
        else
          failed=$(field failed "$summary")
          typed=$(field typed_cause "$summary")
          fail_lines=$(printf '%s\n' "$out" | grep '^KIT_PREFLIGHT check=[A-Za-z0-9]* result=FAIL ')
          typed_suffix=
          if [ -n "$typed" ] && [ "$typed" != - ]; then
            typed_suffix=" typed_cause=$typed"
          fi
          reason="preflight_failed failed=${failed:-?}$(printf '%s\n' "$fail_lines" | sed -nE 's/^KIT_PREFLIGHT check=([A-Za-z0-9]+) result=FAIL reason=([^ ]*).*/ \1=\2/p' | tr -d '\n')${typed_suffix} log=$log${rb_note}"
        fi
      fi
      if [ "$result" = FAIL ] && [[ $reason != row_invalid:* ]]; then
        if awk -F'\t' -v s="$sha" -v g="$gen" '$2==s && $3==g {f=1} END {exit !f}' "$RECHECK_LEDGER" 2>/dev/null; then
          notify=prior; prior=$((prior + 1))
        else
          msg=$LOGD/$gen-recheck-$sha8.msg.txt
          recheck_message "$sha" "$clone" "$gen" "$token" "$label" "$pkg" "$reason" "${fail_lines:-$summary}" "$needs" > "$msg"
          if sout=$(timeout 300 "$LANE_SEND" "$owner" "$msg" "wq-recheck-${gen:0:8}-$sha8" 2>&1); then
            sent=$((sent + 1))
            # The ledger is what makes a rerun silent; a lane told but not recorded is told again next run (reported).
            if printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$sha" "$gen" "$token" "$owner" "$msg" >> "$RECHECK_LEDGER" 2>/dev/null; then
              notify=sent
            else
              notify=sent_unrecorded; lfail=$((lfail + 1))
            fi
          else
            src_rc=$?; notify=failed; nfail=$((nfail + 1))
            printf '%s lane send FAILED rc=%s run=%s: %s\n' "$(ts)" "$src_rc" "$owner" "$(printf '%s' "$sout" | tail -c 300 | tr '\n' ' ')" >> "$log"
          fi
        fi
      fi
      line="RECHECK gen=$gen lane=$token result=$result reason=$reason owner=${owner:-unknown} label=${label:-unknown} source=$src notify=$notify"
      echo "$line"; echo "$(ts) $line" >> "$LOG"
      if [ "$result" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); needs_rows+="$line pkg=${pkg:-unknown}"$'\n'; fi
    done
  done
  [ "$lfail" -eq 0 ] || perr+=(ledger_write_failed)
  if [ "$fail" -gt 0 ]; then
    head=$(printf '%s NEEDS gpu-14 recheck deployed=%s clone=%s rows=%s pass=%s fail=%s notified=%s prior=%s notify_failed=%s ledger_failed=%s: %s queued kit(s) fail kit-preflight at the deployed runner and will be refused at window time (nothing reached the device). Each failing lane run was told once (notify=sent|prior) to re-seal a NEW generation and hand it back with BOOT_READY; withdraw the old row (#withdrawn- prefix) when the new one is queued. notify=failed rows need a hand relay of the .msg.txt named in their log; notify=sent_unrecorded rows were told but the ledger append failed, so a rerun tells them again; row_invalid rows need the row fixed by hand.' \
      "$(ts)" "$sha" "$clone" "$rows" "$pass" "$fail" "$sent" "$prior" "$nfail" "$lfail" "$fail")
    if recheck_write_needs "$head"; then state=$needs; else state=write_failed; perr+=(needs_write_failed); fi
    if [ $((sent + nfail)) -gt 0 ]; then
      if printf 'window-queue RECHECK deployed=%s clone=%s: %s of %s queued kits fail kit-preflight at the deployed runner (lanes told=%s prior=%s send_failed=%s); nothing reached the device and no row was changed; summary=%s\n' \
          "$sha8" "$clone" "$fail" "$rows" "$sent" "$prior" "$nfail" "$state" \
          | timeout 60 "$COMMS" send --from "$NOTE_FROM" --to "$NOTE_TO" --topic coord --stdin >/dev/null 2>&1; then note_state=sent
      else
        note_state=failed; echo "$(ts) RECHECK_NOTE_FAILED deployed=$sha8 to=$NOTE_TO (summary=$state)" >> "$LOG"
      fi
    fi
  else
    # All rows pass: this sha has nothing outstanding, so an older summary for it is stale and must not survive silently.
    rm -f "$needs" 2>/dev/null
    if [ -e "$needs" ] || [ -L "$needs" ]; then state=$needs; perr+=(needs_stale_remove_failed); else state=-; fi
  fi
  if [ ${#perr[@]} -eq 0 ]; then prefix=WINDOW_QUEUE_RECHECK; else prefix="WINDOW_QUEUE_RECHECK_FAILED reason=$(IFS=,; echo "${perr[*]}")"; fi
  line="$prefix deployed=$sha clone=$clone rows=$rows pass=$pass fail=$fail notified=$sent prior=$prior notify_failed=$nfail needs=$state note=$note_state"
  echo "$(ts) RECHECK_DONE ${line#WINDOW_QUEUE_RECHECK}" >> "$LOG"
  echo "$line"
  [ ${#perr[@]} -eq 0 ] || return 6
  return 0
}

NEXT_ONLY=0; RESUME_MODE=
case "${1:-}" in
  --recheck) shift; recheck "$@"; exit $? ;;
  --add)
    shift
    if [ "${1:-}" = --supersedes ]; then [ $# -ge 2 ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=usage"; exit 2; }; SUPERSEDES=$2; shift 2; fi
    [ $# -ge 7 ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=usage"; exit 2; }; add_row "$@"; exit $? ;;
  --add-from-status)
    shift
    if [ "${1:-}" = --supersedes ]; then [ $# -ge 2 ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=usage"; exit 2; }; SUPERSEDES=$2; shift 2; fi
    [ $# -eq 4 ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=usage"; exit 2; }
    stl=$4; case "$stl" in *"reason=BOOT_READY "*|*"reason=BOOT_READY") ;; *) echo "WINDOW_QUEUE_ADD_REFUSED reason=not_boot_ready"; exit 2;; esac
    pkg=$(field pkg "$stl"); gen=$(field gen "$stl"); steps=$(field steps "$stl"); label=$(field label "$stl")
    # Lanes already say `supersedes=<gen7+>` in the HANDBACK status (own field or inside note=); lane-drive.sh passes the whole
    # line, so the driver needs no change.  An explicit --supersedes wins.  The first token is taken from anywhere in the line
    # (`note=supersedes=<p>`, `(supersedes=<p>)`, `;supersedes=<p>`): field() only sees tokens that start the line or follow
    # whitespace, so it missed those and left the stale predecessor queued.  The whole alphanumeric run is taken, never a hex
    # prefix of a longer word; add_row stays the single validator (charset/length) and logs a malformed one as prefix_invalid.
    if [ -z "$SUPERSEDES" ]; then
      SUPERSEDES=$(printf '%s' "$stl" | grep -oE 'supersedes=[0-9A-Za-z_]+' | head -n1) || SUPERSEDES=
      SUPERSEDES=${SUPERSEDES#supersedes=}
    fi
    note=""; case "$stl" in *" note="*) note=${stl#* note=}; note=${note%%"$BACKTICK"*} ;; esac
    # gpu-14 2026-10-24 (uaudit g13 15c61a02): a lane's sealed 42-char label made the driver's auto-add refuse
    # label_invalid and exit, so a BOOT_READY window sat unqueued. The label is only a queue tag here (preflight and
    # chain key on gen), so keep the first 40 chars instead of refusing; the charset is still validated by add_row.
    if [ "${#label}" -gt 40 ]; then note="label_truncated_from_${#label}_chars${note:+; $note}"; label=${label:0:40}; fi
    [ -n "$pkg" ] && [ -n "$gen" ] && [ -n "$steps" ] && [ -n "$label" ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=missing_fields pkg=${pkg:-?} gen=${gen:-?} steps=${steps:-?} label=${label:-?}"; exit 2; }
    add_row "$1" "$2" "$3" "$pkg" "$gen" "$steps" "$label" "$note"; exit $? ;;
  --done-from-status)  # gpu-14 2026-10-16: the lane's WINDOW_DONE gen=<32hex> plan=complete|incomplete status decides the close
    [ $# -eq 3 ] || { echo "WINDOW_QUEUE_DONE_REFUSED reason=usage"; exit 2; }
    caller=$2; stl=$3
    g=$(printf '%s' "$stl" | grep -oE 'gen=[0-9a-f]{32}' | head -n1 | cut -d= -f2)
    pl=$(printf '%s' "$stl" | grep -oE 'plan=(complete|incomplete)' | head -n1 | cut -d= -f2)
    [ -n "$g" ] && [ -n "$pl" ] || { echo "WINDOW_QUEUE_DONE_REFUSED reason=status_missing_gen_or_plan"; exit 2; }
    ag=$(sed -n 's/^gen=//p' "$ACTIVE" 2>/dev/null | head -1)
    ao=$(sed -n 's/^owner=//p' "$ACTIVE" 2>/dev/null | head -1)
    [ "$g" = "$ag" ] && [ "$caller" = "$ao" ] || { echo "WINDOW_QUEUE_DONE_REFUSED reason=active_owner_mismatch gen=$g active_gen=${ag:-none} caller=$caller active_owner=${ao:-none}"; exit 2; }
    exec "$0" --done "$g" "$pl" lane-status ;;
  --done)
    case "${3:-}" in complete) set -- "$1" "$2" success "${4:-plan=complete}" ;; incomplete) set -- "$1" "$2" failure "${4:-plan=incomplete}" ;; esac
    [[ ${2:-} =~ ^[0-9a-f]{32}$ ]] && { [ "${3:-}" = success ] || [ "${3:-}" = failure ]; } || { echo "WINDOW_QUEUE_DONE_REFUSED reason=usage"; exit 2; }
    if [ -f "$MARK/$2" ]; then [ "$(cut -f1 "$MARK/$2")" = "$3" ] && { echo "WINDOW_QUEUE_DONE_RECORDED gen=$2 close=$3 existing=1"; exit 0; }; echo "WINDOW_QUEUE_DONE_REFUSED reason=marker_conflict"; exit 2; fi
    printf '%s\t%s\t%s\n' "$3" "$(ts)" "${4:-manual}" > "$MARK/.$2.tmp" && mv "$MARK/.$2.tmp" "$MARK/$2"
    echo "WINDOW_QUEUE_DONE_RECORDED gen=$2 close=$3"; exit 0 ;;
  --has)
    g=${2:-}; n=$(ls "$NEEDS"/window-*-"$g".txt 2>/dev/null | head -1)
    [ -n "$n" ] && { head -1 "$n"; exit 3; }
    grep -qx "gen=$g" "$ACTIVE" 2>/dev/null && exit 4
    awk -F'\t' -v g="$g" '!/^#/ && $6==g {f=1} END {exit !f}' "$Q" && exit 0; exit 1 ;;
  --resume)  # gpu-14 2026-10-16: after diagnosing a STOP: record the stopped window's close, archive pause+active
    case "${2:-}" in complete|incomplete|success|failure) ;; *) echo "WINDOW_QUEUE_RESUME_REFUSED reason=usage hint='--resume complete|incomplete'"; exit 2 ;; esac
    RESUME_MODE=$2; shift 2 ;;
  --next) NEXT_ONLY=1; shift ;;
  --status)
    echo "WINDOW_QUEUE_STATUS running=$(running && echo 1 || echo 0) paused=$([ -f "$PAUSE" ] && echo 1 || echo 0) depth=$(grep -cvE '^[[:space:]]*(#|$)' "$Q") active=$(sed -n 's/^gen=//p' "$ACTIVE" 2>/dev/null | head -1) failed=$(grep -c . "$FAILED" 2>/dev/null || echo 0)"; exit 0 ;;
esac

ONCE=0; DRAIN=0; DRY=0
for a in "$@"; do case "$a" in --once) ONCE=1 ;; --drain) DRAIN=1 ;; --dry-run) DRY=1 ;; *) echo "WINDOW_QUEUE_EXIT reason=usage arg=$a"; exit 2 ;; esac; done

other_window() {  # same rule as window-chain.sh: only a positively readable closed State permits a new window
  local d s
  for d in "$WIN"/*/; do [ -f "$d/runner.json" ] || continue
    if ! s=$(jq -er '.State | select(type == "string" and length > 0)' "$d/runner.json" 2>/dev/null); then
      echo "$(basename "$d"):state_unreadable"; return 0
    fi
    # 2026-10-18 (5b629cf4, tsp-mc9m.41.1018.12.39): a failed close with a runner-validated safe acknowledgement is closed
    # for queue purposes, but ONLY when the deployed runner's own queue-disposition says RUN (it re-validates the receipt).
    case "$s" in closed) ;;
      failed) if [ -f "$d/safe-acknowledgement.json" ] && [ "$("$DISPOSITION" kit 2>/dev/null | head -1)" = RUN ]; then :
              else echo "$(basename "$d"):$s"; return 0; fi ;;
      *) echo "$(basename "$d"):$s"; return 0 ;; esac; done; return 1; }
affinity_head() {  # use the reviewed orderer against a private queue copy
  local raw=$1 d result rc g r owner
  d=$(mktemp -d "${RUNNER_TEMP:-/tmp}/window-order.XXXXXX") || return 1
  cp "$Q" "$d/window-queue.tsv" || { rmdir "$d"; return 1; }
  result=$("$ORDER_TOOL" order --by-image --dry-run --json \
    --queue "$d/window-queue.tsv" --prefer "$PREFER" --held "$HELD" \
    --start-image "$raw" 2>/dev/null)
  rc=$?
  find "$d" -mindepth 1 -delete; rmdir "$d"
  [ "$rc" = 0 ] || return 1
  while IFS= read -r g; do
    [[ $g =~ ^[0-9a-f]{32}$ ]] || return 1
    r=$(awk -F'\t' -v g="$g" '!/^[[:space:]]*(#|$)/ && $6==g {print; exit}' "$Q")
    [ -n "$r" ] || return 1
    owner=$(printf '%s\n' "$r" | cut -f3)
    awk -F'\t' -v o="$owner" '$1==o {f=1} END {exit !f}' "$HELD" 2>/dev/null && continue
    printf '%s\n' "$r"
    return 0
  done < <(printf '%s\n' "$result" | jq -er '.proposed.order[]' 2>/dev/null)
  return 1
}
package_raw_sha() {  # package_raw_sha <package>; one exact descriptor SHA or failure
  local f raw='' got
  for f in "$1"/seed-kit/felboot-request*.json; do
    [ -f "$f" ] || continue
    got=$(jq -er '.ImageSource.RawSHA256 | select(type == "string")' "$f" 2>/dev/null) || return 1
    [[ $got =~ ^[0-9a-f]{64}$ ]] || return 1
    [ -z "$raw" ] || [ "$raw" = "$got" ] || return 1
    raw=$got
  done
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw"
}
# 2026-10-19: while Codex turns fail ~40% (owners blocked mid-window: battsafe 07:13Z, mem 08:39Z), gpu-14 lists the
# owner runs whose windows go first (one run id per line) in $PREFER. Rows are otherwise FIFO. No file = plain FIFO.
head_row() { local r='' h=/dev/null p='' raw=''
  [ -s "$HELD" ] && h=$HELD
  [ -s "$PREFER" ] && r=$(awk -F'\t' 'FILENAME==ARGV[1] { x[$1]=1; next } FILENAME==ARGV[2] { if ($0 !~ /^[[:space:]]*(#|$)/) p[$1]=1; next } !/^[[:space:]]*(#|$)/ && ($3 in p) && !($3 in x) {print; exit}' "$h" "$PREFER" "$Q")
  [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  r=$(awk -F'\t' 'FILENAME==ARGV[1] { x[$1]=1; next } !/^[[:space:]]*(#|$)/ && !($3 in x) { s=tolower($8 " " $9); gsub(/[^a-z0-9_]+/, " ", s); if ((" " s " ") ~ / head /) {print; exit} }' "$h" "$Q")
  [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  if [ "$BASE_AFFINITY" = 1 ]; then
    p=$(awk -F'\t' 'NF>=7 {p=$7} END {print p}' "$DONE" 2>/dev/null)
    if raw=$(package_raw_sha "$p" 2>/dev/null); then
      if r=$(affinity_head "$raw"); then
        printf '%s\n' "$r"; return 0
      fi
      say "BASE_AFFINITY_FALLBACK reason=orderer_failed tool=$ORDER_TOOL" >&2
    fi
  fi
  awk -F'\t' 'FILENAME==ARGV[1] { x[$1]=1; next } !/^[[:space:]]*(#|$)/ && !($3 in x) {print; exit}' "$h" "$Q"; }
queued_rows() { grep -cvE '^[[:space:]]*(#|$)' "$Q" 2>/dev/null || true; }
refresh_held() {  # write "<owner run>\t<model>" for each queued owner whose Codex model probes full (rc 1)
  local o m out='' new old; local -A full=()
  for o in $(awk -F'\t' '!/^[[:space:]]*(#|$)/ {print $3}' "$Q" | sort -u); do
    m=$("$OWNER_MODEL" "$o" 2>/dev/null | head -1)
    case "$m" in gpt-*) [ -n "${full[$m]:-}" ] || { "$PROBE" "$m" >/dev/null 2>&1; full[$m]=$?; }
                        [ "${full[$m]}" = 1 ] && out+="$o	$m"$'\n' ;; esac
    # 2026-10-20 (battsafe-g4 driver exited on HANDBACK reason=WAITING with r22 queued): with no live lane-drive.sh, nobody
    # records WINDOW_DONE, so an opened window idles to the 3600 s limit. Hold the owner until gpu-14 restarts its driver.
    if [ -n "$DRIVER_ALIVE" ]; then "$DRIVER_ALIVE" "$o" >/dev/null 2>&1
    else pgrep -f "lane-drive\.sh $o( |\$)" >/dev/null 2>&1
    fi || out+="$o	no_driver"$'\n'
  done
  new=$(printf '%s' "$out" | sort); old=$(sort "$HELD" 2>/dev/null)
  [ "$new" = "$old" ] && return 0
  printf '%s' "$out" > "$HELD.tmp.$$" && mv "$HELD.tmp.$$" "$HELD"
  [ "$DRY" = 1 ] || [ "$NEXT_ONLY" = 1 ] || say "HOLD_SET held=[$(printf '%s' "$out" | awk -F'\t' 'NF {printf "%s%s:%s", (n++ ? " " : ""), $1, $2}')]"; }
pop_head() {
  exec 7>>"$QL"; flock -w 30 7 || return 3
  ROW=$(head_row); [ -n "$ROW" ] || { exec 7>&-; return 1; }
  if ! R_POP="$ROW" awk '!d && $0 == ENVIRON["R_POP"] {d=1; next} {print}' "$Q" > "$Q.tmp.$$" || ! mv "$Q.tmp.$$" "$Q"; then
    exec 7>&-; return 4
  fi
  # Keep QL until process_row publishes this owner in ACTIVE.
}
push_head() {
  [ "${WQ_TEST_PUSH_HEAD_FAIL:-0}" != 1 ] || return 4
  exec 7>>"$QL"; flock -w 30 7 || { exec 7>&-; return 3; }
  if ! awk -v r="$1" 'BEGIN {d=0} !d && !/^[[:space:]]*(#|$)/ {print r; d=1} {print} END {if (!d) print r}' "$Q" > "$Q.tmp.$$" || ! mv "$Q.tmp.$$" "$Q"; then
    exec 7>&-; return 4
  fi
  exec 7>&-
}
requeue_or_stop() {
  local tmp="$REQUEUE.tmp.$$"
  board_lock || stop requeue_lock_failed "could not lock protected board state"
  printf '%s\n' "$ROW" > "$tmp" && { [ ! -f "$REQUEUE" ] || cat "$REQUEUE" >> "$tmp"; } && mv "$tmp" "$REQUEUE" \
    || { board_unlock; stop requeue_preservation_failed "could not preserve dequeued row in $REQUEUE"; }
  board_unlock
  if push_head "$ROW"; then
    board_lock || stop requeue_lock_failed "could not lock protected board state"
    awk -v r="$ROW" '!d && $0 == r {d=1; next} {print}' "$REQUEUE" > "$tmp" && mv "$tmp" "$REQUEUE" \
      || { board_unlock; stop requeue_receipt_cleanup_failed "row is back in queue but recovery receipt remains in $REQUEUE"; }
    board_unlock
    return 0
  fi
  stop requeue_failed "dequeued row preserved in $REQUEUE; restore it to $Q before resuming"
}
needs() { printf '%s NEEDS gpu-14 gen=%s lane=%s label=%s: %s\n' "$(ts)" "$G" "$LANE" "$LABEL" "$2" >> "$NEEDS/window-$1-$G.txt"; }
# 2026-10-28 (periph-g3b r40, gen 6903abef): a start-time preflight failure only wrote a NEEDS file for gpu-14, so the
# lane still believed its gen was queued and sat silent ("not nudging"). Tell the owning lane directly, once per gen.
lane_notify() {  # lane_notify <stage> <message body>: one message to the owning run per gen and stage, one typed log line
  local msg=$LOGD/$G-$1.msg.txt state=sent
  printf '%s\n' "$2" > "$msg" 2>/dev/null || state=msg_write_failed
  if [ "$state" = sent ]; then timeout 300 "$LANE_SEND" "$OWNER" "$msg" "wq-$1-${G:0:8}" >/dev/null 2>&1 || state=send_failed; fi
  say "${1^^}_NOTIFY gen=$G owner=${OWNER:-unknown} notify=$state"
}
preflight_notify() {  # preflight_notify <preflight output> <summary line>
  lane_notify preflight "$(printf 'window-queue: kit %s (gen %s) was refused at start preflight, so it will not boot: %s\n' "$LABEL" "$G" "$2"
    printf '%s\n' "$1" | grep 'result=FAIL' | grep -v '^KIT_PREFLIGHT result' | cut -c1-400
    printf 'This gen is dead; do not re-queue it. Fix the cause and reseal a NEW generation, or hand back with %s state=HANDBACK and the reason. Full report: %s\n' "$TOKEN" "$LOGD/$G-preflight.txt")"
}
# 2026-10-28 (venc-build47-r3, gen 1568696a): a boot-open failure told only gpu-14 (notify_boot_open_failure), so the
# owning lane again sat "not nudging" on a dead gen. Tell the lane too, and say whether the queue went on or stopped.
bootopen_notify() {  # bootopen_notify <reason> <class> <node failure or empty> <continues|stops>
  local next="Reseal the same content as a NEW generation and add it to the queue, or hand back with $TOKEN state=HANDBACK and the reason."
  [ "$4" = continues ] || next="The queue stopped for gpu-14 to diagnose this failure. Do not reseal until gpu-14 tells you to."
  lane_notify bootopen "$(printf 'window-queue: kit %s (gen %s) failed at boot-open and will not be retried: reason=%s%s class=%s\n%s\nChain log: %s\n' \
    "$LABEL" "$G" "$1" "${3:+ node_failure=$3}" "$2" "$next" "$LOGD/$G-chain.txt")"
}
boot_open_disposition() {  # boot_open_disposition <class>: count an ordinary failure and persist the streak, then set BO_STOP
  # to the stop reason, or empty when the queue continues. The lane notice is sent after this, so it names the final outcome
  # even when persisting the streak fails (#1907 review).
  BO_STOP=
  [ "$1" = ordinary ] || { BO_STOP=boot_open_failed; return 0; }
  BOOT_OPEN_FAILURES=$((BOOT_OPEN_FAILURES + 1))
  [ "$BOOT_OPEN_FAILURES" -lt 2 ] || { BO_STOP=boot_open_circuit_breaker; return 0; }
  BOOT_STREAK_GEN=$G
  set_boot_streak "$BOOT_OPEN_FAILURES" "$G" || BO_STOP=boot_open_state_unreadable
  return 0
}
fail_row() {  # <kind> <detail> [<node failure>]: ts kind detail + the 9-column row; a boot-open failure that carries the node's
  # failure_reason adds it as a TRAILING node_failure=<token> column, so positional readers (collect.py gen=column 9) are unchanged.
  printf '%s\t%s\t%s\t%s%s\n' "$(ts)" "$1" "$2" "$ROW" "$(node_col "${3:-}")" >> "$FAILED"; }
record_rootfs_recovery_tally() {  # successful recovery still counts the initiating boot failure exactly once
  local receipt=$WIN/boot-open-$G.rootfs-recovery.result.json
  [ -e "$receipt" ] || return 0
  jq -e --arg gen "$G" '
    type == "object"
    and .Schema == "pocketforge.kit-window-rootfs-stall-recovery/v1"
    and .Generation == $gen
    and .Attempt == 1 and .RecoveryAttemptCount == 1
    and .FailureCode == "BASE_ROOTFS_STALL"
    and .Outcome == "opened" and .TallyOutcome == "failure"
  ' "$receipt" >/dev/null 2>&1 \
    || stop boot_open_state_unreadable "invalid recovered-stall tally receipt=$receipt"
  fail_row boot_open_failed BASE_ROOTFS_STALL
  say "BOOT_OPEN_RECOVERED_TALLY gen=$G reason=BASE_ROOTFS_STALL receipt=$receipt"
}
node_col() { [ -z "$1" ] || printf '\tnode_failure=%s' "$1"; }
stop() {  # stop <why> <detail>
  printf '%s stop reason=%s gen=%s\n' "$(ts)" "$1" "${G:-}" > "$PAUSE"
  phase stopped 2>/dev/null
  needs queue-stop "queue STOPPED reason=$1 $2 (pause file written; diagnose, then rm $PAUSE and $ACTIVE and restart)"
  say "STOP reason=$1 gen=${G:-} $2"
  printf 'window-queue STOP reason=%s gen=%s lane=%s label=%s: %s; pause=%s needs=%s\n' \
    "$1" "${G:-}" "${LANE:-unknown}" "${LABEL:-unknown}" "$2" "$PAUSE" "$NEEDS/window-queue-stop-${G:-}.txt" \
    | timeout 60 "$COMMS" send --from "$NOTE_FROM" --to "$NOTE_TO" --topic coord --stdin >/dev/null 2>&1 \
    || say "STOP_NOTE_FAILED reason=$1 gen=${G:-} to=$NOTE_TO (queue remains stopped; tell $NOTE_TO by hand)"
  echo "WINDOW_QUEUE_EXIT reason=stop:$1 gen=${G:-} needs=$NEEDS/window-queue-stop-${G:-}.txt"; exit 10; }
active_remove() {
  local rc
  board_lock || return 1
  rm -f "$ACTIVE"; rc=$?
  board_unlock; return "$rc"
}
active_resolve() {
  local target=$1 rc
  board_lock || return 1
  mv "$ACTIVE" "$target"; rc=$?
  board_unlock; return "$rc"
}
finish() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$G" "$OWNER" "$LANE" "$LABEL" "$1" "$P" >> "$DONE"; active_remove; say "DONE gen=$G outcome=$1"; }
phase() {
  local rc
  board_lock || return 1
  sed -i "s/^phase=.*/phase=$1/" "$ACTIVE"; rc=$?
  board_unlock; return "$rc"
}
set_boot_streak() {
  printf '%s\t%s\n' "$1" "${2:--}" > "$BOOT_STREAK.tmp.$$" && mv "$BOOT_STREAK.tmp.$$" "$BOOT_STREAK"
}
# 2026-10-25 (#1802, tsp-mc9m.41.1030.56.15): STOCK_BOOT_FORCED_OFF_ZERO_POWER is the stock-boot tripwire whose
# force-off went unconfirmed by receipt but whose psu-off AND power-zero probes both passed (receipt
# Outcome=zero-power-confirmed, QueueRule=stop-on-second-same-utc-date): the device is verified dark, so it is an
# ordinary boot-open failure (continue once, STOP on the second consecutive). Its row precedes the stock_boot_* glob;
# every other stock_boot_* refusal keeps its first-failure power_safety STOP.
boot_open_class() {  # <reason> [<node failure_reason>]: one normalized pattern table is the policy boundary for first-failure STOPs.
  # When a generic BASE_BOOT_FAILED carries the node's typed Oem.PocketForge.FailureReason (observed.failure_reason, #1802/#1806)
  # the token's row decides when the table has one (fel_usb_not_enumerated -> node_fel), else the runner code's row does.
  local reason=${1,,} node=${2,,} class
  [ -n "$reason" ] || { echo state_unknown; return; }
  if [ -n "$node" ]; then class=$(boot_open_class_row "$node"); [ -z "$class" ] || { echo "$class"; return; }; fi
  class=$(boot_open_class_row "$reason"); echo "${class:-state_unknown}"
}
# 2026-10-26 (tsp-mc9m.41.1030.56.54): the last block is the one deliberate widening of "ordinary". A warm-reuse refusal
# (REUSE_*: integrity/credential proof, receipt, cost gate, boot unavailable) and a runner contract/request refusal
# (RESUME_ADAPTER_*, RESUME_REQUEST_*, RESUME_ANCHOR_*, RESUME_SCHEMA_*, an existing or mis-pathed receipt) are typed,
# deterministic refusals of the runner or the sealed package: continuing once costs one row, the second consecutive one
# still STOPs (breaker), and the next row gets a full verified flash.  Order is the policy: first match wins, so the rows
# above (state_unknown/unreadable, infrastructure, power_safety, node_fel) take any token that also names one of those causes
# (REUSE_USB_*, RESUME_ADAPTER_PSU_*, ...).  The six rows just before the new block close the words those rows only match at
# the start of a token (felboot_*, fel_*, ums_*, stock_boot_*) or not at all (force_off, power), so a REUSE_/RESUME_ code that
# names the FEL path or the device power state can never fall through to "ordinary".  That includes
# REUSE_RECOVERY_FORCE_OFF_FAILED: the warm-reuse recovery could not force the device off, so its power state is unknown.
# Every other RESUME_* code (BOOT_ABORT_ANCHORED, OPERATION_*, WINDOW_*, RECEIPT_WRITE_FAILED, OUTPUT_*, CLOSE_*) and
# TEARDOWN_FAILED are not listed and stay state_unknown (STOP).
boot_open_class_row() {  # <token>: the table row's class, or nothing
  local token=$1 class pattern
  while IFS=$'\t' read -r class pattern; do
    [[ $token == $pattern ]] && { echo "$class"; return; }
  done <<'EOF'
state_unknown	unknown
state_unknown	*unknown*
state_unknown	*unreadable*
infrastructure	*other_generation_open*
infrastructure	*resume_operation_lock_failed*
ordinary	stock_boot_forced_off_zero_power
power_safety	stock_boot_*
node_fel	felboot_*
node_fel	fel_*
node_fel	*felentry*
node_fel	*umssetup*
node_fel	ums_*
node_fel	*usb*
node_fel	*preflight*seed*missing*
node_fel	*preflight*stage*missing*
power_safety	*force_off_unconfirmed*
power_safety	*psu*
power_safety	*safety*
ordinary	base_login_failed
ordinary	base_boot_failed
ordinary	base_boot_hang
ordinary	base_rootfs_stall
node_fel	*felboot*
node_fel	*_fel_*
node_fel	*_ums_*
power_safety	*force_off*
power_safety	*stock_boot*
power_safety	*power*
ordinary	reuse_*
ordinary	resume_adapter_*
ordinary	resume_request_*
ordinary	resume_anchor_*
ordinary	resume_schema_*
ordinary	resume_receipt_exists
ordinary	resume_receipt_path_invalid
EOF
}
notify_boot_open_failure() {
  printf 'window-queue continued after first ordinary boot-open failure gen=%s lane=%s label=%s reason=%s; the failed generation will not be retried and the next row still receives a full verified flash. log: %s\n' \
    "$G" "$LANE" "$LABEL" "$1" "$LOGD/$G-chain.txt" \
    | timeout 60 "$COMMS" send --from "$NOTE_FROM" --to "$NOTE_TO" --topic coord --stdin >/dev/null 2>&1 \
    || say "BOOT_OPEN_FAILURE_NOTE_FAILED gen=$G to=$NOTE_TO (queue continues; tell $NOTE_TO by hand)"
}
verdict_has_gen() {
  awk -F'\t' -v g="$1" '$2==g {f=1} END {exit !f}' "$DONE" 2>/dev/null \
    || awk -F'\t' -v g="$1" '$9==g {f=1} END {exit !f}' "$FAILED" 2>/dev/null
}
verdict_kind() {
  if awk -F'\t' -v g="$1" '$2==g {f=1} END {exit !f}' "$DONE" 2>/dev/null; then echo done
  elif awk -F'\t' -v g="$1" '$9==g {f=1} END {exit !f}' "$FAILED" 2>/dev/null; then echo failed
  else echo none; fi
}
record_failure() {
  local kind=$1 detail=$2 failed_row=${ROW:-}
  [ -n "$failed_row" ] || failed_row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t0\t%s\trecovered' \
    "$(ts)" "$LANE" "$OWNER" "$TOKEN" "$P" "$G" "$LABEL")
  printf '%s\t%s\t%s\t%s\n' "$(ts)" "$kind" "$detail" "$failed_row" >> "$FAILED"
}
receipt_reason() {  # <gen>: the runner refusal recorded in boot-open-<gen>.failed.json (Detail marker, else Reason)
  local f=$WIN/boot-open-$1.failed.json r
  r=$(jq -r '.Detail // empty' "$f" 2>/dev/null \
    | grep -oE '(PF_KIT_RESUME_REFUSED|PF_KIT_WINDOW_RUNNER_REFUSED) reason=[A-Za-z0-9_]+' | tail -1 | cut -d= -f2)
  [ -n "$r" ] || r=$(jq -r '.Reason // empty' "$f" 2>/dev/null)
  printf '%s' "$r"
}
receipt_node_failure() {  # <gen> <reason>: the node's failure_reason inside a BASE_BOOT_FAILED receipt's Detail, else nothing
  [ "${2^^}" = BASE_BOOT_FAILED ] || return 0
  jq -r '.Detail // empty' "$WIN/boot-open-$1.failed.json" 2>/dev/null | node_failure
}
node_failure() {  # stdin = refusal text: the node's typed Oem.PocketForge.FailureReason that a BASE_BOOT_FAILED refusal carries as
  # observed.failure_reason (#1802/#1806), or nothing. It travels as its OWN field (node_failure=<token> on the STOP line and NEEDS
  # text, a trailing failed.tsv column) so every reason= token stays byte-identical for existing readers (pf-window-throughput.py
  # stop_class, fleet-board collect.py). The chain log holds the JSON with escaped quotes, the failed.json Detail plain; both match.
  grep -oE '\\?"failure_reason\\?":\\?"[a-z][a-z0-9_:]{0,80}' | head -1 | sed 's/.*"//'
}
reconcile_at_start() {
  local f d gen st kind row ag _ts lane owner token pkg row_gen steps label note tmp reason node class terminal_reason verdict
  local queue_closed runner_failed
  local -A terminal=()
  for f in "$WIN"/boot-open-*.failed.json; do
    [ -f "$f" ] || continue
    gen=${f##*/boot-open-}; gen=${gen%.failed.json}
    [[ $gen =~ ^[0-9a-f]{32}$ ]] && terminal[$gen]=boot_open_failed
  done
  for d in "$WIN"/*/; do
    [ -f "$d/runner.json" ] || continue
    gen=$(basename "$d"); [[ $gen =~ ^[0-9a-f]{32}$ ]] || continue
    if ! st=$(jq -er '.State | select(type == "string" and length > 0)' "$d/runner.json" 2>/dev/null); then
      unset 'terminal[$gen]'; continue
    fi
    case "$st" in
      failed) terminal[$gen]=runner_failed ;;
      closed) terminal[$gen]=closed ;;
      *) unset 'terminal[$gen]' ;;  # open, closing and unknown windows are never reconciled
    esac
  done
  [ "${#terminal[@]}" -gt 0 ] || return 0
  exec 7>>"$QL"; flock -w 30 7 || return 1
  ag=$(sed -n 's/^gen=//p' "$ACTIVE" 2>/dev/null | head -1)
  while IFS= read -r gen; do
    kind=${terminal[$gen]}
    row=$(awk -F'\t' -v g="$gen" '!/^#/ && $6==g {print; exit}' "$Q" 2>/dev/null)
    verdict=$(verdict_kind "$gen")
    if [ -z "$row" ] && [ "$ag" != "$gen" ]; then
      # History (tsp-mc9m.41.1030.56.12 verifier D1): receipts and runner dirs under $WIN are never removed (add_row
      # relies on them), so every start sees every generation ever run. Only the generation the queue owns (ACTIVE or
      # a queued row) is classified, gated or STOPped on. History gets a missing verdict recorded exactly once, never a
      # breaker count, a node probe, or a STOP that gpu-14 already resumed.
      [ "$verdict" = none ] || continue
      row=$(printf '%s\tunknown\tunknown\tRECONCILED\t-\t%s\t0\treconciled\treconciled_at_start' "$(ts)" "$gen")
      case "$kind" in
        closed)
          terminal_reason=$(jq -er '.Reason | select(type == "string" and length > 0)' "$WIN/$gen/terminal.json" 2>/dev/null)
          if clean_runner_reason "$terminal_reason"; then
            printf '%s\t%s\tunknown\tunknown\treconciled\treconciled_at_start\t-\n' "$(ts)" "$gen" >> "$DONE"
          else
            printf '%s\tclosed_non_success:%s\treconciled_at_start\t%s\n' "$(ts)" "${terminal_reason:-missing_terminal}" "$row" >> "$FAILED"
          fi ;;
        boot_open_failed)
          reason=$(receipt_reason "$gen"); node=$(receipt_node_failure "$gen" "$reason")
          printf '%s\tboot_open_failed:%s\treconciled_at_start\t%s%s\n' "$(ts)" "${reason:-unknown}" "$row" "$(node_col "$node")" >> "$FAILED" ;;
        *) printf '%s\t%s\treconciled_at_start\t%s\n' "$(ts)" "$kind" "$row" >> "$FAILED" ;;
      esac || { exec 7>&-; return 1; }
      say "RECONCILED_AT_START gen=$gen terminal=$kind history=1"
      continue
    fi
    if [ -z "$row" ]; then  # the active generation: rebuild its row from ACTIVE
      lane=$(sed -n 's/^lane=//p' "$ACTIVE" | head -1); owner=$(sed -n 's/^owner=//p' "$ACTIVE" | head -1)
      token=$(sed -n 's/^token=//p' "$ACTIVE" | head -1); pkg=$(sed -n 's/^pkg=//p' "$ACTIVE" | head -1)
      label=$(sed -n 's/^label=//p' "$ACTIVE" | head -1)
      row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t0\t%s\treconciled_at_start' \
        "$(ts)" "${lane:-unknown}" "${owner:-unknown}" "${token:-RECONCILED}" "${pkg:--}" "$gen" "${label:-reconciled}")
    fi
    IFS=$'\t' read -r _ts lane owner token pkg row_gen steps label note <<< "$row"
    G=$gen; OWNER=${owner:-unknown}; LANE=${lane:-unknown}; LABEL=${label:-reconciled}; P=${pkg:--}
    TOKEN=${token:-RECONCILED}; ROW=$row
    if [ "$kind" = closed ]; then
      if [ "$verdict" != done ]; then
        terminal_reason=$(jq -er '.Reason | select(type == "string" and length > 0)' "$WIN/$gen/terminal.json" 2>/dev/null)
        # A close the queue itself drove (phase=closing, helper complete rc 0, recorded close_reason = terminal Reason)
        # is the normal end of a window whatever that reason; a runner that closed itself is accepted only on an
        # explicit success. Either way the post-close USB gate runs before anything is recorded DONE.
        queue_closed=0; runner_failed=
        if [ "$ag" = "$gen" ] && [ -n "$terminal_reason" ] \
           && [ "$(sed -n 's/^phase=//p' "$ACTIVE" | head -1)" = closing ] \
           && [ "$(sed -n 's/^helper_status=//p' "$ACTIVE" | head -1)" = complete ] \
           && [ "$(sed -n 's/^helper_rc=//p' "$ACTIVE" | head -1)" = 0 ] \
           && [ "$(sed -n 's/^close_reason=//p' "$ACTIVE" | head -1)" = "$terminal_reason" ]; then
          queue_closed=1; runner_failed=$(sed -n 's/^runner_failed=//p' "$ACTIVE" | head -1)
        fi
        if ! clean_runner_reason "$terminal_reason" && [ "$queue_closed" != 1 ]; then
          [ "$verdict" = failed ] || printf '%s\tclosed_non_success:%s\treconciled_at_start\t%s\n' "$(ts)" "${terminal_reason:-missing_terminal}" "$row" >> "$FAILED"
          exec 7>&-
          stop runner_closed_non_success "recovered closed runner has Reason='${terminal_reason:-missing or unreadable terminal.json}'"
        fi
        post_close_usb
        if [ -n "$runner_failed" ]; then
          [ "$verdict" != none ] || record_failure runner_failed "$runner_failed"
          exec 7>&-
          stop runner_failed "recovered failed runner $gen closed safely with failure ($runner_failed); device state unknown, diagnose before resuming"
        fi
        [ "$verdict" != none ] || printf '%s\t%s\t%s\t%s\t%s\treconciled_at_start\t%s\n' \
          "$(ts)" "$gen" "$owner" "$lane" "$label" "$pkg" >> "$DONE" || { exec 7>&-; return 1; }
      fi
    elif [ "$kind" = boot_open_failed ]; then
      reason=$(receipt_reason "$gen"); node=$(receipt_node_failure "$gen" "$reason")
      class=$(boot_open_class "$reason" "$node")
      [ "$verdict" != none ] || printf '%s\t%s\treconciled_at_start\t%s%s\n' "$(ts)" "boot_open_failed:${reason:-unknown}" "$row" "$(node_col "$node")" >> "$FAILED" \
        || { exec 7>&-; return 1; }
      if [ "$class" != ordinary ]; then
        exec 7>&-
        stop boot_open_failed "recovered receipt reason=${reason:-unknown}${node:+ node_failure=$node} class=$class"
      fi
      if [ "$BOOT_OPEN_FAILURES" = 0 ]; then
        BOOT_OPEN_FAILURES=1; BOOT_STREAK_GEN=$gen
        set_boot_streak 1 "$gen" || { exec 7>&-; return 1; }
      elif [ "${BOOT_STREAK_GEN:-}" = "$gen" ] || { [ -z "${BOOT_STREAK_GEN:-}" ] && [ "$verdict" = failed ]; }; then
        BOOT_STREAK_GEN=$gen
        set_boot_streak 1 "$gen" || { exec 7>&-; return 1; }
      else
        exec 7>&-
        stop boot_open_circuit_breaker "recovered second consecutive boot-open failure reason=${reason:-unknown}"
      fi
    else
      # runner_failed for a generation the queue OWNS (ACTIVE or a queued row) is never a consumable record: the
      # device state is unknown. Record the verdict once, then STOP with the row and ACTIVE preserved, exactly as the
      # live wait does (teardown_failed when the runner's own teardown left terminal.json, runner_failed otherwise).
      # An ACTIVE runner without terminal.json never reaches here: recover_recorded_active closes it and STOPs first.
      if [ -f "$WIN/$gen/terminal.json" ]; then
        case "$verdict" in
          none)
            recover_failed_terminal startup
            printf '%s\t%s\t%s\t%s\t%s\treconciled_auto_recovered\t%s\n' \
              "$(ts)" "$gen" "$owner" "$lane" "$label" "$pkg" >> "$DONE" \
              || { exec 7>&-; return 1; } ;;
          failed)
            exec 7>&-
            stop teardown_failed \
              "recovered owned runner $gen already has a FAILED terminal verdict; auto-first-step will not retry" ;;
          done) : ;;
        esac
      else
        [ "$verdict" != none ] || printf '%s\t%s\treconciled_at_start\t%s\n' "$(ts)" "$kind" "$row" >> "$FAILED" \
          || { exec 7>&-; return 1; }
        exec 7>&-
        reason=$(jq -r '.Reason // "unknown"' "$WIN/$gen/failure.json" 2>/dev/null)
        stop runner_failed "recovered owned runner $gen is State=failed (${reason:-unknown}) and was never closed by the queue; device state unknown, diagnose before resuming; remove its row from $Q if it is queued"
      fi
    fi
    say "RECONCILED_AT_START gen=$gen terminal=$kind"
    tmp=$Q.tmp.$$
    awk -F'\t' -v g="$gen" '/^#/ || $6!=g' "$Q" > "$tmp" && mv "$tmp" "$Q" \
      || { exec 7>&-; return 1; }
    [ "$ag" = "$gen" ] && rm -f "$ACTIVE"
  done < <(printf '%s\n' "${!terminal[@]}" | sort)
  exec 7>&-
}
auto_recovered() {  # auto_recovered "<AUTO_RECOVERED gen= class= receipt= existing= log=>": record + tell gpu-14
  local line=${1%% log=*}
  # The audit trail is the only record of an automatic recovery: a failed local write STOPs the queue.
  printf '%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$G" "$LANE" "$LABEL" "$line" >> "$AUTOREC" && echo "$(ts) $line" >> "$LOG" \
    || stop close_failed "${line} but its audit write failed ($AUTOREC / $LOG); the window IS closed, record it by hand"
  echo "$(ts) $line"
  printf 'window-queue %s lane=%s label=%s: the close failed, the runner validated its one automatic first step from its own receipts, and the queue continued (the next window full-flashes). close log: %s\n' \
    "$line" "$LANE" "$LABEL" "$LOGD/$G-close.txt" \
    | timeout 60 "$COMMS" send --from "$NOTE_FROM" --to "$NOTE_TO" --topic coord --stdin >/dev/null 2>&1 \
    || say "AUTO_RECOVERED_NOTE_FAILED gen=$G to=$NOTE_TO (recovery stands; tell $NOTE_TO by hand)"; }
recover_failed_terminal() {  # recover_failed_terminal <live|startup>: runner owns classification; queue gates typed result
  local source=$1 close_out clrc st auto auto_count disp
  say "AUTO_FIRST_STEP gen=$G source=$source runner_state=failed terminal=present"
  "$CLOSE" "$G" failure --auto-first-step > "$LOGD/$G-close.txt" 2>&1 7>&- 8>&-
  clrc=$?
  close_out=$(cat "$LOGD/$G-close.txt")
  st=$(jq -r '.State // empty' "$WIN/$G/runner.json" 2>/dev/null)
  auto=$(printf '%s\n' "$close_out" \
    | grep -E "^AUTO_RECOVERED gen=$G class=[a-z_]+ receipt=/[^ ]+ existing=[01] log=/[^ ]+$" \
    | head -1)
  auto_count=$(printf '%s\n' "$close_out" \
    | grep -cE "^AUTO_RECOVERED gen=$G class=[a-z_]+ receipt=/[^ ]+ existing=[01] log=/[^ ]+$")
  disp=$("$DISPOSITION" kit 2>/dev/null | head -1)
  if [ "$auto_count" = 1 ] && [ "$clrc" = 0 ] && [ "$st" = closed ] && [ "$disp" = RUN ]; then
    auto_recovered "$auto"
    post_close_usb
    return 0
  fi
  if [ "$source" = startup ] && [ "$verdict" = none ]; then
    printf '%s\t%s\treconciled_at_start\t%s\n' "$(ts)" "$kind" "$row" >> "$FAILED" \
      || stop teardown_failed "runner terminal State=failed for $G; auto-first-step refused and FAILED ledger write failed"
  fi
  stop teardown_failed \
    "runner terminal State=failed for $G; auto-first-step source=$source rc=$clrc state=${st:-missing} disposition=${disp:-none} typed_lines=$auto_count: $(printf '%s' "$close_out" | tail -1 | cut -c1-400)"
}
post_close_usb() {  # gate queue advancement on one typed, read-only node sample
  local out rc count
  out=$("$POST_CLOSE_USB" "$G" 2>&1); rc=$?
  printf '%s\n' "$out" >> "$LOGD/$G-close.txt" \
    || stop post_close_usb_latch "detector receipt write failed log=$LOGD/$G-close.txt"
  count=$(printf '%s\n' "$out" | grep -c '^POST_CLOSE_USB ')
  if [ "$rc" != 0 ] || [ "$count" != 1 ] \
     || ! printf '%s\n' "$out" | grep -qxE "POST_CLOSE_USB result=PASS reason=healthy gen=$G node=pf-node-01"; then
    stop post_close_usb_latch "detector rc=$rc receipt=$(printf '%s' "$out" | tail -1 | cut -c1-240) log=$LOGD/$G-close.txt"
  fi
  say "POST_CLOSE_USB PASS gen=$G"
}
load_active_context() {
  [ -f "$ACTIVE" ] || return 1
  G=$(sed -n 's/^gen=//p' "$ACTIVE" | head -1)
  [[ $G =~ ^[0-9a-f]{32}$ ]] || return 1
  OWNER=$(sed -n 's/^owner=//p' "$ACTIVE" | head -1)
  LANE=$(sed -n 's/^lane=//p' "$ACTIVE" | head -1)
  TOKEN=$(sed -n 's/^token=//p' "$ACTIVE" | head -1)
  P=$(sed -n 's/^pkg=//p' "$ACTIVE" | head -1)
  LABEL=$(sed -n 's/^label=//p' "$ACTIVE" | head -1)
  OWNER=${OWNER:-unknown}; LANE=${LANE:-unknown}; TOKEN=${TOKEN:-RECONCILED}
  P=${P:--}; LABEL=${LABEL:-reconciled}
}
active_set() {
  local key=$1 value=$2 tmp=$ACTIVE.tmp.$$ rc
  board_lock || return 1
  awk -F= -v k="$key" '$1 != k' "$ACTIVE" > "$tmp" && printf '%s=%s\n' "$key" "$value" >> "$tmp" && mv "$tmp" "$ACTIVE"; rc=$?
  board_unlock; return "$rc"
}
pid_start() {
  [ -r "/proc/$1/stat" ] || return 1
  sed 's/.*) //' "/proc/$1/stat" | awk '{print $20}'
}
helper_state() {
  local phase_name=$1 status=$2 pid=$3 start=$4 rc=$5 tmp=$ACTIVE.tmp.$$ write_rc
  board_lock || return 1
  awk -F= '$1 != "phase" && $1 !~ /^helper_(status|pid|start|rc)$/' "$ACTIVE" > "$tmp" \
    && printf 'phase=%s\nhelper_status=%s\nhelper_pid=%s\nhelper_start=%s\nhelper_rc=%s\n' \
      "$phase_name" "$status" "$pid" "$start" "$rc" >> "$tmp" && mv "$tmp" "$ACTIVE"; write_rc=$?
  board_unlock; return "$write_rc"
}
run_helper() {  # run_helper <phase> <log> <argv...>; leaves a durable completion receipt in ACTIVE
  local phase_name=$1 log=$2 helper
  shift 2
  helper_state "$phase_name" starting 0 0 pending || stop active_helper_state_unreadable "could not persist helper start intent"
  (
    local hp=$BASHPID hs rc
    exec 8>&-
    hs=$(pid_start "$hp" 2>/dev/null || echo exited)
    helper_state "$phase_name" running "$hp" "$hs" pending || exit 125
    "$@" > "$log" 2>&1; rc=$?
    helper_state "$phase_name" complete "$hp" "$hs" "$rc" || exit 125
    exit "$rc"
  ) & helper=$!
  wait "$helper"; HELPER_RC=$?
}
clear_helper() {
  local tmp=$ACTIVE.tmp.$$ rc
  [ -f "$ACTIVE" ] || return 0
  board_lock || return 1
  awk -F= '$1 !~ /^helper_(status|pid|start|rc)$/' "$ACTIVE" > "$tmp" && mv "$tmp" "$ACTIVE"; rc=$?
  board_unlock; return "$rc"
}
wait_recorded_helper() {
  local ap hp hs status rc now n=0
  RECOVERED_HELPER_STATUS=; RECOVERED_HELPER_RC=
  ap=$(sed -n 's/^phase=//p' "$ACTIVE" | head -1)
  case "$ap" in preflight|chain|closing) ;; *) return 0 ;; esac
  status=$(sed -n 's/^helper_status=//p' "$ACTIVE" | head -1)
  hp=$(sed -n 's/^helper_pid=//p' "$ACTIVE" | head -1)
  hs=$(sed -n 's/^helper_start=//p' "$ACTIVE" | head -1)
  while [ "$status" = starting ] && [ "$n" -lt 5 ]; do
    snooze 1; n=$((n + 1)); status=$(sed -n 's/^helper_status=//p' "$ACTIVE" | head -1)
    hp=$(sed -n 's/^helper_pid=//p' "$ACTIVE" | head -1); hs=$(sed -n 's/^helper_start=//p' "$ACTIVE" | head -1)
  done
  [ -n "$hp" ] || return 0
  [[ $hp =~ ^[0-9]+$ ]] && [[ $hs =~ ^[0-9]+$ ]] \
    || stop active_helper_untracked "active phase=$ap has no exact helper pid identity"
  if [ "$status" != complete ]; then
    while now=$(pid_start "$hp" 2>/dev/null) && [ "$now" = "$hs" ]; do snooze "$POLL"; done
    status=$(sed -n 's/^helper_status=//p' "$ACTIVE" | head -1)
  fi
  rc=$(sed -n 's/^helper_rc=//p' "$ACTIVE" | head -1)
  [ "$status" = complete ] && [[ $rc =~ ^[0-9]+$ ]] \
    || stop active_helper_outcome_unknown "helper phase=$ap pid=$hp ended without a durable completion rc"
  RECOVERED_HELPER_STATUS=$ap; RECOVERED_HELPER_RC=$rc
  say "RECOVER_HELPER_DRAINED gen=$G phase=$ap pid=$hp rc=$rc"
}
close_current_window() {  # one close path for the live loop and restart/resume recovery
  local reason=$1 close_out clrc st auto disp
  say "CLOSE gen=$G reason=$reason"
  # Persist the close intent first: after a restart between the close helper's completion and the verdict write,
  # startup reconciliation can tell this queue-driven close (DONE closed:<reason>, or runner_failed) from a self-close.
  active_set close_reason "$reason" && active_set runner_failed "${RUNNER_FAILED:-}" \
    || stop active_helper_state_unreadable "could not persist close intent for $G"
  run_helper closing "$LOGD/$G-close.txt" "$CLOSE" "$G" "$reason" --auto-first-step
  clrc=$HELPER_RC
  close_out=$(cat "$LOGD/$G-close.txt")
  st=$(jq -r '.State // empty' "$WIN/$G/runner.json" 2>/dev/null)
  auto=$(printf '%s\n' "$close_out" | grep -m1 "^AUTO_RECOVERED gen=$G class=[a-z_]* receipt=/")
  if [ -n "$auto" ]; then
    disp=$("$DISPOSITION" kit 2>/dev/null | head -1)
    [ "$clrc" = 0 ] && [ "$st" = closed ] && [ "$disp" = RUN ] \
      || stop close_failed "window-close rc=$clrc state=$st disposition=${disp:-none} after ${auto%% log=*}: $(printf '%s' "$close_out" | tail -1 | cut -c1-200)"
    auto_recovered "$auto"
  fi
  [ "$clrc" = 0 ] && [ "$st" = closed ] \
    || stop close_failed "window-close rc=$clrc state=$st: $(printf '%s' "$close_out" | tail -1 | cut -c1-400)"
  post_close_usb
  # A lane-reported failure (WINDOW_DONE plan=incomplete, --done failure, owner_blocked) is the normal end of a window
  # once the close and USB gates pass: record DONE closed:<reason> and continue (main semantics; verifier D2). A
  # runner that FAILED is recorded as such and the caller STOPs: the device state is unknown.
  if [ -n "${RUNNER_FAILED:-}" ]; then
    verdict_has_gen "$G" || record_failure runner_failed "$RUNNER_FAILED"
    say "CLOSED_RUNNER_FAILED gen=$G reason=$RUNNER_FAILED"; return 0
  fi
  finish "closed:$reason"; return 0
}
owner_status() {  # "<state><TAB><blocker text>" of $OWNER from pf-task run.status; empty when unreadable
  local r
  r=$("$SELF/pf-task-run-home" resolve "$OWNER" --format shell 2>/dev/null) || return 0
  ( eval "$r" && timeout 100 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$OWNER\"}" 2>/dev/null ) \
    | jq -r '[(.state // ""), ((.blocker | objects | .blocker | objects | .text | strings) // "")] | @tsv' 2>/dev/null
}
ob_reason_token() {  # the token before the first ':' of a blocker text; unknown = empty text, unrecognized = no token
  local t=$1 k
  [ -n "$t" ] || { echo unknown; return 0; }
  k=${t%%:*}
  if [ "$k" != "$t" ] && [[ $k =~ ^[a-z][a-z0-9_]{0,62}$ ]]; then echo "$k"; else echo unrecognized; fi
}
ob_is_transient() { local x; for x in $OB_TRANSIENT_REASONS; do [ "$x" = "$1" ] && return 0; done; return 1; }
# One owner run.status sample. rc 0 = close the window with failure; rc 1 = keep it. The streak state lives in
# wait_current_window's locals (ob_first = first blocked sample of the streak, ob_n = blocked samples, ob_unk =
# consecutive samples with no readable reason); only a readable non-blocked state ends a streak.
owner_blocked_sample() {
  local s state text="" reason cls now age close=0
  s=$(owner_status); state=${s%%$'\t'*}
  [ "$s" = "$state" ] || text=${s#*$'\t'}
  now=$(date +%s)
  if [ "$state" != blocked ]; then
    if [ -n "$state" ] && [ "$ob_n" -gt 0 ]; then
      say "OWNER_BLOCKED_CLEARED gen=$G run=$OWNER state=$state age=$(( now - ob_first )) samples=$ob_n"
    fi
    [ -z "$state" ] || { ob_first=0; ob_n=0; ob_unk=0; }
    return 1
  fi
  [ "$ob_n" -gt 0 ] || ob_first=$now
  ob_n=$(( ob_n + 1 )); age=$(( now - ob_first ))
  reason=$(ob_reason_token "$text")
  if [ "$reason" = unknown ]; then cls=unknown; ob_unk=$(( ob_unk + 1 )); [ "$ob_unk" -ge 2 ] && close=1
  elif ob_is_transient "$reason"; then cls=transient; ob_unk=0; [ "$age" -ge "$OB_TRANSIENT_MAX_S" ] && close=1
  else cls=hard; ob_unk=0; close=1; fi
  if [ "$close" = 1 ]; then
    needs owner_blocked "OwnerRun $OWNER is blocked (refuses run.send; reason=$reason class=$cls age=${age}s samples=$ob_n) while window $G is open; closed with failure; rotate the lane and re-seal a new generation"
    say "OWNER_BLOCKED gen=$G run=$OWNER reason=$reason class=$cls age=$age samples=$ob_n action=close; closing with failure"
    return 0
  fi
  # kept: transient closes once age reaches limit; unknown closes on the next blocked sample, recheck_after seconds on
  say "OWNER_BLOCKED_TRANSIENT gen=$G run=$OWNER reason=$reason class=$cls age=$age samples=$ob_n $([ "$cls" = transient ] && echo "limit=$OB_TRANSIENT_MAX_S" || echo "recheck_after=$OB_SAMPLE_S") action=keep"
  return 1
}
wait_current_window() {  # shared by a newly opened window and startup reattachment
  local st t0 m why ob_t=0 ob_first=0 ob_n=0 ob_unk=0 limit
  RUNNER_FAILED=
  t0=${1:-$(date +%s)}
  while :; do
    st=$(jq -r '.State // empty' "$WIN/$G/runner.json" 2>/dev/null)
    case "$st" in
      closed)
        # Only a typed clean close advances the queue; failure, timeout,
        # abort, unknown or unreadable all STOP.
        m=$(jq -r '.Reason | strings' "$WIN/$G/terminal.json" 2>/dev/null)
        clean_runner_reason "$m" && { post_close_usb; finish "runner_closed:$m"; return 0; }
        if jq -e '.RenewalLimit.Schema == "pocketforge.kit-window-renewal-limit/v1"' \
             "$WIN/$G/terminal.json" >/dev/null 2>&1; then
          limit=$(jq -r '.RenewalLimit.Limit | strings' "$WIN/$G/terminal.json")
          needs renewal-limit "iteration window hit ${limit:-unknown}; runner closed with canonical timeout; inspect terminal.json before resuming the queue"
        fi
        verdict_has_gen "$G" || record_failure runner_closed_non_success "${m:-missing_terminal}"
        stop runner_closed_non_success "runner self-closed $G with Reason='${m:-missing or unreadable terminal.json}'; diagnose before the next window" ;;
      failed)
        if [ -f "$WIN/$G/terminal.json" ]; then
          recover_failed_terminal live
          finish runner_auto_recovered
          return 0
        fi
        why=$(jq -r '.Reason // "unknown"' "$WIN/$G/failure.json" 2>/dev/null)
        # After a runner-FAILED window the device state is unknown: close it, then STOP the queue.
        m=failure; RUNNER_FAILED=$why ;;
      open)
        m=""; [ -f "$MARK/$G" ] && m=$(cut -f1 "$MARK/$G" | head -1)
        case "$m" in ""|success|failure) ;; *) stop marker_invalid "window-done marker for $G says '$m'" ;; esac
        [ -n "$m" ] || retry_queued_supersede "$G" "$LANE"
        # A blocked owner cannot hand back its window, but pf-task also shows `blocked` for a bounded child wait that
        # clears by itself. Sample every WQ_OWNER_SAMPLE_S and decide per reason (owner_blocked_sample).
        if [ -z "$m" ] && [ $(( $(date +%s) - ob_t )) -ge "$OB_SAMPLE_S" ]; then ob_t=$(date +%s)
          owner_blocked_sample && m=failure
        fi ;;
      closing) m="" ;;
      *) stop runner_state_unknown "runner.json State='${st:-missing}' for $G" ;;
    esac
    if [ -n "${m:-}" ]; then
      close_current_window "$m"
      [ -n "$RUNNER_FAILED" ] && stop runner_failed "runner failed window $G ($RUNNER_FAILED); closed with failure; device state unknown, diagnose before resuming"
      return 0
    fi
    [ $(( $(date +%s) - t0 )) -ge "$MAXWIN" ] && stop window_wait_timeout "window $G still '$st' after ${MAXWIN}s and no WINDOW_DONE marker"
    snooze "$POLL"
  done
}
requeue_active_row() {  # a restart during preflight: nothing reached the device, so the popped row returns to the head
  local steps note
  if awk -F'\t' -v g="$G" '!/^#/ && $6==g {f=1} END {exit !f}' "$Q" 2>/dev/null; then
    active_remove; say "REQUEUED_AT_START gen=$G phase=preflight (row already queued)"; return 0
  fi
  steps=$(sed -n 's/^steps=//p' "$ACTIVE" | head -1); note=$(sed -n 's/^note=//p' "$ACTIVE" | head -1)
  [[ $steps =~ ^[0-9]{1,3}$ ]] \
    || stop active_row_unrecoverable "active phase=preflight for gen=$G records no steps; re-add the row by hand, then rm $ACTIVE"
  ROW=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(ts)" "$LANE" "$OWNER" "$TOKEN" "$P" "$G" "$steps" "$LABEL" "$note")
  push_head "$ROW" || stop requeue_failed "could not return the preflight row gen=$G to $Q; re-add it by hand, then rm $ACTIVE"
  active_remove; say "REQUEUED_AT_START gen=$G phase=preflight (nothing reached the device)"
}
recover_recorded_active() {  # recover a stranded active runner before reconcile/archive discards its ownership
  local source=$1 st since start ap
  RECOVERED_ACTIVE=0; RUNNER_FAILED=
  load_active_context || return 0
  wait_recorded_helper
  ap=$(sed -n 's/^phase=//p' "$ACTIVE" | head -1)
  if [ -n "${RECOVERED_HELPER_STATUS:-}" ] && [ "${RECOVERED_HELPER_RC:-0}" != 0 ]; then
    case "$RECOVERED_HELPER_STATUS" in
      chain)
        [ -f "$WIN/boot-open-$G.failed.json" ] && return 0
        stop chain_helper_failed "recovered CHAIN helper rc=$RECOVERED_HELPER_RC; refusing reattach" ;;
      closing) stop close_helper_failed "recovered CLOSE helper rc=$RECOVERED_HELPER_RC; refusing reattach" ;;
    esac  # preflight: nothing reached the device whatever its rc; the row is requeued below
  fi
  if [ -n "${RECOVERED_HELPER_STATUS:-}" ] && [ "${RECOVERED_HELPER_RC:-}" = 0 ]; then
    # A durable rc=0 is not the helper's postcondition. Before any reattach, apply the gates the live loop applies to
    # a fresh completion: CHAIN opened a window only with NETREADY_WATCH_SENT in its log ('CHAIN boot-open rc=0'
    # without it is the handoff_failed STOP; neither marker is an unknown chain outcome), and CLOSE finished only with
    # runner State=closed (a close that left the runner open, closing, failed or unreadable is close_failed).
    case "$RECOVERED_HELPER_STATUS" in
      chain)
        if ! grep -q 'NETREADY_WATCH_SENT' "$LOGD/$G-chain.txt" 2>/dev/null; then
          grep -q 'CHAIN boot-open rc=0' "$LOGD/$G-chain.txt" 2>/dev/null \
            && stop handoff_failed "recovered CHAIN helper rc=0: window $G is OPEN but the handoff failed: $(grep -E 'CHAIN_STOP|_REFUSED|_STOP' "$LOGD/$G-chain.txt" 2>/dev/null | tail -1 | cut -c1-200) log=$LOGD/$G-chain.txt (resume with WINDOW_CHAIN_FROM=fill or close it)"
          stop chain_unknown "recovered CHAIN helper rc=0 with neither NETREADY_WATCH_SENT nor 'CHAIN boot-open rc=0' in log=$LOGD/$G-chain.txt; refusing reattach"
        fi ;;
      closing)
        st=$(jq -r '.State // empty' "$WIN/$G/runner.json" 2>/dev/null)
        [ "$st" = closed ] \
          || stop close_failed "recovered CLOSE helper rc=0 left runner State='${st:-missing}' for $G; refusing reattach log=$LOGD/$G-close.txt" ;;
    esac
  fi
  if [ "$ap" = preflight ] && [ ! -f "$WIN/$G/runner.json" ] && [ ! -f "$WIN/boot-open-$G.failed.json" ]; then
    requeue_active_row; return 0
  fi
  if [ ! -f "$WIN/$G/runner.json" ]; then
    [ -f "$WIN/boot-open-$G.failed.json" ] && return 0
    stop active_helper_outcome_unknown "active generation has no runner or boot-open receipt after helper drain"
  fi
  case "$ap" in chain|closing)
    [ -n "${RECOVERED_HELPER_STATUS:-}" ] \
      || stop active_helper_untracked "active phase=$ap has a runner but no durable helper outcome" ;;
  esac
  [ ! -f "$WIN/$G/terminal.json" ] || return 0
  st=$(jq -r '.State // empty' "$WIN/$G/runner.json" 2>/dev/null)
  case "$st" in
    failed)
      RUNNER_FAILED=$(jq -r '.Reason // "unknown"' "$WIN/$G/failure.json" 2>/dev/null); RUNNER_FAILED=${RUNNER_FAILED:-unknown}
      say "RECOVER_CLOSE source=$source gen=$G runner_state=$st reason=failure ($RUNNER_FAILED)"
      close_current_window failure
      [ "$source" = resume ] \
        || stop runner_failed "recovered failed runner closed safely with failure ($RUNNER_FAILED); device state unknown, diagnose before resuming" ;;
    open|closing)
      if [ "$source" = startup ]; then
        # A pause represents an intentional handoff to gpu-14. --resume owns its close;
        # an unpaused service restart reattaches to the still-healthy runner instead.
        [ -f "$PAUSE" ] && return 0
        say "RECOVER_REATTACH source=$source gen=$G runner_state=$st"
        since=$(sed -n 's/^since=//p' "$ACTIVE" | head -1)
        start=$(date -u -d "$since" +%s 2>/dev/null) || stop active_deadline_unreadable "invalid active since='$since'"
        phase "$st"; clear_helper
        wait_current_window "$start"
      else
        say "RECOVER_CLOSE source=$source gen=$G runner_state=$st reason=failure"
        close_current_window failure
      fi ;;
    *) return 0 ;;
  esac
  RECOVERED_ACTIVE=1
}

# 2026-10-26T07:00Z: a systemic validation failure (#1837's template/lane/idle
# regressions) failed all 10 queued rows in one pass without pausing.  Three
# consecutive invalid rows mean the validator or the queue is wrong, not the
# rows: STOP for gpu-14 like the boot-open breaker does.
row_invalid_streak() {  # row_invalid_streak <reason>
  ROW_INVALID_FAILURES=$((ROW_INVALID_FAILURES + 1))
  [ "$ROW_INVALID_FAILURES" -lt 3 ] && return 0
  stop row_invalid_circuit_breaker "third consecutive invalid row reason=$1: $(printf '%s' "$ROW" | cut -c1-200)"
}

process_row() {
  local _ts pre prc ok note env_ok chain_log crc why node_why st t0 m failure_class bo_queue
  IFS=$'\t' read -r _ts LANE OWNER TOKEN P G STEPS LABEL NOTE <<< "$ROW"
  if ! why=$(validate "$LANE" "$OWNER" "$TOKEN" "$P" "$G" "$STEPS" "$LABEL"); then
    [ "$DRY" = 1 ] && { echo "WINDOW_QUEUE_DRY row_invalid reason=$why"; return 1; }
    exec 7>&-
    G=${G:-row-$(date +%s)}; fail_row row_invalid "$why"; needs row "row invalid ($why): $ROW"; say "ROW_INVALID $why"
    row_invalid_streak "$why"; return 0; fi
  if ! why=$(validate_unattended_request "$P" "$G"); then
    [ "$DRY" = 1 ] && { echo "WINDOW_QUEUE_DRY row_invalid reason=$why"; return 1; }
    exec 7>&-
    fail_row unattended_request_invalid "$why"
    needs row "unattended request invalid ($why): $ROW"
    say "ROW_INVALID $why"
    row_invalid_streak "$why"
    return 0
  fi
  ROW_INVALID_FAILURES=0
  if [ "$DRY" != 1 ]; then
    if ! printf 'gen=%s\nowner=%s\nlane=%s\ntoken=%s\npkg=%s\nlabel=%s\nsteps=%s\nnote=%s\nphase=preflight\nsince=%s\n' \
        "$G" "$OWNER" "$LANE" "$TOKEN" "$P" "$LABEL" "$STEPS" "$NOTE" "$(ts)" > "$ACTIVE"; then
      exec 7>&-
      requeue_or_stop
      stop active_write_failed "could not publish owner transition in $ACTIVE"
    fi
    exec 7>&-
  fi
  # Per-generation overrides are gpu-14's file only (gen<TAB>check<TAB>reason); a lane-written note never overrides.
  local -a ovenv=()
  while IFS=$'\t' read -r og oc orsn; do [ "$og" = "$G" ] && [[ $oc =~ ^C[0-9]$ ]] && ovenv+=("KIT_PREFLIGHT_OVERRIDE_$oc=$orsn"); done < <(cat "$OVR" 2>/dev/null)
  if [ "$DRY" = 1 ]; then
    pre=$(run_preflight "$P" "$G" "$OWNER" "$STEPS"); prc=$?
  else
    run_helper preflight "$LOGD/$G-preflight.txt" run_preflight "$P" "$G" "$OWNER" "$STEPS"
    prc=$HELPER_RC; clear_helper; pre=$(cat "$LOGD/$G-preflight.txt")
  fi
  ok=$(printf '%s\n' "$pre" | grep '^KIT_PREFLIGHT result=' | tail -1)
  env_ok=$(printf '%s\n' "$pre" | sed -n 's/^KIT_PREFLIGHT chain_paths_ok=//p' | head -1)
  note="window-queue: when your plan has run to its end (or cannot continue), end the turn with $TOKEN state=WINDOW_DONE gen=$G plan=complete (or plan=incomplete); the queue closes the window from that line."
  [ -n "$NOTE" ] && note="$NOTE | $note"
  local -a cenv=(env); [ -n "$env_ok" ] && cenv+=("PF_WINDOW_IMAGE_PATHS_OK=$env_ok")
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "$pre"
    printf 'WINDOW_QUEUE_DRY chain_cmd=%s\n' "$(printf '%q ' "${cenv[@]}" "$CHAIN" "$P" "$G" "$OWNER" "$TOKEN" "$STEPS" "$LABEL" "$note")"
    [ "$prc" = 0 ]; return
  fi
  if [ "$prc" -ne 0 ]; then
    fail_row preflight "${ok:-rc=$prc}"; needs preflight "kit-preflight FAILED: ${ok:-rc=$prc}; $(printf '%s\n' "$pre" | grep 'result=FAIL' | grep -v '^KIT_PREFLIGHT result' | cut -c1-300 | tr '\n' ' ') log=$LOGD/$G-preflight.txt"
    active_remove; say "PREFLIGHT_FAIL gen=$G $ok"; preflight_notify "$pre" "${ok:-rc=$prc}"; return 0; fi
  say "PREFLIGHT_PASS gen=$G $ok"
  # 2026-10-22 (tsp-mc9m.41.995.133.1): every ExtraBootArgs boot fails the Boot-phase setenv echo until the
  # console_ops fix deploys. While $FB/hold-extrabootargs exists, such a kit fails its row without opening a window.
  # -z also matches a non-empty JSON array value, even one spread over several lines.
  if [ -f "$FB/hold-extrabootargs" ] && grep -rqzE --include='*.json' --exclude='*template*' '"ExtraBootArgs"[[:space:]]*:[[:space:]]*("[^"]+|\[[[:space:]]*")' "$P" 2>/dev/null; then
    fail_row held_extrabootargs "$(head -1 "$FB/hold-extrabootargs")"
    needs held "kit uses ExtraBootArgs while held: $(head -1 "$FB/hold-extrabootargs"); tell the lane to reseal without them or wait for the fix"
    active_remove; say "HELD_EXTRABOOTARGS gen=$G"; return 0; fi
  if why=$(other_window); then requeue_or_stop; active_remove; say "REFUSED other_window_open $why (row returned to head)"; echo "WINDOW_QUEUE_EXIT reason=other_window_open window=$why"; exit 5; fi
  chain_log=$LOGD/$G-chain.txt
  # 2026-10-18 (felentry tsp-mc9m.41.923.42.1): the intermittent FelEntry stall needs a usbmon trace of a NATURAL
  # failure, and the root-only arm is one-shot. While fleet-board/usbmon-autoarm exists, arm it before every window.
  # Arm only when usbmon is loaded (an arm without the module refuses boot-open fel_usbmon_unavailable), and never
  # stop the queue over arming: a failed arm only means this window goes untraced.
  if [ -f "$FB/usbmon-autoarm" ] && [ -z "${WQ_BOARD:-}" ]; then
    arm=$(timeout 30 ssh -T -o BatchMode=yes pf-node-01 'A=/run/pocketforge/fel-usbmon.arm; lsmod | grep -q "^usbmon " || { echo "USBMON_ARM skipped reason=module_absent"; exit 0; }; if sudo -n test -e $A; then echo "USBMON_ARM already=1 $(sudo -n stat -c "%a_%U:%G_%s" $A)"; exit 0; fi; T=$(sudo -n mktemp /run/pocketforge/.fel-usbmon.arm.XXXXXX) && printf "enabled\n" | sudo -n tee $T >/dev/null && sudo -n chown root:root $T && sudo -n chmod 0600 $T && sudo -n mv -f $T $A && echo "USBMON_ARM set=1 $(sudo -n stat -c "%a_%U:%G_%s" $A)"' 2>&1 | tail -1); say "${arm:-USBMON_ARM failed reason=ssh} gen=$G"
  fi
  say "CHAIN start gen=$G label=$LABEL"
  run_helper chain "$chain_log" "${cenv[@]}" "$CHAIN" "$P" "$G" "$OWNER" "$TOKEN" "$STEPS" "$LABEL" "$note"
  crc=$HELPER_RC
  grep -q 'PF_KIT_WINDOW_RUNNER_REFUSED reason=runner_deploy_pending' "$chain_log" 2>/dev/null || DEPLOY_PENDING_SINCE=
  if [ "$crc" = 0 ] && grep -q 'NETREADY_WATCH_SENT' "$chain_log"; then
    record_rootfs_recovery_tally
    BOOT_OPEN_FAILURES=0; BOOT_STREAK_GEN=; set_boot_streak 0 - || stop boot_open_state_unreadable "could not reset $BOOT_STREAK after successful boot-open"
    phase open; clear_helper
    say "CHAIN open gen=$G (bundle + netready sent; lane drives its steps)"
  elif grep -q 'CHAIN boot-open rc=0' "$chain_log"; then
    BOOT_OPEN_FAILURES=0; BOOT_STREAK_GEN=; set_boot_streak 0 - || stop boot_open_state_unreadable "could not reset $BOOT_STREAK after successful boot-open"
    stop handoff_failed "window $G is OPEN but the handoff failed rc=$crc: $(grep -E 'CHAIN_STOP|_REFUSED|_STOP' "$chain_log" | tail -1 | cut -c1-200) log=$chain_log (resume with WINDOW_CHAIN_FROM=fill or close it)"
  elif grep -q 'CHAIN boot-open start' "$chain_log"; then
    why=$(grep -oE 'PF_KIT_RESUME_REFUSED reason=[A-Za-z0-9_]+' "$chain_log" | head -1 | cut -d= -f2); [ -n "$why" ] || why=$(grep -oE 'PF_KIT_WINDOW_RUNNER_REFUSED reason=[A-Za-z0-9_]+' "$chain_log" | head -1 | cut -d= -f2)
    if [ "${why,,}" = runner_deploy_pending ]; then
      # The runner refused BEFORE touching state or the device (drain marker, tsp-mc9m.60.29.84.46): not a failure, not a
      # breaker count. Return the row to the head and retry after the deploy; past the ceiling fall through to the STOP.
      [ -n "$DEPLOY_PENDING_SINCE" ] || DEPLOY_PENDING_SINCE=$(date +%s)
      if [ $(( $(date +%s) - DEPLOY_PENDING_SINCE )) -lt "$DEPLOY_PENDING_MAX" ]; then
        requeue_or_stop; active_remove
        say "DEPLOY_PENDING gen=$G a coordinator runner deploy is draining boot-opens; row returned to head, retry in ${DEPLOY_PENDING_S}s"
        snooze "$DEPLOY_PENDING_S"; return 0
      fi
      say "DEPLOY_PENDING_TIMEOUT gen=$G still draining after ${DEPLOY_PENDING_MAX}s; treating as a boot-open failure"
    fi
    node_why=; [ "${why^^}" != BASE_BOOT_FAILED ] || node_why=$(node_failure < "$chain_log")
    fail_row boot_open_failed "${why:-unknown}" "$node_why"
    failure_class=$(boot_open_class "${why:-}" "$node_why")
    needs boot-open "boot-open FAILED reason=${why:-unknown}${node_why:+ node_failure=$node_why} class=$failure_class rc=$crc log=$chain_log; this generation will not be retried"
    boot_open_disposition "$failure_class"
    bo_queue=continues; [ -z "$BO_STOP" ] || bo_queue=stops
    bootopen_notify "${why:-unknown}" "$failure_class" "$node_why" "$bo_queue"
    case "$BO_STOP" in
      boot_open_failed) stop boot_open_failed "reason=${why:-unknown}${node_why:+ node_failure=$node_why} class=$failure_class rc=$crc log=$chain_log (diagnose before a NEW package+generation)" ;;
      boot_open_circuit_breaker) stop boot_open_circuit_breaker "second consecutive boot-open failure reason=${why:-unknown} rc=$crc log=$chain_log" ;;
      boot_open_state_unreadable) stop boot_open_state_unreadable "could not persist first failure in $BOOT_STREAK" ;;
    esac
    notify_boot_open_failure "${why:-unknown}"
    active_remove
    say "BOOT_OPEN_FAILED_CONTINUE gen=$G reason=${why:-unknown} streak=$BOOT_OPEN_FAILURES"
    return 0
  else
    why=$(grep -oE 'CHAIN_STOP [a-z0-9_]+' "$chain_log" | tail -1 | cut -d' ' -f2)
    case "$why" in ""|runner_clone_unknown|other_window_not_closed|resume_window_not_open) stop "chain_${why:-unknown}" "rc=$crc log=$chain_log" ;; esac
    fail_row chain_refused "$why"; needs chain "window-chain refused before boot-open: $why rc=$crc log=$chain_log"; active_remove; say "CHAIN_REFUSED gen=$G $why"; return 0
  fi
  phase open; clear_helper
  wait_current_window
}

if [ -n "$RESUME_MODE" ]; then
  [ -f "$PAUSE" ] || { echo "WINDOW_QUEUE_RESUME_REFUSED reason=not_paused"; exit 2; }
  exec 8>>"$RL"; flock -n 8 \
    || { echo "WINDOW_QUEUE_RESUME_REFUSED reason=queue_process_running"; exit 2; }
  exec 6>>"$COMPAT"; flock -s -w 30 6 \
    || { echo "WINDOW_QUEUE_RESUME_REFUSED reason=archive_transition_running"; exit 2; }
  ag=$(sed -n 's/^gen=//p' "$ACTIVE" 2>/dev/null | head -1)
  recover_recorded_active resume
  resume_result=$RESUME_MODE
  if [ "${RECOVERED_ACTIVE:-0}" = 1 ]; then
    resume_result=failure
  elif [ -n "$ag" ] && [ ! -f "$MARK/$ag" ]; then
    "$0" --done "$ag" "$RESUME_MODE" resume >/dev/null \
      || { echo "WINDOW_QUEUE_RESUME_REFUSED reason=done_failed gen=$ag"; exit 2; }
  fi
  set_boot_streak 0 - \
    || { echo "WINDOW_QUEUE_RESUME_REFUSED reason=breaker_state_write_failed"; exit 2; }
  st=$(date -u +%Y%m%dT%H%M%SZ)
  mv "$PAUSE" "$PAUSE.resolved-$st"
  [ -f "$ACTIVE" ] && active_resolve "$ACTIVE.resolved-$st"
  say "RESUME gen=${ag:-none} close=$resume_result (pause archived $st)"
  echo "WINDOW_QUEUE_RESUMED gen=${ag:-none} close=$resume_result"
  exit 0
fi

if [ "$NEXT_ONLY" = 1 ]; then  # print the generation the loop would open next, after refreshing the capacity holds
  refresh_held; r=$(head_row); [ -n "$r" ] && { printf '%s\n' "$r" | awk -F'\t' '{print $6}'; exit 0; }
  [ "$(queued_rows)" -gt 0 ] && { echo "WINDOW_QUEUE_NEXT held_all rows=$(queued_rows)"; exit 6; }; echo "WINDOW_QUEUE_NEXT empty"; exit 1
fi
if [ "$DRY" = 1 ]; then
  refresh_held; ROW=$(head_row); [ -n "$ROW" ] || { echo "WINDOW_QUEUE_DRY empty"; exit 0; }
  w=$(other_window) && echo "WINDOW_QUEUE_DRY note=other_window_open window=$w (a real run would refuse)"
  process_row; exit $(( $? == 0 ? 0 : 1 ))
fi
exec 8>>"$RL"; flock -n 8 || { echo "WINDOW_QUEUE_EXIT reason=already_running"; exit 5; }
exec 6>>"$COMPAT"; flock -s -w 30 6 \
  || { echo "WINDOW_QUEUE_EXIT reason=archive_transition_running"; exit 5; }
if [ -f "$BOOT_STREAK" ]; then
  IFS=$'\t' read -r BOOT_OPEN_FAILURES BOOT_STREAK_GEN < "$BOOT_STREAK"
  case "$BOOT_OPEN_FAILURES" in 0|1) ;; *)
    G=startup; LANE=queue; LABEL=breaker
    stop boot_open_state_unreadable "breaker state in $BOOT_STREAK is unreadable or unknown" ;;
  esac
else
  BOOT_OPEN_FAILURES=0; BOOT_STREAK_GEN=
fi
[ -f "$PAUSE" ] && { echo "WINDOW_QUEUE_EXIT reason=paused_at_start pause=\"$(head -c 200 "$PAUSE")\""; exit 5; }
recover_recorded_active startup
if ! reconcile_at_start; then
  G=startup; LANE=queue; LABEL=reconcile
  stop reconcile_failed "could not reconcile terminal runner records"
fi
[ -f "$ACTIVE" ] && { echo "WINDOW_QUEUE_EXIT reason=active_item_unresolved gen=$(sed -n 's/^gen=//p' "$ACTIVE") hint=inspect, then rm $ACTIVE"; exit 5; }
say "START pid=$$ once=$ONCE drain=$DRAIN"
idle_logged=0
while :; do
  [ -f "$PAUSE" ] && { say "PAUSED (drained)"; echo "WINDOW_QUEUE_EXIT reason=paused"; exit 0; }
  refresh_held
  if [ -z "$(head_row)" ]; then
    if [ "$(queued_rows)" -gt 0 ]; then
      [ "$ONCE" = 1 ] || [ "$DRAIN" = 1 ] && { echo "WINDOW_QUEUE_EXIT reason=held_all rows=$(queued_rows)"; exit 0; }
      [ "$idle_logged" = 2 ] || say "IDLE all $(queued_rows) queued windows held (owner model at capacity)"; idle_logged=2; snooze "$POLL"; continue
    fi
    [ "$ONCE" = 1 ] || [ "$DRAIN" = 1 ] && { echo "WINDOW_QUEUE_EXIT reason=empty"; exit 0; }
    [ "$idle_logged" = 1 ] || say "IDLE queue empty"; idle_logged=1; snooze "$POLL"; continue
  fi
  idle_logged=0
  if w=$(other_window); then say "REFUSED other_window_open $w"; echo "WINDOW_QUEUE_EXIT reason=other_window_open window=$w"; exit 5; fi
  pop_head || continue
  process_row
  [ "$ONCE" = 1 ] && { echo "WINDOW_QUEUE_EXIT reason=once"; exit 0; }
done
