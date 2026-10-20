#!/usr/bin/env bash
# gpu-14 2026-10-15: one command for the kit-window close dance (typed by hand for batch8 and batch9).
# Order is the standing rule: stop pf-kit-window-runner.service, close in-process from the deployed clone, then
# ALWAYS start the service again, even if the close failed. The deploy clone is the one the live service runs.
# usage: window-close.sh <generation-32hex> <success|failure>
set -uo pipefail
gen=${1:?generation}; reason=${2:?success|failure}
[[ $gen =~ ^[0-9a-f]{32}$ ]] || { echo "WINDOW_CLOSE_REFUSED reason=generation_not_32hex gen=$gen"; exit 2; }
case "$reason" in success|failure) ;; *) echo "WINDOW_CLOSE_REFUSED reason=bad_reason $reason"; exit 2;; esac
R=/home/matt/recovery/gpu14
clone=$(systemctl --user show pf-kit-window-runner.service -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^PF_KIT_AUTOMATION_REPO=//p')
[ -n "$clone" ] || clone=$(grep -oE 'deploy-clones/pa-[0-9a-f]+' "$R/build10-windows.md" | tail -1 | sed "s#^#$R/#")
[ -d "$clone" ] || { echo "WINDOW_CLOSE_REFUSED reason=deploy_clone_unknown"; exit 3; }
log="$R/close-${gen:0:8}.log"
systemctl --user stop pf-kit-window-runner.service
# 2026-10-19: when staging_required, close needs the generation-bound DUT key ref and the bench route
# (PF_BENCH_DUT_HOST and friends). The service gets them from its env file; an in-process close must load it too.
envf="$HOME/.config/pocketforge/kit-window-runner.env"
( if [ -r "$envf" ]; then set -a; . "$envf"; set +a; fi
  PF_KIT_DUT_KEY_SECRET="kit-window/$gen/dut-key" PF_KIT_AUTOMATION_REPO="$clone" \
    exec timeout 900 pf-automation-tool pf-kit-window-runner close "$gen" --reason "$reason" ) >"$log" 2>&1
rc=$?
systemctl --user start pf-kit-window-runner.service
svc=$(systemctl --user is-active pf-kit-window-runner.service)
state=$(grep -o 'PF_KIT_WINDOW_RUNNER state=[a-z_]*' "$log" | tail -1)
# A failed boot-open never opens a window: the runner then refuses foreign_generation. Say so instead of a bare rc=2.
failed_rec="$HOME/.local/state/pocketforge/kit-windows/boot-open-$gen.failed.json"
if [ "$rc" -ne 0 ] && grep -q 'reason=foreign_generation' "$log" && [ -f "$failed_rec" ]; then
  echo "WINDOW_CLOSE gen=$gen result=not_open boot_open_failed_record=$failed_rec service=$svc (nothing to close; the next window-chain may open)"
  [ "$svc" = active ]; exit
fi
echo "WINDOW_CLOSE gen=$gen reason=$reason rc=$rc ${state:-state=unknown} service=$svc clone=${clone##*/} log=$log"
[ "$rc" -eq 0 ] && [ "$svc" = active ]
