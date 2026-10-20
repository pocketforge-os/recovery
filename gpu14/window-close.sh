#!/usr/bin/env bash
# gpu-14 2026-10-15: one command for the kit-window close dance (typed by hand for batch8 and batch9).
# Order is the standing rule: stop pf-kit-window-runner.service, close in-process from the deployed clone, then
# ALWAYS start the service again, even if the close failed. The deploy clone is the one the live service runs.
# usage: window-close.sh <generation-32hex> <success|failure> [--auto-first-step]
# --auto-first-step (tsp-mc9m.41.1030.56.2, the queue only): after a FAILED close, still inside the stopped-service
# bracket, run the deployed runner's `auto-first-step` ONCE. The runner decides from its own receipts; on success this
# prints `AUTO_RECOVERED gen= class= receipt=` and exits 0; on any refusal the close stays failed (`auto=<refusal>`).
# Test seams: GPU14_ROOT, PF_KIT_WINDOWS_DIR, WC_SYSTEMCTL, WC_TOOL, WC_RUNNER_ENV, WC_AUTO_RUNNER.
set -uo pipefail
gen=${1:?generation}; reason=${2:?success|failure}; auto_step=0
[[ $gen =~ ^[0-9a-f]{32}$ ]] || { echo "WINDOW_CLOSE_REFUSED reason=generation_not_32hex gen=$gen"; exit 2; }
case "$reason" in success|failure) ;; *) echo "WINDOW_CLOSE_REFUSED reason=bad_reason $reason"; exit 2;; esac
case "${3:-}" in "") ;; --auto-first-step) auto_step=1 ;; *) echo "WINDOW_CLOSE_REFUSED reason=bad_flag ${3}"; exit 2;; esac
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
SYSTEMCTL=${WC_SYSTEMCTL:-systemctl}; TOOL=${WC_TOOL:-pf-automation-tool}
unit_env=$("$SYSTEMCTL" --user show pf-kit-window-runner.service -p Environment --value 2>/dev/null | tr ' ' '\n')
clone=$(sed -n 's/^PF_KIT_AUTOMATION_REPO=//p' <<<"$unit_env")
[ -n "$clone" ] || clone=$(grep -oE 'deploy-clones/pa-[0-9a-f]+' "$R/build10-windows.md" | tail -1 | sed "s#^#$R/#")
[ -d "$clone" ] || { echo "WINDOW_CLOSE_REFUSED reason=deploy_clone_unknown"; exit 3; }
log="$R/close-${gen:0:8}.log"
"$SYSTEMCTL" --user stop pf-kit-window-runner.service
# 2026-10-19: when staging_required, close needs the generation-bound DUT key ref and the bench route
# (PF_BENCH_DUT_HOST and friends). The service gets them from its env file; an in-process close must load it too.
envf=${WC_RUNNER_ENV:-$HOME/.config/pocketforge/kit-window-runner.env}
# shellcheck source=/dev/null
( if [ -r "$envf" ]; then set -a; . "$envf"; set +a; fi
  PF_KIT_DUT_KEY_SECRET="kit-window/$gen/dut-key" PF_KIT_AUTOMATION_REPO="$clone" \
    exec timeout 900 "$TOOL" pf-kit-window-runner close "$gen" --reason "$reason" ) >"$log" 2>&1
rc=$?
# A failed boot-open never opens a window: the runner then refuses foreign_generation. Say so instead of a bare rc=2.
failed_rec="${PF_KIT_WINDOWS_DIR:-$HOME/.local/state/pocketforge/kit-windows}/boot-open-$gen.failed.json"
not_open=0; [ "$rc" -ne 0 ] && grep -q 'reason=foreign_generation' "$log" && [ -f "$failed_rec" ] && not_open=1
auto=""; auto_refused=""
if [ "$rc" -ne 0 ] && [ "$auto_step" = 1 ] && [ "$not_open" = 0 ]; then
  # The deployed clone's own runner (the service's binary and trust set) runs the step; its trusted adapter is $clone.
  alog="$R/close-${gen:0:8}.auto.log"
  # shellcheck source=/dev/null
  ( if [ -r "$envf" ]; then set -a; . "$envf"; set +a; fi
    PF_KIT_DUT_KEY_SECRET="kit-window/$gen/dut-key" PF_KIT_AUTOMATION_REPO="$clone" \
    PF_KIT_TRUSTED_AUTOMATION_REPOS=$(sed -n 's/^PF_KIT_TRUSTED_AUTOMATION_REPOS=//p' <<<"$unit_env") \
      exec timeout 900 "${WC_AUTO_RUNNER:-$clone/scripts/pf-kit-window-runner}" auto-first-step "$gen" --actor window-queue ) >"$alog" 2>&1
  arc=$?
  line=$(grep -m1 "^PF_KIT_WINDOW_RUNNER state=auto-recovered generation=$gen " "$alog")
  cls=$(grep -oE ' class=[a-z_]+' <<<"$line" | cut -d= -f2); rcpt=$(grep -oE ' receipt=/[^ ]+' <<<"$line" | cut -d= -f2)
  if [ "$arc" -eq 0 ] && [ -n "$cls" ] && [ -n "$rcpt" ]; then
    auto="AUTO_RECOVERED gen=$gen class=$cls receipt=$rcpt existing=$(grep -oE 'existing=[01]' <<<"$line" | cut -d= -f2) log=$alog"; rc=0
  else
    auto_refused=$(grep -oE 'reason=[A-Za-z0-9_]+( Detail="[A-Za-z0-9_:]*")?' "$alog" | tail -1 | tr -d '"' | tr ' ' ':')
    auto_refused="auto=${auto_refused:-rc_$arc} auto_log=$alog"
  fi
fi
"$SYSTEMCTL" --user start pf-kit-window-runner.service
svc=$("$SYSTEMCTL" --user is-active pf-kit-window-runner.service)
state=$(grep -o 'PF_KIT_WINDOW_RUNNER state=[a-z_]*' "$log" | tail -1)
if [ "$not_open" = 1 ]; then
  echo "WINDOW_CLOSE gen=$gen result=not_open boot_open_failed_record=$failed_rec service=$svc (nothing to close; the next window-chain may open)"
  [ "$svc" = active ]; exit
fi
[ -n "$auto" ] && echo "$auto"
echo "WINDOW_CLOSE gen=$gen reason=$reason rc=$rc ${state:-state=unknown} service=$svc clone=${clone##*/} log=$log${auto_refused:+ $auto_refused}"
[ "$rc" -eq 0 ] && [ "$svc" = active ]
