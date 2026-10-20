#!/usr/bin/env bash
# proc-coord 2026-10-16 (tsp-mc9m.41.1030; owner decision D4a): always-on kit-window queue. gpu-14 hand-ran every
# BOOT_READY -> preflight -> window-chain -> wait -> close by hand (gpu14-window-checklist.md), so each window cost a
# gpu-14 turn at both ends and the bench idled between them. This loop pops the head row of
# fleet-board/window-queue.tsv, runs kit-preflight.sh, runs window-chain.sh exactly as gpu-14 calls it, waits for the
# window to end, closes it with window-close.sh, and takes the next row. It wakes gpu-14 (its run_in_background exit)
# only on a stop. What stays with gpu-14: queue ORDER (edit the tsv), Build-16/lockup-last judgement, FEL diagnosis.
#
# usage: window-queue.sh [--once|--drain] [--dry-run]     run the loop (default: forever, idles on an empty queue)
#        window-queue.sh --add <lane-fam> <owner-run> <TOKEN> <pkg-dir> <gen> <steps> <label> [note]
#        window-queue.sh --add-from-status <lane-fam> <owner-run> <TOKEN> "<HANDBACK reason=BOOT_READY ... line>"
#        window-queue.sh --done <gen> success|failure|complete|incomplete   (gpu-14 or the lane-drive hook: the plan ended)
#        window-queue.sh --resume complete|incomplete   (after diagnosing a STOP: records the stopped window, archives pause+active)
#        window-queue.sh --done-from-status '<lane WINDOW_DONE line with gen= plan=>'
#        window-queue.sh --has <gen>     rc 0 queued, 4 active, 3 NEEDS file exists, 1 unknown/finished
#        window-queue.sh --status
# Row (tab-separated): ts lane-fam owner-run TOKEN package-dir generation steps label note. First non-comment = next.
# Loop rc: 0 done (--once/--drain/paused-drain), 1 dry-run preflight FAIL, 2 usage, 5 refused (already running,
#          paused at start, another window open, unresolved active item), 10 STOP (pause file + NEEDS written).
# Stop rules (no retry loops, memory no-retry-loops-in-fel-device-entry): boot-open failure (BASE_BOOT_FAILED, FEL,
# login), window open but handoff failed, close failed, teardown failed, unknown chain outcome, window wait timeout.
# A preflight FAIL or a pre-boot CHAIN_STOP only fails that row (failed.tsv + needs/window-<kind>-<gen>.txt) and the
# loop continues: nothing reached the device.
# Test seams: GPU14_ROOT, WQ_BOARD, PF_KIT_WINDOWS_DIR, WQ_PREFLIGHT, WQ_CHAIN, WQ_CLOSE, WQ_POLL_S, WQ_WINDOW_MAX_S,
#             WQ_PROBE, WQ_OWNER_MODEL, WQ_DISPOSITION, WQ_COMMS, WQ_NOTE_FROM, WQ_NOTE_TO.
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
FB=${WQ_BOARD:-$R/fleet-board}
Q=$FB/window-queue.tsv; QL=$FB/window-queue.tsv.lock; RL=$FB/.window-queue.run.lock; PAUSE=$FB/window-queue.pause
FAILED=$FB/window-queue.failed.tsv; DONE=$FB/window-queue.done.tsv; ACTIVE=$FB/window-queue.active
PREFER=$FB/window-queue.prefer; NEEDS=$FB/needs; MARK=$FB/window-done; LOGD=$FB/window-queue-logs; OVR=$FB/window-queue.overrides.tsv; LOG=$FB/window-queue.log
WIN=${PF_KIT_WINDOWS_DIR:-$HOME/.local/state/pocketforge/kit-windows}
PROBE=${WQ_PROBE:-$R/model-capacity-probe.sh}; OWNER_MODEL=${WQ_OWNER_MODEL:-$R/owner-model.sh}; HELD=$FB/window-queue.held
PREFLIGHT=${WQ_PREFLIGHT:-$SELF/kit-preflight.sh}; CHAIN=${WQ_CHAIN:-$R/window-chain.sh}; CLOSE=${WQ_CLOSE:-$R/window-close.sh}
POLL=${WQ_POLL_S:-30}; MAXWIN=${WQ_WINDOW_MAX_S:-10800}
DISPOSITION=${WQ_DISPOSITION:-$R/window-disposition.sh}; COMMS=${WQ_COMMS:-pf-comms}
NOTE_FROM=${WQ_NOTE_FROM:-gpu-14}; NOTE_TO=${WQ_NOTE_TO:-proc-coord}; AUTOREC=$FB/window-queue.auto-recovered.tsv
ts() { date -u +%FT%TZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
mkdir -p "$FB" "$NEEDS" "$MARK" "$LOGD"
[ -f "$Q" ] || printf '# ts\tlane-fam\towner-run\tTOKEN\tpackage-dir\tgeneration\tsteps\tlabel\tnote  (first non-comment row is next; gpu-14 reorders by editing)\n' > "$Q"
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
known_gen() { awk -F'\t' -v g="$1" '!/^#/ && $6==g {f=1} END {exit !f}' "$Q" 2>/dev/null \
  || awk -F'\t' -v g="$1" '$2==g || $9==g {f=1} END {exit !f}' "$DONE" "$FAILED" 2>/dev/null \
  || grep -qx "gen=$1" "$ACTIVE" 2>/dev/null; }
running() { ( exec 8>>"$RL"; ! flock -n 8 ); }

add_row() {  # add_row <lane> <owner> <TOKEN> <pkg> <gen> <steps> <label> <note>
  local why note
  why=$(validate "$1" "$2" "$3" "$4" "$5" "$6" "$7") || { echo "WINDOW_QUEUE_ADD_REFUSED reason=$why"; return 2; }
  if [ -e "$WIN/$5" ] || [ -e "$WIN/boot-open-$5.json" ] || [ -e "$WIN/boot-open-$5.failed.json" ]; then echo "WINDOW_QUEUE_ADD_REFUSED reason=generation_consumed gen=$5"; return 2; fi
  note=$(printf '%s' "${8:-}" | tr -d '\r\n' | tr '\t' ' ' | cut -c1-400)
  exec 7>>"$QL"; flock -w 30 7 || { echo "WINDOW_QUEUE_ADD_REFUSED reason=queue_lock_timeout"; return 2; }
  if known_gen "$5"; then exec 7>&-; echo "WINDOW_QUEUE_ADD_REFUSED reason=duplicate_generation gen=$5"; return 2; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$note" >> "$Q"
  exec 7>&-
  say "ADD gen=$5 lane=$1 label=$7 depth=$(grep -cvE '^[[:space:]]*(#|$)' "$Q")"
  if running && [ ! -f "$PAUSE" ]; then echo "WINDOW_QUEUE_ADDED gen=$5 running=1"; return 0; fi
  echo "WINDOW_QUEUE_ADDED gen=$5 running=$(running && echo 1 || echo 0) paused=$([ -f "$PAUSE" ] && echo 1 || echo 0) hint=gpu-14 must start/unpause window-queue.sh"; return 11
}
field() { printf '%s' "$2" | grep -oE "(^|[[:space:]])$1=[^[:space:]]+" | head -n1 | sed -E "s/^[[:space:]]*$1=//; s/[\`*,;]+\$//"; }

NEXT_ONLY=0
case "${1:-}" in
  --add) shift; [ $# -ge 7 ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=usage"; exit 2; }; add_row "$@"; exit $? ;;
  --add-from-status)
    [ $# -eq 5 ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=usage"; exit 2; }
    stl=$5; case "$stl" in *"reason=BOOT_READY "*|*"reason=BOOT_READY") ;; *) echo "WINDOW_QUEUE_ADD_REFUSED reason=not_boot_ready"; exit 2;; esac
    pkg=$(field pkg "$stl"); gen=$(field gen "$stl"); steps=$(field steps "$stl"); label=$(field label "$stl")
    note=""; case "$stl" in *" note="*) note=${stl#* note=}; note=${note%%\`*} ;; esac
    [ -n "$pkg" ] && [ -n "$gen" ] && [ -n "$steps" ] && [ -n "$label" ] || { echo "WINDOW_QUEUE_ADD_REFUSED reason=missing_fields pkg=${pkg:-?} gen=${gen:-?} steps=${steps:-?} label=${label:-?}"; exit 2; }
    add_row "$2" "$3" "$4" "$pkg" "$gen" "$steps" "$label" "$note"; exit $? ;;
  --done-from-status)  # gpu-14 2026-10-16: the lane's `WINDOW_DONE gen=<32hex> plan=complete|incomplete` decides the close
    g=$(printf '%s' "${2:-}" | grep -oE 'gen=[0-9a-f]{32}' | head -n1 | cut -d= -f2)
    pl=$(printf '%s' "${2:-}" | grep -oE 'plan=(complete|incomplete)' | head -n1 | cut -d= -f2)
    [ -n "$g" ] && [ -n "$pl" ] || { echo "WINDOW_QUEUE_DONE_REFUSED reason=status_missing_gen_or_plan"; exit 2; }
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
    [ -f "$PAUSE" ] || { echo "WINDOW_QUEUE_RESUME_REFUSED reason=not_paused"; exit 2; }
    case "${2:-}" in complete|incomplete|success|failure) ;; *) echo "WINDOW_QUEUE_RESUME_REFUSED reason=usage hint='--resume complete|incomplete'"; exit 2 ;; esac
    running && { echo "WINDOW_QUEUE_RESUME_REFUSED reason=queue_process_running"; exit 2; }
    ag=$(sed -n 's/^gen=//p' "$ACTIVE" 2>/dev/null | head -1)
    if [ -n "$ag" ] && [ ! -f "$MARK/$ag" ]; then "$0" --done "$ag" "$2" resume >/dev/null || { echo "WINDOW_QUEUE_RESUME_REFUSED reason=done_failed gen=$ag"; exit 2; }; fi
    st=$(date -u +%Y%m%dT%H%M%SZ); mv "$PAUSE" "$PAUSE.resolved-$st"; [ -f "$ACTIVE" ] && mv "$ACTIVE" "$ACTIVE.resolved-$st"
    say "RESUME gen=${ag:-none} close=$2 (pause archived $st)"; echo "WINDOW_QUEUE_RESUMED gen=${ag:-none} close=$2"; exit 0 ;;
  --next) NEXT_ONLY=1; shift ;;
  --status)
    echo "WINDOW_QUEUE_STATUS running=$(running && echo 1 || echo 0) paused=$([ -f "$PAUSE" ] && echo 1 || echo 0) depth=$(grep -cvE '^[[:space:]]*(#|$)' "$Q") active=$(sed -n 's/^gen=//p' "$ACTIVE" 2>/dev/null | head -1) failed=$(grep -c . "$FAILED" 2>/dev/null || echo 0)"; exit 0 ;;
esac

ONCE=0; DRAIN=0; DRY=0
for a in "$@"; do case "$a" in --once) ONCE=1 ;; --drain) DRAIN=1 ;; --dry-run) DRY=1 ;; *) echo "WINDOW_QUEUE_EXIT reason=usage arg=$a"; exit 2 ;; esac; done

other_window() {  # same rule as window-chain.sh: any runner.json State other than closed blocks a new window
  local d s
  for d in "$WIN"/*/; do [ -f "$d/runner.json" ] || continue; s=$(jq -r .State "$d/runner.json" 2>/dev/null)
    # 2026-10-18 (5b629cf4, tsp-mc9m.41.1018.12.39): a failed close with a runner-validated safe acknowledgement is closed
    # for queue purposes, but ONLY when the deployed runner's own queue-disposition says RUN (it re-validates the receipt).
    case "$s" in closed|"") ;;
      failed) if [ -f "$d/safe-acknowledgement.json" ] && [ "$("$R/window-disposition.sh" kit 2>/dev/null | head -1)" = RUN ]; then :
              else echo "$(basename "$d"):$s"; return 0; fi ;;
      *) echo "$(basename "$d"):$s"; return 0 ;; esac; done; return 1; }
# 2026-10-19: while Codex turns fail ~40% (owners blocked mid-window: battsafe 07:13Z, mem 08:39Z), gpu-14 lists the
# owner runs whose windows go first (one run id per line) in $PREFER. Rows are otherwise FIFO. No file = plain FIFO.
head_row() { local r='' h=/dev/null
  [ -s "$HELD" ] && h=$HELD
  [ -s "$PREFER" ] && r=$(awk -F'\t' 'FILENAME==ARGV[1] { x[$1]=1; next } FILENAME==ARGV[2] { if ($0 !~ /^[[:space:]]*(#|$)/) p[$1]=1; next } !/^[[:space:]]*(#|$)/ && ($3 in p) && !($3 in x) {print; exit}' "$h" "$PREFER" "$Q")
  [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
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
    pgrep -f "lane-drive\.sh $o( |\$)" >/dev/null 2>&1 || out+="$o	no_driver"$'\n'
  done
  new=$(printf '%s' "$out" | sort); old=$(sort "$HELD" 2>/dev/null)
  [ "$new" = "$old" ] && return 0
  printf '%s' "$out" > "$HELD.tmp.$$" && mv "$HELD.tmp.$$" "$HELD"
  [ "$DRY" = 1 ] || [ "$NEXT_ONLY" = 1 ] || say "HOLD_SET held=[$(printf '%s' "$out" | awk -F'\t' 'NF {printf "%s%s:%s", (n++ ? " " : ""), $1, $2}')]"; }
pop_head() {
  exec 7>>"$QL"; flock -w 30 7 || return 3
  ROW=$(head_row); [ -n "$ROW" ] || { exec 7>&-; return 1; }
  R_POP="$ROW" awk '!d && $0 == ENVIRON["R_POP"] {d=1; next} {print}' "$Q" > "$Q.tmp.$$" && mv "$Q.tmp.$$" "$Q"; exec 7>&-; }
push_head() { exec 7>>"$QL"; flock -w 30 7 || return 3
  awk -v r="$1" 'BEGIN {d=0} !d && !/^[[:space:]]*(#|$)/ {print r; d=1} {print} END {if (!d) print r}' "$Q" > "$Q.tmp.$$" && mv "$Q.tmp.$$" "$Q"; exec 7>&-; }
needs() { printf '%s NEEDS gpu-14 gen=%s lane=%s label=%s: %s\n' "$(ts)" "$G" "$LANE" "$LABEL" "$2" >> "$NEEDS/window-$1-$G.txt"; }
fail_row() { printf '%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$ROW" >> "$FAILED"; }
stop() {  # stop <why> <detail>
  printf '%s stop reason=%s gen=%s\n' "$(ts)" "$1" "${G:-}" > "$PAUSE"
  sed -i 's/^phase=.*/phase=stopped/' "$ACTIVE" 2>/dev/null
  needs queue-stop "queue STOPPED reason=$1 $2 (pause file written; diagnose, then rm $PAUSE and $ACTIVE and restart)"
  say "STOP reason=$1 gen=${G:-} $2"
  echo "WINDOW_QUEUE_EXIT reason=stop:$1 gen=${G:-} needs=$NEEDS/window-queue-stop-${G:-}.txt"; exit 10; }
finish() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$G" "$OWNER" "$LANE" "$LABEL" "$1" "$P" >> "$DONE"; rm -f "$ACTIVE"; say "DONE gen=$G outcome=$1"; }
phase() { sed -i "s/^phase=.*/phase=$1/" "$ACTIVE"; }
auto_recovered() {  # auto_recovered "<AUTO_RECOVERED gen= class= receipt= existing= log=>": record + tell proc-coord
  local line=${1%% log=*}
  say "$line"; printf '%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$G" "$LANE" "$LABEL" "$line" >> "$AUTOREC"
  printf 'window-queue %s lane=%s label=%s: the close failed, the runner validated its one automatic first step from its own receipts, and the queue continued (the next window full-flashes). close log: %s\n' \
    "$line" "$LANE" "$LABEL" "$LOGD/$G-close.txt" \
    | timeout 60 "$COMMS" send --from "$NOTE_FROM" --to "$NOTE_TO" --topic coord --stdin >/dev/null 2>&1 \
    || say "AUTO_RECOVERED_NOTE_FAILED gen=$G to=$NOTE_TO (recovery stands; tell $NOTE_TO by hand)"; }

process_row() {
  local _ts pre prc ok note env_ok chain_log crc why st t0 m close_out clrc
  IFS=$'\t' read -r _ts LANE OWNER TOKEN P G STEPS LABEL NOTE <<< "$ROW"
  if ! why=$(validate "$LANE" "$OWNER" "$TOKEN" "$P" "$G" "$STEPS" "$LABEL"); then
    [ "$DRY" = 1 ] && { echo "WINDOW_QUEUE_DRY row_invalid reason=$why"; return 1; }
    G=${G:-row-$(date +%s)}; fail_row row_invalid "$why"; needs row "row invalid ($why): $ROW"; say "ROW_INVALID $why"; return 0; fi
  [ "$DRY" = 1 ] || printf 'gen=%s\nowner=%s\nlane=%s\ntoken=%s\npkg=%s\nlabel=%s\nphase=preflight\nsince=%s\n' "$G" "$OWNER" "$LANE" "$TOKEN" "$P" "$LABEL" "$(ts)" > "$ACTIVE"
  # Per-generation overrides are gpu-14's file only (gen<TAB>check<TAB>reason); a lane-written note never overrides.
  local -a ovenv=()
  while IFS=$'\t' read -r og oc orsn; do [ "$og" = "$G" ] && [[ $oc =~ ^C[0-9]$ ]] && ovenv+=("KIT_PREFLIGHT_OVERRIDE_$oc=$orsn"); done < <(cat "$OVR" 2>/dev/null)
  pre=$(env "${ovenv[@]}" "$PREFLIGHT" "$P" "$G" "$OWNER" "$STEPS" 2>&1); prc=$?
  [ "$DRY" = 1 ] || printf '%s\n' "$pre" > "$LOGD/$G-preflight.txt"
  ok=$(printf '%s\n' "$pre" | grep -m1 '^KIT_PREFLIGHT result=' )
  env_ok=$(printf '%s\n' "$pre" | sed -n 's/^KIT_PREFLIGHT chain_paths_ok=//p' | head -1)
  note="window-queue: when your plan has run to its end (or cannot continue), end the turn with \`$TOKEN state=WINDOW_DONE gen=$G plan=complete\` (or plan=incomplete); the queue closes the window from that line."
  [ -n "$NOTE" ] && note="$NOTE | $note"
  local -a cenv=(env); [ -n "$env_ok" ] && cenv+=("PF_WINDOW_IMAGE_PATHS_OK=$env_ok")
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "$pre"
    printf 'WINDOW_QUEUE_DRY chain_cmd=%s\n' "$(printf '%q ' "${cenv[@]}" "$CHAIN" "$P" "$G" "$OWNER" "$TOKEN" "$STEPS" "$LABEL" "$note")"
    [ "$prc" = 0 ]; return
  fi
  if [ "$prc" -ne 0 ]; then
    fail_row preflight "${ok:-rc=$prc}"; needs preflight "kit-preflight FAILED: ${ok:-rc=$prc}; $(printf '%s\n' "$pre" | grep 'result=FAIL' | grep -v '^KIT_PREFLIGHT result' | cut -c1-300 | tr '\n' ' ') log=$LOGD/$G-preflight.txt"
    rm -f "$ACTIVE"; say "PREFLIGHT_FAIL gen=$G $ok"; return 0; fi
  say "PREFLIGHT_PASS gen=$G $ok"
  if why=$(other_window); then push_head "$ROW"; rm -f "$ACTIVE"; say "REFUSED other_window_open $why (row returned to head)"; echo "WINDOW_QUEUE_EXIT reason=other_window_open window=$why"; exit 5; fi
  phase chain; chain_log=$LOGD/$G-chain.txt
  # 2026-10-18 (felentry tsp-mc9m.41.923.42.1): the intermittent FelEntry stall needs a usbmon trace of a NATURAL
  # failure, and the root-only arm is one-shot. While fleet-board/usbmon-autoarm exists, arm it before every window.
  # Arm only when usbmon is loaded (an arm without the module refuses boot-open fel_usbmon_unavailable), and never
  # stop the queue over arming: a failed arm only means this window goes untraced.
  if [ -f "$FB/usbmon-autoarm" ] && [ -z "${WQ_BOARD:-}" ]; then
    arm=$(timeout 30 ssh -T -o BatchMode=yes pf-node-01 'A=/run/pocketforge/fel-usbmon.arm; lsmod | grep -q "^usbmon " || { echo "USBMON_ARM skipped reason=module_absent"; exit 0; }; if sudo -n test -e $A; then echo "USBMON_ARM already=1 $(sudo -n stat -c "%a_%U:%G_%s" $A)"; exit 0; fi; T=$(sudo -n mktemp /run/pocketforge/.fel-usbmon.arm.XXXXXX) && printf "enabled\n" | sudo -n tee $T >/dev/null && sudo -n chown root:root $T && sudo -n chmod 0600 $T && sudo -n mv -f $T $A && echo "USBMON_ARM set=1 $(sudo -n stat -c "%a_%U:%G_%s" $A)"' 2>&1 | tail -1); say "${arm:-USBMON_ARM failed reason=ssh} gen=$G"
  fi
  say "CHAIN start gen=$G label=$LABEL"
  "${cenv[@]}" "$CHAIN" "$P" "$G" "$OWNER" "$TOKEN" "$STEPS" "$LABEL" "$note" > "$chain_log" 2>&1; crc=$?
  if [ "$crc" = 0 ] && grep -q 'NETREADY_WATCH_SENT' "$chain_log"; then say "CHAIN open gen=$G (bundle + netready sent; lane drives its steps)"
  elif grep -q 'CHAIN boot-open rc=0' "$chain_log"; then stop handoff_failed "window $G is OPEN but the handoff failed rc=$crc: $(grep -E 'CHAIN_STOP|_REFUSED|_STOP' "$chain_log" | tail -1 | cut -c1-200) log=$chain_log (resume with WINDOW_CHAIN_FROM=fill or close it)"
  elif grep -q 'CHAIN boot-open start' "$chain_log"; then
    why=$(grep -oE 'PF_KIT_RESUME_REFUSED reason=[A-Za-z_]+' "$chain_log" | head -1 | cut -d= -f2); [ -n "$why" ] || why=$(grep -oE 'PF_KIT_WINDOW_RUNNER_REFUSED reason=[A-Za-z_]+' "$chain_log" | head -1 | cut -d= -f2)
    fail_row boot_open_failed "${why:-unknown}"
    stop boot_open_failed "reason=${why:-unknown} rc=$crc log=$chain_log (node-side: diagnose before any retry; a retry is a NEW package+generation added at the head)"
  else
    why=$(grep -oE 'CHAIN_STOP [a-z0-9_]+' "$chain_log" | tail -1 | cut -d' ' -f2)
    case "$why" in ""|runner_clone_unknown|other_window_not_closed|resume_window_not_open) stop "chain_${why:-unknown}" "rc=$crc log=$chain_log" ;; esac
    fail_row chain_refused "$why"; needs chain "window-chain refused before boot-open: $why rc=$crc log=$chain_log"; rm -f "$ACTIVE"; say "CHAIN_REFUSED gen=$G $why"; return 0
  fi
  phase open; t0=$(date +%s)
  while :; do
    st=$(jq -r '.State // empty' "$WIN/$G/runner.json" 2>/dev/null)
    case "$st" in
      closed)
        # Only an explicit success advances the queue; failure, timeout, abort, unknown or unreadable all STOP.
        m=$(jq -r '.Reason | strings' "$WIN/$G/terminal.json" 2>/dev/null)
        [ "$m" = success ] && { finish runner_closed:success; return 0; }
        finish "runner_closed:${m:-unreadable}"
        stop runner_closed_non_success "runner self-closed $G with Reason='${m:-missing or unreadable terminal.json}'; diagnose before the next window" ;;
      failed)
        [ -f "$WIN/$G/terminal.json" ] && stop teardown_failed "runner terminal State=failed for $G"
        why=$(jq -r '.Reason // "unknown"' "$WIN/$G/failure.json" 2>/dev/null)
        # gpu-14 2026-10-16: after a runner-FAILED window the device state is unknown: close it, then STOP the queue.
        m=failure; RUNNER_FAILED=$why ;;
      open)
        m=""; [ -f "$MARK/$G" ] && m=$(cut -f1 "$MARK/$G" | head -1)
        case "$m" in ""|success|failure) ;; *) stop marker_invalid "window-done marker for $G says '$m'" ;; esac
        # gpu-14 2026-10-19 (a39b22b4): a BLOCKED OwnerRun (second Codex overload, .995.130) refuses every send, so
        # nothing can drive or hand back the window; it would idle to the 3600 s limit with the DUT up. Every 5 min,
        # read the owner's state; if blocked, close with failure now (normal teardown) and continue with the next row.
        if [ -z "$m" ] && [ $(( $(date +%s) - ${ob_t:-0} )) -ge 300 ]; then ob_t=$(date +%s)
          ob=$(r=$("$SELF/pf-task-run-home" resolve "$OWNER" --format shell 2>/dev/null) && eval "$r" && timeout 100 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$OWNER\"}" 2>/dev/null | jq -r '.state // empty')
          if [ "$ob" = blocked ]; then m=failure; needs owner_blocked "OwnerRun $OWNER is blocked (refuses run.send) while window $G is open; closed with failure; rotate the lane and re-seal a new generation"; say "OWNER_BLOCKED gen=$G run=$OWNER; closing with failure"; fi
        fi ;;
      closing) m="" ;;
      *) stop runner_state_unknown "runner.json State='${st:-missing}' for $G" ;;
    esac
    if [ -n "${m:-}" ]; then
      phase closing; say "CLOSE gen=$G reason=$m"
      close_out=$("$CLOSE" "$G" "$m" --auto-first-step 2>&1); clrc=$?; printf '%s\n' "$close_out" > "$LOGD/$G-close.txt"
      st=$(jq -r '.State // empty' "$WIN/$G/runner.json" 2>/dev/null)
      auto=$(printf '%s\n' "$close_out" | grep -m1 "^AUTO_RECOVERED gen=$G class=[a-z_]* receipt=/")
      if [ -n "$auto" ]; then
        disp=$("$DISPOSITION" kit 2>/dev/null | head -1)
        [ "$clrc" = 0 ] && [ "$st" = closed ] && [ "$disp" = RUN ] \
          || stop close_failed "window-close rc=$clrc state=$st disposition=${disp:-none} after ${auto%% log=*}: $(printf '%s' "$close_out" | tail -1 | cut -c1-200)"
        auto_recovered "$auto"
      fi
      [ "$clrc" = 0 ] && [ "$st" = closed ] || stop close_failed "window-close rc=$clrc state=$st: $(printf '%s' "$close_out" | tail -1 | cut -c1-400)"
      finish "closed:$m"
      [ -n "${RUNNER_FAILED:-}" ] && stop runner_failed "runner failed window $G ($RUNNER_FAILED); closed with failure; device state unknown, diagnose before resuming"
      return 0
    fi
    [ $(( $(date +%s) - t0 )) -ge "$MAXWIN" ] && stop window_wait_timeout "window $G still '$st' after ${MAXWIN}s and no WINDOW_DONE marker"
    snooze "$POLL"
  done
}

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
[ -f "$PAUSE" ] && { echo "WINDOW_QUEUE_EXIT reason=paused_at_start pause=\"$(head -c 200 "$PAUSE")\""; exit 5; }
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
