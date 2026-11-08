#!/usr/bin/env bash
# Close one kit window with the runner service stopped. The queue may request
# the runner's one receipt-decided automatic first step after a failed close.
# The service is restarted on every exit.
# usage: window-close.sh <generation-32hex> <success|failure> [--auto-first-step]
# Test seams: GPU14_ROOT, PF_KIT_WINDOWS_DIR, WC_SYSTEMCTL, WC_RUNNER_ENV.
set -uo pipefail

gen=${1:?generation}; reason=${2:?success|failure}; auto_step=0
[[ $gen =~ ^[0-9a-f]{32}$ ]] \
  || { echo "WINDOW_CLOSE_REFUSED reason=generation_not_32hex gen=$gen"; exit 2; }
case "$reason" in
  success|failure) ;;
  *) echo "WINDOW_CLOSE_REFUSED reason=bad_reason $reason"; exit 2 ;;
esac
case "${3:-}" in
  "") ;;
  --auto-first-step) auto_step=1 ;;
  *) echo "WINDOW_CLOSE_REFUSED reason=bad_flag ${3}"; exit 2 ;;
esac

R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
SYSTEMCTL=${WC_SYSTEMCTL:-systemctl}
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
unit_env=$("$SYSTEMCTL" --user show pf-kit-window-runner.service -p Environment --value 2>/dev/null | tr ' ' '\n')
clone=$(sed -n 's/^PF_KIT_AUTOMATION_REPO=//p' <<<"$unit_env")
[ -n "$clone" ] \
  || clone=$(grep -oE 'deploy-clones/pa-[0-9a-f]+' "$R/build10-windows.md" | tail -1 | sed "s#^#$R/#")
[[ $clone == /* ]] && clone_id=$(realpath -e -- "$clone" 2>/dev/null) && [ -d "$clone_id" ] \
  || { echo "WINDOW_CLOSE_REFUSED reason=deploy_clone_unknown"; exit 3; }
trusted=$(sed -n 's/^PF_KIT_TRUSTED_AUTOMATION_REPOS=//p' <<<"$unit_env")
[ -n "$trusted" ] \
  || { echo "WINDOW_CLOSE_REFUSED reason=runner_trust_configuration_missing"; exit 3; }
canonical_repo_is_trusted "$clone" "$trusted"; trust_rc=$?
case "$trust_rc" in
  0) ;;
  10) echo "WINDOW_CLOSE_REFUSED reason=deploy_clone_unknown"; exit 3 ;;
  12) echo "WINDOW_CLOSE_REFUSED reason=runner_trust_path_unresolved"; exit 3 ;;
  *) echo "WINDOW_CLOSE_REFUSED reason=runner_repo_not_deployed"; exit 3 ;;
esac
runner=$clone/scripts/pf-kit-window-runner
[ -x "$runner" ] || { echo "WINDOW_CLOSE_REFUSED reason=deployed_runner_missing"; exit 3; }

log="$R/close-${gen:0:8}.log"
svc_stopped=1
restore_service() {
  [ "$svc_stopped" = 1 ] || return 0
  svc_stopped=0
  "$SYSTEMCTL" --user start pf-kit-window-runner.service
}
trap restore_service EXIT
trap 'restore_service; exit 130' INT
trap 'restore_service; exit 143' TERM
"$SYSTEMCTL" --user stop pf-kit-window-runner.service
stop_rc=$?
stop_state=$("$SYSTEMCTL" --user is-active pf-kit-window-runner.service 2>/dev/null)
if [ "$stop_rc" -ne 0 ] || [ "$stop_state" != inactive ]; then
  echo "WINDOW_CLOSE_REFUSED reason=runner_service_stop_failed stop_rc=$stop_rc service=${stop_state:-unknown}"
  exit 4
fi

# The in-process close and auto step receive the service's generation-bound
# route/key environment while the service remains stopped.
envf=${WC_RUNNER_ENV:-$HOME/.config/pocketforge/kit-window-runner.env}
# shellcheck source=/dev/null
( if [ -r "$envf" ]; then set -a; . "$envf"; set +a; fi
  PF_KIT_DUT_KEY_SECRET="kit-window/$gen/dut-key" PF_KIT_AUTOMATION_REPO="$clone" \
  PF_KIT_TRUSTED_AUTOMATION_REPOS="$trusted" \
    exec timeout 900 "$runner" close "$gen" --reason "$reason" ) >"$log" 2>&1
rc=$?
state=$(grep -o 'PF_KIT_WINDOW_RUNNER state=[a-z_-]*' "$log" | tail -1)

# A failed boot-open never opened a window. Do not attempt a recovery step for
# a foreign generation whose typed boot-open failure receipt exists.
failed_rec="${PF_KIT_WINDOWS_DIR:-$HOME/.local/state/pocketforge/kit-windows}/boot-open-$gen.failed.json"
not_open=0
[ "$rc" -ne 0 ] && grep -q 'reason=foreign_generation' "$log" && [ -f "$failed_rec" ] && not_open=1

auto=""; auto_refused=""
# close() can reconcile an already-failed runner and return rc 0 with the typed
# result state=failed. That is still a failed close for the queue's requested
# one automatic first step, and remains nonzero if the step refuses.
if [ "$state" = "PF_KIT_WINDOW_RUNNER state=failed" ]; then rc=1; fi
if [ "$rc" -ne 0 ] && [ "$auto_step" = 1 ] && [ "$not_open" = 0 ]; then
  alog="$R/close-${gen:0:8}.auto.log"
  # shellcheck source=/dev/null
  ( if [ -r "$envf" ]; then set -a; . "$envf"; set +a; fi
    PF_KIT_DUT_KEY_SECRET="kit-window/$gen/dut-key" PF_KIT_AUTOMATION_REPO="$clone" \
    PF_KIT_TRUSTED_AUTOMATION_REPOS="$trusted" \
      exec timeout 900 "$runner" \
        auto-first-step "$gen" --actor window-queue ) >"$alog" 2>&1
  arc=$?
  line=$(grep -m1 "^PF_KIT_WINDOW_RUNNER state=auto-recovered generation=$gen " "$alog")
  cls=$(grep -oE ' class=[a-z_]+' <<<"$line" | cut -d= -f2)
  rcpt=$(grep -oE ' receipt=/[^ ]+' <<<"$line" | cut -d= -f2)
  existing=$(grep -oE ' existing=[01]' <<<"$line" | cut -d= -f2)
  if [ "$arc" -eq 0 ] && [ -n "$cls" ] && [ -n "$rcpt" ] && [ -n "$existing" ]; then
    auto="AUTO_RECOVERED gen=$gen class=$cls receipt=$rcpt existing=$existing log=$alog"
    rc=0
  else
    auto_refused=$(grep -oE 'reason=[A-Za-z0-9_]+( Detail="?[A-Za-z0-9_:]+"?)?' "$alog" \
      | tail -1 | tr -d '"' | tr ' ' ':')
    auto_refused="auto=${auto_refused:-rc_$arc} auto_log=$alog"
  fi
fi

restore_service
svc=$("$SYSTEMCTL" --user is-active pf-kit-window-runner.service)
if [ "$not_open" = 1 ]; then
  echo "WINDOW_CLOSE gen=$gen result=not_open boot_open_failed_record=$failed_rec service=$svc (nothing to close; the next window-chain may open)"
  [ "$svc" = active ]; exit
fi
[ -n "$auto" ] && echo "$auto"
echo "WINDOW_CLOSE gen=$gen reason=$reason rc=$rc ${state:-state=unknown} service=$svc clone=${clone##*/} log=$log${auto_refused:+ $auto_refused}"
[ "$rc" -eq 0 ] && [ "$svc" = active ]
