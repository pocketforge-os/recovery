#!/usr/bin/env bash
# gpu-14 2026-10-14: deploy-first redeploy of the live kit-window runner to a reviewed automation head, for the
# .1018.12.20 fix (a refused terminal notice to a released OwnerRun flipped CLOSED window 6c30f32b back to failed on
# every service start, and install --apply refuses while any window is not closed).
# Order: preflight (head reviewed by the caller, clone verified, every package's AutomationSHA reachable)
# -> stop service -> sanctioned `reconcile` of each torn-down-but-failed window with the OLD runner (sets closed; its
# delivery refusal is expected) -> new clone's install --check/--apply (live-window gate must pass) -> watch the
# reconciled windows stay closed for 60 s under the NEW service -> report. Stops at the first refusal.
# usage: runner-redeploy.sh <40-hex head> <reconcile-gen>... [--close-wedged <gen>...] [--packages <pkg-dir>...]
#   reconcile-gen: windows whose terminal receipt is CLOSED but whose runner.json is failed (teardown complete).
#   --close-wedged (2026-10-14, P0 tsp-mc9m.41.1018.12.24): windows the OLD runner can no longer close because a
#   crash-left runner.json.new makes every action refuse runner_state_invalid. The installer refuses while any window
#   is open, and the old close is the broken code, so deploy-first deadlocks. With the service stopped, the NEW clone's
#   reviewed `close --reason failure` recovers the replacement under the admission lock (PF_KIT_WINDOW_RUNNER_RECOVERY)
#   and the OLD runner (the window checkout's trusted repo) then closes it normally. Then the live-window gate passes.
set -uo pipefail
H=${1:?head}; shift
[[ $H =~ ^[0-9a-f]{40}$ ]] || { echo "REDEPLOY_REFUSED reason=bad_head"; exit 2; }
gens=(); wgens=(); pkgs=(); mode=gen
for a in "$@"; do
  if [ "$a" = --packages ]; then mode=pkg; continue; fi
  if [ "$a" = --close-wedged ]; then mode=wedged; continue; fi
  case $mode in
    gen|wedged) [[ $a =~ ^[0-9a-f]{32}$ ]] || { echo "REDEPLOY_REFUSED reason=bad_generation $a"; exit 2; }
                if [ $mode = gen ]; then gens+=("$a"); else wgens+=("$a"); fi ;;
    pkg) pkgs+=("$a") ;;
  esac
done
R=/home/matt/recovery/gpu14; NEW=$R/deploy-clones/pa-${H:0:8}; WR=$HOME/.local/state/pocketforge/kit-windows
ts() { date -u +%FT%TZ; }
OLD=$(systemctl --user show pf-kit-window-runner.service -p Environment --value | tr ' ' '\n' | sed -n 's/^PF_KIT_AUTOMATION_REPO=//p')
[ -d "$OLD" ] || { echo "REDEPLOY_REFUSED reason=old_clone_unknown"; exit 2; }
echo "$(ts) REDEPLOY old=$OLD new=$NEW head=$H"
# 1. clone at the exact head
if [ ! -d "$NEW" ]; then
  git clone -q https://github.com/pocketforge-os/pocketforge-automation "$NEW" && git -C "$NEW" fetch -q origin "$H" && git -C "$NEW" checkout -q --detach "$H" \
    || { echo "REDEPLOY_REFUSED reason=clone_failed"; exit 3; }
fi
[ "$(git -C "$NEW" rev-parse HEAD)" = "$H" ] && [ -z "$(git -C "$NEW" status --porcelain)" ] || { echo "REDEPLOY_REFUSED reason=clone_not_clean_at_head"; exit 3; }
# 2026-10-15 (route #1482): a MERGE_READY head 33 commits behind main lacked the live-proven #1485 declared-reboot fix;
# deploying it would have silently rolled the runner back. The new head must contain the currently deployed head.
OLD_HEAD=$(git -C "$OLD" rev-parse HEAD)
git -C "$NEW" cat-file -e "$OLD_HEAD^{commit}" 2>/dev/null || git -C "$NEW" fetch -q origin "$OLD_HEAD" 2>/dev/null
git -C "$NEW" merge-base --is-ancestor "$OLD_HEAD" "$H" || { echo "REDEPLOY_REFUSED reason=new_head_drops_deployed_commits deployed=$OLD_HEAD new=$H (merge main into the PR branch first)"; exit 3; }
# 2. every package's AutomationSHA must be reachable in the new clone (the runner checks windows out from it)
for p in "${pkgs[@]}"; do
  a=$(jq -r '.AutomationSHA // empty' "$p/boot-open-request.json" 2>/dev/null || jq -r '.AutomationSHA // empty' "$p/boot-open-request.template.json" 2>/dev/null)
  [ -z "$a" ] && a=$(jq -r '.AutomationSHA // empty' "$p/boot-open-request.template.json" 2>/dev/null)
  [ -z "$a" ] && a=$(grep -rhoE 'AutomationSHA[^0-9a-f]{1,6}[0-9a-f]{40}' "$p"/*.json 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
  [[ $a =~ ^[0-9a-f]{40}$ ]] && git -C "$NEW" cat-file -e "$a^{commit}" 2>/dev/null || { echo "REDEPLOY_REFUSED reason=package_automation_sha_unreachable pkg=$p sha=${a:-none}"; exit 3; }
  echo "$(ts) REDEPLOY package ok $p automation=${a:0:12}"
done
# 3. the new clone's own check must report drift only (not a broken script)
"$NEW/scripts/install-pf-kit-window-runner.sh" --check >/dev/null 2>&1; crc=$?
[ $crc -le 1 ] || { echo "REDEPLOY_REFUSED reason=new_check_error rc=$crc"; exit 3; }
# 4. stop the service, then reconcile the named windows with the OLD runner
systemctl --user stop pf-kit-window-runner.service || { echo "REDEPLOY_REFUSED reason=stop_failed"; exit 4; }
systemctl --user is-active --quiet pf-kit-window-runner.service && { echo "REDEPLOY_REFUSED reason=still_active"; exit 4; }
for g in "${gens[@]}"; do
  jq -e '.State=="closed"' "$WR/$g/terminal.json" >/dev/null || { echo "REDEPLOY_STOP reason=terminal_not_closed gen=$g (service left STOPPED)"; exit 5; }
  PF_KIT_AUTOMATION_REPO=$OLD "$OLD/scripts/pf-kit-window-runner" reconcile "$g" > "$R/redeploy-reconcile-$g.out" 2>&1
  s=$(jq -r .State "$WR/$g/runner.json")
  echo "$(ts) REDEPLOY reconcile gen=$g state=$s ($(grep -m1 -oE 'PF_KIT_WINDOW_RUNNER[A-Z_]* [^ ]*( reason=[a-z_]*)?' "$R/redeploy-reconcile-$g.out"))"
  [ "$s" = closed ] || { echo "REDEPLOY_STOP reason=reconcile_not_closed gen=$g (service left STOPPED)"; exit 5; }
done
# 4b. wedged windows: the NEW clone's reviewed close recovers the crash-left replacement under the admission lock
# (PF_KIT_WINDOW_RUNNER_RECOVERY). Its close then refuses checkout_repo_untrusted, because the window checkout came from
# the OLD clone (witness 2026-10-14T10:22Z, c7a0d326). So the now-valid open window is closed by the OLD runner, the
# window's trusted repo, which is a normal sanctioned close. A window with no replacement is closed by the OLD runner directly.
for g in "${wgens[@]}"; do
  s0=$(jq -r .State "$WR/$g/runner.json" 2>/dev/null)
  case "$s0" in open|failed|closing) ;; *) echo "REDEPLOY_STOP reason=not_wedged_state gen=$g state=$s0 (service left STOPPED)"; exit 5;; esac
  if [ -e "$WR/$g/runner.json.new" ]; then
    PF_KIT_AUTOMATION_REPO=$NEW timeout 900 "$NEW/scripts/pf-kit-window-runner" close "$g" --reason failure > "$R/redeploy-recover-$g.out" 2>&1
    grep -q '^PF_KIT_WINDOW_RUNNER_RECOVERY state=completed' "$R/redeploy-recover-$g.out" && [ ! -e "$WR/$g/runner.json.new" ] \
      || { echo "REDEPLOY_STOP reason=recovery_failed gen=$g $(tail -1 "$R/redeploy-recover-$g.out" | cut -c1-160) (service left STOPPED)"; exit 5; }
    echo "$(ts) REDEPLOY recovered gen=$g $(grep -m1 '^PF_KIT_WINDOW_RUNNER_RECOVERY' "$R/redeploy-recover-$g.out" | cut -c1-200)"
  fi
  s=$(jq -r .State "$WR/$g/runner.json" 2>/dev/null)
  if [ "$s" != closed ]; then
    PF_KIT_AUTOMATION_REPO=$OLD timeout 900 "$OLD/scripts/pf-kit-window-runner" close "$g" --reason failure > "$R/redeploy-close-wedged-$g.out" 2>&1; crc2=$?
    s=$(jq -r .State "$WR/$g/runner.json" 2>/dev/null)
    echo "$(ts) REDEPLOY close gen=$g rc=$crc2 state=$s ($(grep -m1 -oE 'PF_KIT_WINDOW_RUNNER[A-Z_]* [^ ]*( reason=[a-z_]*)?' "$R/redeploy-close-wedged-$g.out"))"
  fi
  [ "$s" = closed ] || { echo "REDEPLOY_STOP reason=close_wedged_not_closed gen=$g (service left STOPPED)"; exit 5; }
done
gens+=("${wgens[@]}")
# 5. install the new unit (its live-window gate runs here) and start
"$NEW/scripts/install-pf-kit-window-runner.sh" --apply > "$R/redeploy-apply-${H:0:8}.out" 2>&1; arc=$?
cat "$R/redeploy-apply-${H:0:8}.out" | tail -3
if [ $arc -ne 0 ]; then
  echo "$(ts) REDEPLOY_STOP reason=apply_failed rc=$arc; restarting the OLD unit unchanged"
  systemctl --user start pf-kit-window-runner.service; exit 6
fi
"$NEW/scripts/install-pf-kit-window-runner.sh" --check || { echo "REDEPLOY_STOP reason=post_check_failed"; exit 6; }
# 6. watch: the reconciled windows must stay closed under the new service (the bug flipped them within 0 s)
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 60 ]; do
  for g in "${gens[@]}"; do
    s=$(jq -r .State "$WR/$g/runner.json")
    [ "$s" = closed ] || { echo "$(ts) REDEPLOY_FAIL reason=flipped gen=$g state=$s"; exit 7; }
  done
  sleep 3
done
for g in "${gens[@]}"; do
  echo "$(ts) REDEPLOY window gen=$g state=closed undeliverable=$( [ -f "$WR/$g/terminal.undeliverable.json" ] && jq -c '{Reason,OwnerRun}' "$WR/$g/terminal.undeliverable.json" || echo none) delivered=$( [ -f "$WR/$g/terminal.delivered" ] && echo yes || echo no)"
done
echo "$(ts) REDEPLOY_OK head=$H clone=$NEW active=$(systemctl --user is-active pf-kit-window-runner.service)"
