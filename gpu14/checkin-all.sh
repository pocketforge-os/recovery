#!/usr/bin/env bash
# gpu-14 combined lane check-in timer (owner 2026-10-03: check in on ALL coordinators, max 30 min apart,
# steer on tooling/gaps, report to the owner each interval). Waits, then prints every lane digest.
# usage: checkin-all.sh [interval_seconds=1800] [max_quiet_seconds=1800]
# 2026-10-06 (owner: be efficient with tokens and time): the digest is still taken every interval,
# but the script only EXITS (waking gpu-14) when the signature changed since the last printed
# digest, or when max_quiet elapsed. Signature = lane status(result#N) lines, inbox count,
# driver liveness, STALL presence per lane, disposition asks. A quiet digest is discarded.
set -u
# 2026-10-05: twice gpu-14 launched this detached ("&>/dev/null & disown", ">/dev/null 2>&1 & true"),
# so no completion ever woke the session. It must run as a harness background task, whose stdout is
# a task output FILE. Refuse when stdout is /dev/null.
if [ "$(readlink -f /proc/$$/fd/1)" = /dev/null ]; then
  echo "REFUSED: stdout is /dev/null; run checkin-all.sh with Bash run_in_background, never with & or >/dev/null" >&2; exit 2
fi
# 2026-10-07: gpu-14 armed a second check-in while one was still running (11:53Z, 13:24Z), so duplicate
# digests woke the session. One instance at a time: refuse if another holds the lock.
exec 9>/home/matt/recovery/gpu14/.checkin-all.lock
if ! flock -n 9; then
  echo "REFUSED: another checkin-all.sh is already running (lock held); do not arm a second one" >&2; exit 3
fi
INTERVAL=${1:-1800}; MAXQ=${2:-1800}; SIGF=/home/matt/recovery/gpu14/.checkin-last-signature
start=$(date +%s)
digest() {
# source AFTER the sleep: a rotation during the wait must be reflected (19:20Z digest showed g3)
. /home/matt/recovery/gpu14/current-lanes.env
R=/home/matt/recovery/gpu14
# 2026-10-06: CX-DEPUTY asked gpu-14 for failed-job logs over pf-comms (agent.gpu-14); gpu-14 has no
# listener and saw it only because a SAY line mentioned it. Show bus DMs since the previous check-in
# (non-advancing history; never acks or moves any consumer).
echo "########## GPU14 INBOX (pf-comms DMs, last $(( ${INTERVAL:-1800} + 120 ))s)"
timeout 60 pf-comms history -n 30 --subject agent.gpu-14 2>/dev/null | python3 -c '
import sys, json, time
since = time.time() - int(sys.argv[1]); n = 0
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"): continue
    try: d = json.loads(line)
    except Exception: continue
    ts = d.get("ts") or 0
    try: ts = float(ts)
    except Exception: ts = 0
    if ts < since: continue
    n += 1
    print("INBOX", time.strftime("%H:%M:%SZ", time.gmtime(ts)), d.get("from"), "->", (d.get("body") or d.get("text") or "")[:600].replace("\n", " "))
print("GPU14_INBOX_NEW n=%d" % n)' "$(( ${INTERVAL:-1800} + 120 ))"
echo "########## DEPUTY"
/home/matt/recovery/gpu14/checkin-digest.sh 0
echo "########## STEAMLINK"
/home/matt/recovery/gpu14/sl-checkin.sh 0 | /usr/bin/grep -v -E 'CALL wait'
echo "########## GPUCAP"
pgrep -u matt -f "lane-drive.sh ${GPUCAP_RUN:0:12}" >/dev/null && echo "gpucap-driver=ALIVE" || echo "gpucap-driver=GONE"
tail -n 3 $R/gpucap-drive.log 2>/dev/null | cut -c1-300
PYTHONDONTWRITEBYTECODE=1 python3 $R/lane-peek.py $GPUCAP_RUN 14 | /usr/bin/grep -v -E 'CALL wait'
(cd /home/matt/mission-control && bd comments tsp-mc9m.41.924.29 --json 2>/dev/null | jq -r '.[-1] | "\(.created_at) \(.text[0:1000])"')
echo "########## COMPOSITOR"
pgrep -u matt -f "lane-drive.sh ${COMP_RUN:0:12}" >/dev/null && echo "comp-driver=ALIVE" || echo "comp-driver=GONE"
tail -n 3 $R/comp-drive.log 2>/dev/null | cut -c1-300
PYTHONDONTWRITEBYTECODE=1 python3 $R/lane-peek.py $COMP_RUN 14 | /usr/bin/grep -v -E 'CALL wait'
cd /home/matt/mission-control && bd comments tsp-op5a.440 --json 2>/dev/null | jq -r '.[-1] | "\(.created_at) \(.text[0:1000])"'
gh api orgs/pocketforge-os/actions/runner-groups/7/runners --jq '"pf-public runners=\(.total_count)"' 2>/dev/null
}
while :; do
  sleep "$INTERVAL"
  out=$(digest 2>&1)
  sig=$(printf '%s\n' "$out" | /usr/bin/grep -E 'status\(result#|GPU14_INBOX_NEW|driver=|STALL_CHECK|NO_DISPOSITION|asking disposition|MISSING|REFUS' | sed -E 's/idle=[0-9]+m/idle=*/; s/^[0-9T:-]+Z //' | sort | sha256sum | cut -c1-16)
  quiet=$(( $(date +%s) - start ))
  prev=$(cat "$SIGF" 2>/dev/null)
  if [ "$sig" != "$prev" ] || [ "$quiet" -ge "$MAXQ" ]; then
    printf '%s\n' "$sig" > "$SIGF"
    if [ "$sig" != "$prev" ]; then echo "CHECKIN_REASON=changed quiet_s=$quiet"; else echo "CHECKIN_REASON=max_quiet quiet_s=$quiet"; fi
    printf '%s\n' "$out"
    exit 0
  fi
done
