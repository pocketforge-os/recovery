#!/usr/bin/env bash
# gpu-14 2026-10-13: a1w-window-2 (gen 473cb775) passed its sequence-0 network bootstrap at 19:31:48Z and then died on
# the runner's 600 s idle limit: the netready step and PF_KIT_NETWORK_READY are gpu-14's, and nothing woke gpu-14 when
# the receipt landed (lane-drive keeps waiting on WINDOW_STEP). This watcher removes that hop: start it right after a
# successful boot-open. It waits for the delivered seq-0 receipt, reads the PASS host line from the package's
# step stdout, runs the package's own netready.sh with that host, and sends PF_KIT_NETWORK_READY to the OwnerRun.
# usage: window-netready-watch.sh [--dry-run] <package-dir> <generation> <owner-run> <TOKEN>
#   --dry-run: parse and report only (no netready, no message).
# rc: 0 sent (or dry-run parsed), 2 bootstrap FAIL / malformed, 3 window closed first, 4 timeout, 5 netready refused,
#     6 send failed.
set -uo pipefail
dry=0; [ "${1:-}" = --dry-run ] && { dry=1; shift; }
pkg=${1:?package dir}; gen=${2:?generation}; owner=${3:?owner run}; token=${4:?status token}
[[ $gen =~ ^[0-9a-f]{32}$ ]] || { echo "NETREADY_WATCH_REFUSED reason=bad_generation"; exit 2; }
W=$HOME/.local/state/pocketforge/kit-windows/$gen
out=$pkg/series/revision-000-step-000.stdout
t0=$(date +%s); limit=${NETREADY_WATCH_LIMIT:-1500}
ts() { date -u +%FT%TZ; }
echo "$(ts) NETREADY_WATCH start gen=$gen pkg=$pkg owner=$owner"
while :; do
  if ls "$W"/receipts/receipt-000000-*.json >/dev/null 2>&1 && [ -s "$out" ]; then break; fi
  st=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('State',''))" "$W/runner.json" 2>/dev/null)
  case "$st" in closed|failed) echo "$(ts) NETREADY_WATCH_STOP reason=window_$st"; exit 3;; esac
  [ $(( $(date +%s) - t0 )) -ge "$limit" ] && { echo "$(ts) NETREADY_WATCH_STOP reason=timeout"; exit 4; }
  sleep 2
done
outcome=$(python3 -c "import json,sys,glob;print(json.load(open(glob.glob(sys.argv[1])[0])).get('Outcome',''))" "$W/receipts/receipt-000000-*.json" 2>/dev/null)
# The step stdout carries CRLF line ends (2026-10-13 window-2: ...known_hosts_fields=3^M), so strip CR first.
pass=$(tr -d '\r' < "$out" | grep -E '^PF_KIT_NETWORK_BOOTSTRAP state=PASS host=192\.168\.86\.[0-9]{1,3} user=gamer known_hosts_fields=3$')
fail=$(tr -d '\r' < "$out" | grep -E '^PF_KIT_NETWORK_BOOTSTRAP state=FAIL' | head -1)
echo "$(ts) NETREADY_WATCH seq0 outcome=$outcome pass_lines=$(printf '%s' "$pass" | grep -c . ) fail='${fail:0:120}'"
if [ "$outcome" != pass ] || [ -n "$fail" ] || [ "$(printf '%s\n' "$pass" | grep -c .)" -ne 1 ]; then
  echo "$(ts) NETREADY_WATCH_REFUSED reason=bootstrap_not_single_pass"; exit 2
fi
host=${pass#*host=}; host=${host%% *}
echo "$(ts) NETREADY_WATCH host=$host"
[ "$dry" = 1 ] && { echo "$(ts) NETREADY_WATCH_DRY_OK host=$host"; exit 0; }
# NETREADY_REUSE_OUTPUT=<file>: network-ready already ran for this window (it restarts the runner service), so reuse its
# saved output instead of running it twice.
if [ -n "${NETREADY_REUSE_OUTPUT:-}" ]; then
  nr=$(cat "$NETREADY_REUSE_OUTPUT"); nrc=0; echo "$(ts) NETREADY_WATCH reuse_output=$NETREADY_REUSE_OUTPUT (not re-run)"
elif C=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['Checkout'])" "$W/runner.json" 2>/dev/null) && [ -d "$C" ] \
     && env PATH=/usr/bin:/bin /usr/bin/python3 "$C/scripts/pf-kit-window-prepare" network-ready --help 2>/dev/null | grep -q -- '--source-address'; then
  # 2026-10-15 (route automation#1482, runner d1f5eb2e): network-ready requires the caller's route identity, and the
  # packages' netready.sh (template from before #1482) omits it: window A 19ee901c refused at 06:12:30Z. Declare the
  # kernel's direct route to the DUT; the helper itself refuses gateways/tunnels/mismatches, this only reads it.
  r=$(ip -4 route get "$host" 2>/dev/null | head -1)
  case "$r" in *" via "*|"") echo "$(ts) NETREADY_WATCH_REFUSED reason=route_not_direct route='$r'"; exit 5;; esac
  dev=$(printf '%s\n' "$r" | sed -n 's/.* dev \([^ ]*\).*/\1/p'); src=$(printf '%s\n' "$r" | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  [[ $src =~ ^192\.168\.86\.[0-9]{1,3}$ && -n $dev ]] || { echo "$(ts) NETREADY_WATCH_REFUSED reason=route_identity_invalid dev=$dev src=$src"; exit 5; }
  [ -z "$(git -C "$C" status --porcelain --untracked-files=all)" ] || { echo "$(ts) NETREADY_WATCH_REFUSED reason=checkout_dirty"; exit 5; }
  echo "$(ts) NETREADY_WATCH route interface=$dev source=$src checkout=$(git -C "$C" rev-parse --short=12 HEAD)"
  nr=$(env PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$C/scripts/pf-kit-window-prepare" network-ready "$gen" \
       --package-dir "$pkg" --host-from-receipt "$pkg/series/revision-000.json" --interface "$dev" --source-address "$src" 2>&1); nrc=$?
elif [ -f "$pkg/netready.sh" ]; then
  nr=$(env PATH=/usr/bin:/bin "$pkg/netready.sh" "$host" 2>&1); nrc=$?
else
  # 2026-10-14: native PR-B packages (pf-kit-window-prepare format, e.g. input-coord's guard) ship no netready.sh; run
  # the same network-ready the STAGE.py wrappers call, with the host taken from the seq-0 revision.
  nr=$(pf-automation-tool pf-kit-window-prepare network-ready "$gen" --package-dir "$pkg" --host-from-receipt "$pkg/series/revision-000.json" 2>&1); nrc=$?
fi
printf '%s\n' "$nr" | tail -5 | sed "s/^/$(ts) netready: /"
ok=0
[ "$nrc" -eq 0 ] && printf '%s\n' "$nr" | grep -q "^NETREADY_OK host=$host " && ok=1
# PR-B packages print `PF_KIT_NETWORK_READY state=pass host= generation= ... bundle=<realpath> sha256=<hex>` and no
# NETREADY_OK. 2026-10-14 gamescope-window-4: network-ready PASSED but the package's own netready.sh grep compared the
# bundle path through the /home/matt/recovery symlink and returned 1. Verify the PASS line independently instead:
# host + generation, realpath(bundle) == realpath(pkg/lane-ssh/CAPABILITY-BUNDLE.txt), and the bundle's sha256.
if [ "$ok" = 0 ]; then
  pl=$(printf '%s\n' "$nr" | grep -E "^PF_KIT_NETWORK_READY state=pass host=$host generation=$gen " | tail -1)
  bp=$(printf '%s' "$pl" | sed -n 's/.* bundle=\([^ ]*\) sha256=[0-9a-f]\{64\}.*/\1/p')
  bs=$(printf '%s' "$pl" | sed -n 's/.* sha256=\([0-9a-f]\{64\}\).*/\1/p')
  if [ -n "$pl" ] && [ -n "$bp" ] && [ -n "$bs" ] \
     && [ "$(realpath -e "$bp" 2>/dev/null)" = "$(realpath -e "$pkg/lane-ssh/CAPABILITY-BUNDLE.txt" 2>/dev/null)" ] \
     && [ "$(sha256sum < "$bp" | cut -c1-64)" = "$bs" ]; then
    ok=1; echo "$(ts) NETREADY_WATCH prb_pass_verified netready_rc=$nrc bundle_sha256=$bs"
  elif [ -n "$pl" ] && [ "$nrc" -eq 0 ] && [ ! -e "$pkg/lane-ssh" ]; then
    # native package without lane SSH: no bundle to verify; host + generation PASS line with rc 0 is the contract
    ok=1; echo "$(ts) NETREADY_WATCH prb_pass_verified_native netready_rc=$nrc"
  fi
fi
if [ "$ok" != 1 ]; then
  echo "$(ts) NETREADY_WATCH_REFUSED reason=netready_failed rc=$nrc"; exit 5
fi
msg=$(mktemp "${TMPDIR:-/tmp}/netready-msg.XXXXXX")
printf 'PF_KIT_NETWORK_READY host=%s user=gamer\n(gpu-14 auto-handoff for gen %s: netready.sh printed NETREADY_OK at %s. Submit your next step now; the runner idle limit is 600 s from the last receipt.)\n' "$host" "$gen" "$(ts)" > "$msg"
# 2026-10-14 (owner Q50, automation#1469): packages built with lane-SSH support publish lane-ssh/CAPABILITY-BUNDLE.txt at
# network-ready. Forward only its LANE SSH section (host, user, pinned known_hosts, pf-secret REF, options; no secret bytes).
lb="$pkg/lane-ssh/CAPABILITY-BUNDLE.txt"
if [ -f "$lb" ]; then
  if grep -qiE 'BEGIN [A-Z ]*PRIVATE KEY' "$lb"; then echo "$(ts) NETREADY_WATCH_REFUSED reason=lane_bundle_contains_key_material"; exit 6; fi
  { printf '\nDirect SSH is allowed for this open window only (see the lane-ssh bundle below). Record command, rc and the SHA256 of every staged and pulled file on your bead. No power, flash/FEL, bootloader or console actions. Hand back WINDOW_DONE when finished; gpu-14 closes.\n'
    sed -n '/^LANE SSH -- VALID ONLY FOR THIS OPEN WINDOW/,$p' "$lb"; } >> "$msg"
  echo "$(ts) NETREADY_WATCH lane_ssh_bundle=forwarded path=$lb"
fi
/home/matt/recovery/gpu14/lane-msg.sh "$owner" "$msg" "netready-$gen" "$token" > "$msg.out" 2>&1; src=$?
tail -1 "$msg.out" | cut -c1-160 | sed "s/^/$(ts) send: /"
rm -f "$msg" "$msg.out"
[ "$src" -eq 0 ] || { echo "$(ts) NETREADY_WATCH_REFUSED reason=send_failed rc=$src"; exit 6; }
echo "$(ts) NETREADY_WATCH_SENT host=$host gen=$gen"
