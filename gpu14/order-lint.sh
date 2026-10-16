#!/usr/bin/env bash
# gpu-14: pre-dispatch lint for a live bench order (2026-10-06, after .997.21.8 lost attempts 2-5 to order defects).
# usage: order-lint.sh <order.md>   -> prints ORDER_LINT PASS|FAIL with one line per check; exit 0 only on PASS.
set -u
o=${1:?order}; fail=0
chk() { if [ "$2" = ok ]; then echo "  ok   $1"; else echo "  FAIL $1 :: $2"; fail=1; fi; }
[ -f "$o" ] || { echo "ORDER_LINT FAIL reason=missing_order path=$o"; exit 2; }
l1=$(head -1 "$o")
case "$l1" in "cx-deputy, acting for gpu-14 under contract tsp-mc9m.41.995, authorizes this live bench: "*) chk live_authority_first_line ok ;; *) chk live_authority_first_line "first line is not the bench-rules LIVE AUTHORITY form" ;; esac
/usr/bin/grep -q '^REHEARSAL PASS' "$o" && chk rehearsal_pass_line ok || chk rehearsal_pass_line "no line starting 'REHEARSAL PASS' inside the sealed order"
# Every facade system id named in the order must resolve live (read-only GET) and echo the same Id.
ids=$(/usr/bin/grep -o -E 'Systems/[A-Za-z0-9_.-]+/' "$o" | sed 's#Systems/##; s#/$##' | sort -u)
[ -n "$ids" ] || chk facade_ids "order names no Systems/<id>/ endpoint"
for id in $ids; do
  got=$(curl -sS -m 10 -H @<(pf-secret get lab/pf-redfish-node-01 | sed 's/^/Authorization: Bearer /') "http://pf-node-01.lan:8095/redfish/v1/Systems/$id" 2>/dev/null | jq -r '.Id // empty' 2>/dev/null)
  [ "$got" = "$id" ] && chk "facade_id $id" ok || chk "facade_id $id" "GET Systems/$id did not return Id=$id (got '${got:-none}')"
done
# Every SHA256SUMS the order points at must verify from its own directory.
nm=0
for m in $(/usr/bin/grep -o -E '(/[A-Za-z0-9_.-]+)+/' "$o" | sort -u); do
  [ -f "$m/SHA256SUMS" ] || continue
  nm=$((nm+1))
  # Entries may be relative to the manifest dir or to its parent (r4/SHA256SUMS lists r4/<file>).
  if (cd "$m" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || (cd "$m/.." && sha256sum -c --quiet "$m/SHA256SUMS" >/dev/null 2>&1); then chk "manifest $m" ok; else chk "manifest $m" "SHA256SUMS does not verify from $m or its parent"; fi
done
# An order that relies on hashed files must have had at least one manifest actually checked.
if /usr/bin/grep -q 'SHA256SUMS' "$o" && [ "$nm" -eq 0 ]; then chk manifests_checked "order mentions SHA256SUMS but no referenced <dir>/SHA256SUMS was found to check"; fi
# No improvisation hooks: vague staging phrases that invited discovery after the hold.
/usr/bin/grep -n -i -E 'existing sanctioned staging path|the usual tool|as appropriate' "$o" >/dev/null && chk no_vague_steps "vague step phrase present: $(/usr/bin/grep -n -i -o -E 'existing sanctioned staging path|the usual tool|as appropriate' "$o" | head -1)" || chk no_vague_steps ok
[ $fail = 0 ] && { echo "ORDER_LINT PASS order=$o sha256=$(sha256sum "$o" | cut -c1-64)"; exit 0; } || { echo "ORDER_LINT FAIL order=$o"; exit 1; }
