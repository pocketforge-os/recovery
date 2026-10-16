#!/usr/bin/env bash
# Top-of-turn liveness ASSERTION for gpu-14's receive path. It asserts DELIVERY
# preconditions, not "a process is running":
#   1. the durable consumer exists on the broker;
#   2. exactly one supervised listener loop is running;
#   3. its heartbeat is fresh (< WINDOW + 120 s) and says consumer=present.
# Prints RECEIVE_PATH OK|FAIL with each reason. Exit 0 = OK, 1 = FAIL.
set -u
ID=gpu-14; HB=/home/matt/recovery/gpu14/receive-path.heartbeat; MAXAGE=${1:-420}
fail=0
if pf-comms status 2>&1 | grep -qE "^\s*agent ${ID}\s"; then echo "consumer: present"; else echo "consumer: MISSING"; fail=1; fi
# the loop records its own pid ($$; command-substitution subshells share its argv, so pgrep counts lie)
PIDF=/home/matt/recovery/gpu14/receive-path.pid
sp=$(cat "$PIDF" 2>/dev/null)
if [ -n "$sp" ] && ps -o args= -p "$sp" 2>/dev/null | grep -q "listen-supervised.sh"; then echo "supervised_listener: pid $sp alive"; else echo "supervised_listener: NOT running (pidfile=${sp:-none})"; fail=1; fi
# a listener is supervised if any of its first 3 ancestors is listen-supervised.sh
stray=$(pgrep -f "^bash /home/matt/.local/bin/pf-comms listen --id ${ID}" | while read p; do
  q=$p; sup=0
  for _ in 1 2 3; do q=$(ps -o ppid= -p "$q" | tr -d ' '); [ -z "$q" ] && break
    ps -o args= -p "$q" | grep -q "listen-supervised.sh" && { sup=1; break; }; done
  [ "$sup" -eq 0 ] && echo "$p"; done | wc -l)
[ "$stray" -gt 0 ] && { echo "stray_unsupervised_listeners: $stray"; fail=1; }
# 14:15Z: the roster-TTL sweep deletes the consumer when the roster_hb lease is > 7200 s old (root
# cause of the 07:42/11:40/14:04 losses). Assert the lease is fresh (the loop re-stamps it every window).
TC=$(pf-comms config show 2>/dev/null | grep '^token_command=' | cut -d= -f2-)
URL=$(pf-comms config show 2>/dev/null | grep '^url=' | cut -d= -f2-)
lease=$(nats --server "${PF_COMMS_URL:-$URL}" --token "$(eval "$TC" 2>/dev/null)" kv get roster_hb "$ID" --raw 2>/dev/null | head -1)
if [[ "$lease" =~ ^[0-9]+$ ]]; then
  lage=$(( $(date -u +%s) - lease )); echo "roster_lease: age=${lage}s (sweep reaps at 7200s)"
  [ "$lage" -gt 1800 ] && { echo "roster_lease: STALE"; fail=1; }
else
  echo "roster_lease: unreadable ('${lease:0:40}')"; fail=1
fi
if [ -f "$HB" ]; then
  last=$(tail -1 "$HB"); ts=$(cut -d' ' -f1 <<<"$last")
  age=$(( $(date -u +%s) - $(date -u -d "$ts" +%s 2>/dev/null || echo 0) ))
  echo "heartbeat: age=${age}s last='${last}'"
  { [ "$age" -gt "$MAXAGE" ] || ! grep -q "consumer=present" <<<"$last"; } && fail=1
else
  echo "heartbeat: none"; fail=1
fi
# 2026-09-27: the verdict line also carries the supervisors forcing function, so the
# top-of-turn `| tail -1` shows any lane/orphan run with no live supervisor (4th wake-source slip).
SUP=$(python3 /home/matt/recovery/gpu14/supervisors-check.py 2>&1 | grep -E '^(MISSING|SUPERVISORS)' | tr '\n' ' ')
if [ "$fail" -eq 0 ]; then echo "RECEIVE_PATH OK | $SUP"; exit 0; fi
# one bounded recheck so a single transient broker/status hiccup is shown but not fatal;
# the first attempt's reasons stay printed above (12:18Z: one transient FAIL, OK 5 s later)
if [ -z "${RPC_RECHECK:-}" ]; then echo "RECEIVE_PATH first-attempt FAIL; rechecking in 5 s"; sleep 5; RPC_RECHECK=1 exec "$0" "$@"; fi
echo "RECEIVE_PATH FAIL | ${SUP:-}"; exit 1
