#!/usr/bin/env bash
# gpu-14 file-driven device queue (2026-10-09 ~06:50Z, replaces after-v8.sh).
# Each step re-reads $Q, so inserting or reordering steps needs only a `.new` + `mv` of queue.tsv; the runner is never killed.
# queue.tsv: name<TAB>kit|script|gate|result|kit-resume-boot-open|kit-resume-open|kit-resume-step|kit-resume-close<TAB>path<TAB>sha256<TAB>manifest(kit; '-' otherwise)<TAB>receipt-prefix|log-prefix<TAB>args...
# A step runs at most once: its name is appended to queue.done BEFORE it starts. Seal mismatch skips that step.
# An --offline-only / --check kit smoke (no device) does not hold the queue. The runner exits when no step is left.
set -u
G=${SQ_DIR:-/home/matt/recovery/gpu14}; Q=$G/queue.tsv; DONE=$G/queue.done; ACTIVE=$G/kit-resume.active; DRY=${1:-}
touch "$DONE"
if [ -n "$DRY" ]; then
  cp "$DONE" "$DONE.dry"; DONE=$DONE.dry
  find "$ACTIVE.dry" -maxdepth 0 -type f -delete 2>/dev/null
  [ ! -f "$ACTIVE" ] || cp "$ACTIVE" "$ACTIVE.dry"
  ACTIVE=$ACTIVE.dry
fi
# 2026-10-11: a lane's `--render-only` smoke (a-cts kits print no_device_actions=yes) held the queue for minutes; it is not a boot.
kit_running() { pgrep -af '^bash (/home/matt/recovery/[^ ]*/kits/[^ ]*/|\./)direct-boot\.sh' | /usr/bin/grep -v -e '--offline-only' -e '--render-only' -e ' --check' | /usr/bin/grep -q .; }
note() { echo "$(date -u +%FT%TZ) $*"; [ -n "$DRY" ] || echo "$(date -u +%FT%TZ) $*" >> $G/device-queue.txt; }
# 2026-10-09: build5-session-r1 ended SESSION_FAIL TEARDOWN_FAILED and this runner started the next device step one second later.
# Before every kit/script step, prove the bench is idle: labgrid place FREE, relays vbus=cut batt=cut, PSU output_on=false.
# Anything else, including an unreadable status, HALTS the queue (exit 3) and quotes what it saw. gpu-14 restarts the runner after checking.
# Outputs are captured first and grepped after (no producer|grep -q under pipefail).
device_idle() {
  local st pw
  st=$(timeout 60 pf-automation-tool pf-device.sh status tsp 2>&1) || true
  case "$st" in *"labgrid place : FREE"*) ;; *) note "HALT before $1: place not FREE: $(printf '%s\n' "$st" | /usr/bin/grep -m1 'labgrid place' | cut -c1-160)"; return 1 ;; esac
  pw=$(timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 matt@pf-node-01.lan 'pf-power status; pf-psu status' 2>&1) || true
  case "$pw" in *"vbus=cut batt=cut"*) ;; *) note "HALT before $1: relays not proven cut: $(printf '%s' "$pw" | tr '\n' ' ' | cut -c1-200)"; return 1 ;; esac
  printf '%s\n' "$pw" | /usr/bin/grep -Eq '"output_on"[[:space:]]*:[[:space:]]*false' || { note "HALT before $1: PSU output not proven off: $(printf '%s' "$pw" | tr '\n' ' ' | cut -c1-200)"; return 1; }
  return 0
}
# A kit without run.log (e.g. a pf-kit-session kit) reports through result.json; show its Outcome/Error and halt on a failed teardown.
step_result() {
  if [ -f "$1/run.log" ]; then tail -1 "$1/run.log"; elif [ -f "$1/result.json" ]; then printf 'result.json %s' "$(tr -d '\n ' < "$1/result.json" | cut -c1-240)"; else rf=$(ls "$1"/*result*.txt 2>/dev/null | head -n1); if [ -n "$rf" ]; then printf '%s %s' "$(basename "$rf")" "$( { /usr/bin/grep -m1 -E 'outcome=|verdict=|RESULT' "$rf" || head -n1 "$rf"; } | cut -c1-240)"; else echo "no run.log, result.json or *result*.txt"; fi; fi
}
booted() { ls "$1"/felboot/post* >/dev/null 2>&1 || ls "$1"/felboot/*.json >/dev/null 2>&1 || note "CHAIN_WARN name=$2 reason=no_felboot_posted R=$1"; }
next_step() { awk -F'\t' -v done="$DONE" 'BEGIN{while((getline l < done)>0) d[l]=1} /^#/||NF<6{next} !($1 in d){print; exit}' "$Q"; }

# Resume rows never acquire or adopt ownership. This node-local record only
# retains the anchor and live-adapter repo needed for deadline/TERM close.
resume_persist() {
  local request="$1" temporary
  temporary=$(mktemp "$G/.kit-resume-active.XXXXXX") || return 1
  if ! jq -ce '{Anchor,Live}' "$request" > "$temporary"; then
    find "$temporary" -maxdepth 0 -type f -delete
    return 1
  fi
  mv "$temporary" "$ACTIVE"
}
resume_matches_active() {
  [ "$(jq -cS '{Anchor,Live}' "$1" 2>/dev/null)" = "$(jq -cS . "$ACTIVE" 2>/dev/null)" ]
}
resume_request() {
  local command="$1" reason="${2:-}" anchor repo receipt request output rc
  anchor=$(jq -er '.Anchor | select(type=="string" and startswith("/"))' "$ACTIVE" 2>/dev/null) || return 3
  repo=$(jq -er '.Live.Repo | select(type=="string" and startswith("/"))' "$ACTIVE" 2>/dev/null) || return 3
  [ -f "$anchor" ] || return 3
  request=$(mktemp "$G/.kit-resume-request.XXXXXX") || return 3
  if [ "$command" = resume-status ]; then
    jq -n --arg anchor "$anchor" --arg repo "$repo" '{Anchor:$anchor,Live:{Repo:$repo}}' > "$request"
  else
    receipt=$(dirname "$anchor")/terminal.json
    jq -n --arg anchor "$anchor" --arg repo "$repo" --arg receipt "$receipt" --arg reason "$reason" \
      '{Anchor:$anchor,Receipt:$receipt,Reason:$reason,Live:{Repo:$repo}}' > "$request"
  fi
  output=$(pf-automation-tool pf-kit-session "$command" --request "$request" 2>&1); rc=$?
  find "$request" -maxdepth 0 -type f -delete
  printf '%s\n' "$output"
  return "$rc"
}
resume_deadline_expired() {
  local anchor deadline deadline_epoch now
  anchor=$(jq -er .Anchor "$ACTIVE" 2>/dev/null) || return 0
  deadline=$(jq -er '.Deadline | select(type=="string")' "$anchor" 2>/dev/null) || return 0
  deadline_epoch=$(date -u -d "$deadline" +%s 2>/dev/null) || return 0
  now=$(date -u +%s)
  [ "$deadline_epoch" -le "$now" ]
}
resume_timeout() {
  local output rc
  output=$(resume_request resume-close timeout); rc=$?
  if [ "$rc" -ne 0 ]; then
    # 2026-10-12 kitres attempt 5: the deadline close refused TEARDOWN_FAILED (graceful poweroff, node bug .1018.8) after
    # writing series/terminal.json with force-off/psu-off/power-zero/reap/lease/place all PASS. Same rule as a refused
    # kit-resume-close: a terminal series is closed, so drop the active record (device_idle still gates every later
    # row) and keep the HALT for gpu-14 to read.
    local term; term="$(dirname "$(jq -r .Anchor "$ACTIVE" 2>/dev/null)")/terminal.json"
    if [ -f "$term" ]; then
      note "resume timeout: series terminal.json present ($(jq -c '{State,Reason}' "$term" 2>/dev/null)); active record dropped (bench idle still proven per row)"
      find "$ACTIVE" -maxdepth 0 -type f -delete
    fi
    note "HALT resume timeout close refused rc=$rc: $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  note "RESUME_TIMEOUT closed: $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"
  find "$ACTIVE" -maxdepth 0 -type f -delete
}
resume_abort() {
  local output rc
  if [ -s "$ACTIVE" ]; then
    output=$(resume_request resume-abort gpu14_abort); rc=$?
    if [ "$rc" -eq 0 ]; then
      note "RESUME_ABORT closed: $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"
      find "$ACTIVE" -maxdepth 0 -type f -delete
    else
      note "HALT resume abort refused rc=$rc; active anchor retained: $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"
    fi
  fi
  exit 130
}
trap resume_abort INT TERM

# 2026-10-11: an edited runner kept running its old code until a hand restart. Between steps (never inside one;
# queue.done carries all state) re-exec when this file's bytes changed since start.
SELF=$(readlink -f "$0"); SELF_SHA=$(sha256sum < "$SELF" | cut -c1-64)
while :; do
  [ -n "$DRY" ] || while kit_running; do sleep 20; done
  if [ -z "$DRY" ] && [ "$(sha256sum < "$SELF" | cut -c1-64)" != "$SELF_SHA" ]; then note "RUNNER_REEXEC code changed (was ${SELF_SHA:0:12})"; exec bash "$SELF"; fi
  if [ -z "$DRY" ] && [ -s "$ACTIVE" ] && resume_deadline_expired; then resume_timeout || exit 3; fi
  line=$(next_step)
  if [ -z "$line" ]; then
    if [ -s "$ACTIVE" ]; then [ -n "$DRY" ] && { note "QUEUE exhausted with resume active"; exit 0; }; sleep 20; continue; fi
    note "QUEUE empty (queue.tsv exhausted)"; exit 0
  fi
  IFS=$'\t' read -r name type path want mf prefix args <<<"$line"
  # 2026-10-13: live kit windows (pf-kit-window-runner, .1018.12) own the bench while opening or open. Ask before every
  # device row and before queue.done: WAIT keeps the row queued; HALT or an unreadable answer stops the queue (fail closed).
  if [ -z "$DRY" ] && [ "$type" != result ]; then
    disp=$("$G/window-disposition.sh" "$type" 2>&1); drc=$?
    case "$drc:$disp" in
      0:RUN) ;;
      0:WAIT) note "WAIT before $name: live kit window opening or open"; sleep 20; continue ;;
      *) note "HALT before $name: window disposition rc=$drc: $(printf '%s' "$disp" | tr '\n' ' ' | cut -c1-200)"; exit 3 ;;
    esac
  fi
  case "$type" in
    kit-resume-boot-open|kit-resume-open) [ ! -e "$ACTIVE" ] || { note "HALT before $name: resume already active: $(jq -cS . "$ACTIVE" 2>/dev/null | cut -c1-200)"; exit 3; } ;;
    kit-resume-step|kit-resume-close)
      [ -s "$ACTIVE" ] || { note "HALT before $name: no active resume anchor"; exit 3; }
      resume_matches_active "$path" || { note "HALT before $name: resume request does not match active anchor: $(jq -cS '{Anchor,Live}' "$path" 2>/dev/null | cut -c1-200)"; exit 3; } ;;
    *) [ ! -s "$ACTIVE" ] || { note "HALT before $name: ordinary row forbidden while resume active: $(jq -cS . "$ACTIVE" 2>/dev/null | cut -c1-200)"; exit 3; } ;;
  esac
  if [ -z "$DRY" ]; then case "$type" in result|kit-resume-open|kit-resume-step|kit-resume-close) ;; *) device_idle "$name" || exit 3 ;; esac; fi
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if [ -n "$DRY" ]; then
    case "$type" in
      kit-resume-boot-open|kit-resume-open) resume_persist "$path" || { note "HALT before $name: resume active record invalid"; exit 3; } ;;
      kit-resume-close) find "$ACTIVE" -maxdepth 0 -type f -delete ;;
    esac
    R="$prefix-$stamp"; echo "DRY next: name=$name type=$type path=$path want=${want:0:8} mf=$mf prefix=$prefix args=[${args//@R@/$R}]"; echo "$name" >> "$DONE"; continue
  fi
  echo "$name" >> "$DONE"
  case "$type" in
    kit-resume-boot-open|kit-resume-open|kit-resume-step|kit-resume-close)
      if [ "$mf" != - ] || [ ! -f "$path" ] || [ "$(sha256sum < "$path" | cut -c1-64)" != "$want" ]; then note "HALT $name: resume request seal mismatch (want ${want:0:8})"; exit 3; fi
      if [ "$type" = kit-resume-boot-open ] || [ "$type" = kit-resume-open ]; then resume_persist "$path" || { note "HALT $name: resume active record invalid"; exit 3; }; fi
      command=${type#kit-}; output=$(pf-automation-tool pf-kit-session "$command" --request "$path" 2>&1); rc=$?
      # 2026-10-12: kitres boot-open HALTed with "reason=BASE_ACQUIRE" cut at 200 chars and left tsp-base held; the full
      # refusal (which step, observed ownership) was lost. Keep every pf-kit-session output whole, beside the queue.
      out_file=$G/resume-outputs/$name-$(date -u +%Y%m%dT%H%M%SZ).txt
      [ -n "$DRY" ] || { mkdir -p "$G/resume-outputs" && printf '%s\n' "$output" > "$out_file"; }
      if [ "$rc" -ne 0 ]; then
        if [ "$type" = kit-resume-boot-open ] && [ ! -f "$(jq -r .Anchor "$path" 2>/dev/null)" ]; then
          find "$ACTIVE" -maxdepth 0 -type f -delete
        fi
        # 2026-10-12 kitres attempt 3: close refused TEARDOWN_FAILED after writing series/terminal.json; the stale active
        # record then blocked every ordinary row until gpu-14 deleted it by hand. A terminal series is closed; device_idle
        # still proves the bench free before any later row, so drop the record and keep the HALT.
        if [ "$type" = kit-resume-close ] && [ -f "$(dirname "$(jq -r .Anchor "$ACTIVE" 2>/dev/null)")/terminal.json" ]; then
          note "$name: series terminal.json present; active record dropped (bench idle still proven per row)"
          find "$ACTIVE" -maxdepth 0 -type f -delete
        fi
        note "HALT $name: $command refused rc=$rc full=$out_file: $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"; exit 3
      fi
      [ "$type" != kit-resume-close ] || find "$ACTIVE" -maxdepth 0 -type f -delete
      note "$name $command complete: $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)" ;;
    kit)
      if ! { [ "$(sha256sum < "$path/$mf" | cut -c1-64)" = "$want" ] && (cd "$path" && sha256sum -c --quiet "$mf"); }; then note "SKIP $name: seal mismatch (want ${want:0:8})"; continue; fi
      # 2026-10-11: g1s13-r43 sent DutExec TimeoutSeconds 700 (the service accepts 1..300). The probe never
      # ran and the 38 min boot produced nothing. Refuse a literal over the limit before booting.
      # A kit's own red test of the bound is not a device call: build7-proof-r1's selftest `dutexec boundtest 301`, and
      # a1-bench-r2's smoke.sh `dutexec evil-step 301` (offline test files smoke.sh / *test*.sh are not scanned).
      over=$(/usr/bin/grep -HnoE '(dutexec[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+|TimeoutSeconds"?[[:space:]]*[:=][[:space:]]*)[0-9]+' "$path"/*.sh 2>/dev/null | /usr/bin/grep -v -e 'dutexec[[:space:]]\+boundtest' -e '^[^:]*/smoke\.sh:' -e '^[^:]*/[^/:]*test[^/:]*\.sh:' | awk '{n=$NF; sub(/.*[^0-9]/,"",n); if (n+0>300) print}' | head -n 3 | tr '\n' ' ')
      if [ -n "$over" ]; then note "SKIP $name: DutExec TimeoutSeconds over the 300 s service limit: $over"; continue; fi
      # 2026-10-11: after the seeded node deploy (test-node-farm 430079f6) the node refuses a seedless FelBoot
      # (credential_seed_required) for any raw not on its fallback allowlist; ctsdiag-r3 (Build 6 CTS raw a50ccb56) would
      # have burned a slot. A pre-seed node has no allowlist file, so nothing is skipped there.
      if [ -f "$path/felboot-request.json" ] && ! jq -e '(.SeedHandle // "") | test("^[0-9a-f]{32}$")' "$path/felboot-request.json" >/dev/null 2>&1; then
        raw=$(jq -r '.ImageSource.RawSHA256 // ""' "$path/felboot-request.json" 2>/dev/null)
        allow=$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 matt@pf-node-01.lan 'cat /usr/local/libexec/pocketforge/redfish/seedless-console-fallback-images.txt 2>/dev/null' | /usr/bin/grep -v '^#')
        if [ -n "$allow" ] && ! /usr/bin/grep -qxF "$raw" <<<"$allow"; then note "SKIP $name: seedless FelBoot of raw ${raw:0:12} is not on the node fallback allowlist (credential_seed_required); reseal with the seeded template"; continue; fi
      fi
      R="$prefix-$stamp"; note "$name START R=$R"
      # 2026-10-11 (build7-proof-r1 takes IMAGE SHA RECEIPT): an args field containing @R@ gets the fresh receipt
      # dir substituted there and is passed as-is; otherwise the receipt dir is prepended as $1 (the default contract).
      # shellcheck disable=SC2086
      if [[ "$args" == *@R@* ]]; then (cd "$path" && bash ./direct-boot.sh ${args//@R@/$R}); else (cd "$path" && bash ./direct-boot.sh "$R" $args); fi
      res=$(step_result "$R"); note "$name $res"; booted "$R" "$name"
      case "$res" in *TEARDOWN_FAILED*|*teardown=fail*) note "HALT after $name: teardown failed; gpu-14 must verify the bench"; exit 3 ;; esac ;;
    script|gate)
      # gate (2026-10-09): a prerequisite step (e.g. a node deploy). A non-zero rc HALTS the queue, so the steps that need it
      # never run without it (deploy-4fa8023 refused on a stale origin/main and firstboot-r3 ran anyway without the seed fix).
      if [ "$(sha256sum < "$path" | cut -c1-64)" != "$want" ]; then note "SKIP $name: script sha mismatch (want ${want:0:8})"; [ "$type" = gate ] && { note "HALT after $name: gate skipped"; exit 3; }; continue; fi
      # 2026-10-10: a relaunch script takes its receipt prefix as $1; kitfix handed back rows with it in the prefix
      # column and empty args, so the script would only print usage. Refuse that row instead of burning its slot.
      if [ -z "$args" ] && grep -q '\${1:?' "$path"; then note "SKIP $name: script requires arg1 (\${1:?...}) but args is empty"; [ "$type" = gate ] && { note "HALT after $name: gate skipped"; exit 3; }; continue; fi
      log="$prefix-$stamp.log"; rc=0; note "$name START log=$log"
      # shellcheck disable=SC2086
      # 2026-10-10: PF_QUEUE_ITEM lets a gate exempt its own START line from its queue-idle preflight (test-node-farm#582).
      PF_QUEUE_ITEM="$name" bash "$path" $args > "$log" 2>&1 || rc=$?
      note "$name rc=$rc last=$(tail -1 "$log" | cut -c1-200)"
      if [ "$type" = gate ] && [ "$rc" -ne 0 ]; then note "HALT after $name: gate rc=$rc"; exit 3; fi ;;
    result)  # log the RESULT line of a kit started outside this runner (path = its receipt dir)
      note "$name $(tail -1 "$path/run.log" 2>/dev/null)"; booted "$path" "$name" ;;
    *) note "SKIP $name: unknown type $type" ;;
  esac
done
