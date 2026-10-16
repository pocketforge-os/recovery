#!/usr/bin/env bash
# gpu-14 supervised pf-comms receive path (2026-09-27 12:05Z, after the monitoring
# coordinator caught the listener polling a DELETED consumer for ~20 min:
# process alive, consumer + roster gone, nothing delivered — "running is not delivering").
#
# Loop:
#   1. ASSERT the durable consumer exists (pf-comms status lists "agent gpu-14").
#      If it is missing: re-register, print RECEIVE_PATH_REPAIRED and EXIT, so the
#      coordinator is woken and knows the path broke (messages sent while the consumer
#      was gone are NOT replayed; deliver-policy is `new`).
#   2. Listen for a bounded window (default 300 s). Any delivered message: print, EXIT (wake).
#   3. A failed listen (non-zero, no output): count it; 3 in a row -> print RECEIVE_PATH_DEGRADED, EXIT.
# Every iteration writes a heartbeat line to $HB with the consumer verdict, which
# receive-path-check.sh reads at the top of each coordinator turn.
set -u
ID=gpu-14
HB=/home/matt/recovery/gpu14/receive-path.heartbeat
WINDOW=${1:-300}
PIDF=/home/matt/recovery/gpu14/receive-path.pid
echo $$ > "$PIDF"
fails=0
while :; do
  st=$(pf-comms status 2>&1)
  if ! grep -qE "^\s*agent ${ID}\s" <<<"$st"; then
    reg=$(pf-comms register "$ID" top coordinator GE8300 A133 Odyssey campaign tsp-mc9m.41 2>&1 | tail -1)
    echo "$(date -u +%FT%TZ) consumer=MISSING action=re-register result=${reg}" >> "$HB"
    echo "RECEIVE_PATH_REPAIRED id=${ID} at=$(date -u +%FT%TZ) consumer was missing; re-registered (messages sent while missing are lost): ${reg}"
    exit 0
  fi
  # 14:15Z ROOT CAUSE of the three consumer deletions (07:42, 11:40, 14:04): `register` seeds the
  # roster_hb lease once, only a MANAGED listener refreshes it, and the roster-TTL sweep reaps an id
  # whose lease is > PF_COMMS_ROSTER_TTL (7200 s) old -> consumer deleted 2 h after each register.
  # This plain --batch loop never stamped it. Re-register each iteration: it re-stamps the lease,
  # leaves the existing consumer (cursor/ack floor) as-is, and sends nothing on the bus.
  lease=$(pf-comms register "$ID" top coordinator GE8300 A133 Odyssey campaign tsp-mc9m.41 >/dev/null 2>&1 && echo refreshed || echo refresh_FAILED)
  echo "$(date -u +%FT%TZ) consumer=present lease=$lease pid=$$" >> "$HB"
  out=$(pf-comms listen --id "$ID" --batch --timeout "$WINDOW" 2>&1); rc=$?
  if [ -n "$(tr -d '[:space:]' <<<"$out")" ] && grep -q '"msgid"' <<<"$out"; then
    echo "$out" | tail -c 6000
    echo "gpu-14 supervised listener delivered rc=$rc"
    exit 0
  fi
  if [ "$rc" -ne 0 ]; then
    fails=$((fails+1))
    echo "$(date -u +%FT%TZ) listen rc=$rc fails=$fails out=$(tail -c 200 <<<"$out" | tr '\n' ' ')" >> "$HB"
    if [ "$fails" -ge 3 ]; then
      echo "RECEIVE_PATH_DEGRADED id=${ID} listen failed ${fails}x; last: $(tail -c 400 <<<"$out")"
      exit 0
    fi
    sleep 10
  else
    fails=0
  fi
done
