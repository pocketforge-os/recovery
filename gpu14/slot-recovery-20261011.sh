#!/usr/bin/env bash
# gpu-14 2026-10-11: recover the two full pf-build slots (slot 1 57 KB free, slot 2 259 MB short of the
# 35.4 GB owned-image admission) by the documented path in docs/EPHEMERAL_RUNNERS.md "Persistent pf-build
# cache pressure recovery", then restart the CURRENT pool daemon (automation#1359 is applied later, in its own drain). Bead tsp-mc9m.41.995.60.
# Blocks cleared: Build 7 pf build, qdbus bundle (#1350), platform#317 sim-suite, WPE CI plan.
set -uo pipefail
MM="ssh -4 -o BatchMode=yes -o ConnectTimeout=15 mm@10.0.40.90"
CAND=/home/mm/deploy/pocketforge-automation-28ae3139
SYNC=/home/mm/pocketforge-automation          # synced payload dir, manifest source_sha 4ab16246 (#1379)
MSHA=4ab162467989cedea84698e7dacbefeb694a75c3
ts() { date -u +%FT%TZ; }
say() { echo "$(ts) $*"; }

say "step1 request-drain"
$MM "cd $CAND && scripts/install-runner-pool.sh --request-drain" 2>&1 | tail -3
deadline=$(( $(date +%s) + 150 * 60 ))
while :; do
  st=$($MM "cd $CAND && scripts/install-runner-pool.sh --drain-status" 2>&1 | tail -1)
  say "drain-status $st"
  if printf '%s' "$st" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get("draining") and not d.get("active") and not d.get("busy") else 1)' 2>/dev/null; then break; fi
  [ "$(date +%s)" -lt "$deadline" ] || { say "DRAIN_TIMEOUT: leaving the pool draining but RUNNING; gpu-14 decides"; exit 4; }
  sleep 60
done

say "step2 stop pf-runner-pool.service"
$MM "sudo -n systemctl stop pf-runner-pool.service; systemctl is-active pf-runner-pool.service; sudo -n virsh list --name | grep -c '^mm-eph-' || true" 2>&1 | tail -3
# 2026-10-11 03:15Z: `grep -c ... || echo 0` printed "0\n0" on zero matches (grep exits 1) and aborted a clean drain.
doms=$($MM "sudo -n virsh list --name | grep -c '^mm-eph-'; true" 2>/dev/null | head -n 1 | tr -dc '0-9'); doms=${doms:-unknown}
if [ "${doms:-0}" != 0 ]; then
  say "ABORT: $doms mm-eph domains still running after drain; restoring service (clear-drain + start of the INSTALLED daemon)"
  $MM "sudo -n python3 /usr/local/libexec/pf-runner-pool --config /etc/pocketforge/runner-pool.json --clear-drain; sudo -n systemctl start pf-runner-pool.service; systemctl is-active pf-runner-pool.service" 2>&1 | tail -3
  exit 5
fi

say "step3 cache maintenance (source_sha $MSHA)"
out=$($MM "cd $SYNC && sudo -n python3 scripts/pf-runner-cache-maintenance.py --config config/runner-pool.json --source-sha $MSHA" 2>&1); rc=$?
printf '%s\n' "$out" | tail -n 12
if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -q 'maintenance_status=ok'; then
  say "MAINTENANCE_FAILED rc=$rc; restoring service (clear-drain + start of the INSTALLED daemon), no new install"
  $MM "sudo -n python3 /usr/local/libexec/pf-runner-pool --config /etc/pocketforge/runner-pool.json --clear-drain; sudo -n systemctl start pf-runner-pool.service; systemctl is-active pf-runner-pool.service" 2>&1 | tail -3
  exit 6
fi

say "step4 restart the CURRENT daemon (no #1359 apply: planner advice, apply later in its own drain)"
$MM "cd $CAND && scripts/install-runner-pool.sh --check" 2>&1 | tail -6
$MM "sudo -n python3 /usr/local/libexec/pf-runner-pool --config /etc/pocketforge/runner-pool.json --clear-drain; sudo -n systemctl start pf-runner-pool.service; systemctl is-active pf-runner-pool.service" 2>&1 | tail -3
sleep 120
say "post drain-status $($MM "cd $CAND && scripts/install-runner-pool.sh --drain-status" 2>&1 | tail -1)"
say "SLOT_RECOVERY_DONE"
