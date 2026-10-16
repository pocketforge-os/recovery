#!/usr/bin/env bash
# gpu-14 2026-10-11: after the seeded node deploy, seal each Build 7 template and append its queue row.
# The contract (test-node-farm docs/seeded-felboot-contract.md @a270ac13) stages the one-shot seed handle
# "immediately before sealing and queuing", and a node service restart drops staged handles, so this runs only
# AFTER the deploy and only for rows listed in postdeploy-seal.tsv
# (name<TAB>template_dir<TAB>template_manifest_sha256<TAB>seal_cmd<TAB>lane[<TAB>postseal_check]).
# postseal_check (2026-10-11): a command run in the SEALED kit dir that must exit 0, normally the kit's smoke exactly as
# direct-boot.sh calls it. build7-proof-r1, a1-bench-r2 and browser-bakeoff-r1 all failed their own smoke on the sealed
# instance (their tests assumed the template) and never booted. On failure the staged handle is discarded and the row
# is not queued. A row without one prints SEALQ_WARN.
# usage: seal-and-queue.sh [--dry] [--reseal name ...] [name ...]     (default: every pending row, in file order)
# --reseal (2026-10-11, after node deploy a32815ad dropped every staged handle): for the NAMED rows only, an already
# sealed kit is turned back into its template first: the old handle is discarded with the kit's own seal-request.py
# (failure is reported, not fatal: a node service restart has usually dropped it already), felboot-request.json is
# archived to $G/consumed-requests/, and its SHA256SUMS line is removed. The stripped manifest must hash to the
# recorded template digest, or the row fails. queue.done names are then ignored for those rows.
# Per row: the template's SHA256SUMS digest must equal the recorded one (unchanged template), the seal command must
# print exactly one <X>_QUEUE_LINE row, and that row must name the same kit dir with a manifest digest that matches
# the resealed SHA256SUMS, a clean `sha256sum -c`, and a sealed felboot-request.json carrying a 32-hex SeedHandle.
# Rows are appended with .new + mv; the name goes to postdeploy-seal.done only after the append.
set -uo pipefail
G=${SQ_DIR:-/home/matt/recovery/gpu14}
L=${SQ_LIST:-$G/postdeploy-seal.tsv}; D=${SQ_DONE:-$G/postdeploy-seal.done}; Q=${SQ_QUEUE:-$G/queue.tsv}
QDONE=${SQ_QUEUE_DONE:-$G/queue.done}
NODE_CHECK=${SQ_NODE_CHECK:-ssh -o BatchMode=yes -o ConnectTimeout=10 matt@pf-node-01.lan test -x /usr/local/libexec/pocketforge/redfish/pf-seed-flash.py}
DRY=0; [ "${1:-}" = --dry ] && { DRY=1; shift; }
RESEAL=0; [ "${1:-}" = --reseal ] && { RESEAL=1; shift; [ $# -gt 0 ] || { echo "SEALQ_REFUSED reason=reseal_needs_names"; exit 2; }; }
want_names=" $* "
touch "$D"
if ! $NODE_CHECK; then echo "SEALQ_REFUSED reason=node_not_seeded hint=run the seeded deploy first (pf-seed-flash.py missing on the node)"; exit 3; fi
fail=0
# 2026-10-12: the seed-preflight ssh read this loop's stdin and silently dropped every row after the first seal
# (feature-proof r5 never queued). The rows arrive on fd 3; nothing in the body can eat them.
while IFS=$'\t' read -r -u 3 name dir want cmd lane check; do
  case "$name" in ''|'#'*) continue ;; esac
  [ "$want_names" = "  " ] || case "$want_names" in *" $name "*) ;; *) continue ;; esac
  if [ "$RESEAL" = 0 ] && grep -qxF "$name" "$D"; then echo "SEALQ_SKIP name=$name reason=already_queued"; continue; fi
  # 2026-10-12: s14 was sealed in place while xfer (pft-71bcccbc) was mid-turn editing this template; 19 s later the runner
  # SKIPped it on a checksum mismatch and a seed handle was wasted. Refuse while any full run id in the lane column is not idle.
  # 2026-10-12: g2d's row carried "g2d 6db31ae6…" (no run id), so this guard checked nothing and sealed anyway. A lane
  # column must name at least one full pf-task run id.
  if ! grep -qE 'pft-[0-9a-f]{24}' <<<"$lane"; then echo "SEALQ_FAIL name=$name reason=lane_run_missing lane='${lane:0:60}' hint=postdeploy-seal.tsv col 5 must carry the lane's full pft-<24hex> run id"; fail=1; continue; fi
  for lr in $(grep -oE 'pft-[0-9a-f]{24}' <<<"$lane"); do
    lst=$(timeout 30 /home/matt/.pf-task-v2/bin/pf-task --home /home/matt/.pf-task-v2 --role coordinator run.status "{\"run_id\":\"$lr\"}" 2>/dev/null | grep -m1 '^{' | jq -r '.state // .status // "unknown"' 2>/dev/null)
    case "$lst" in refused) echo "SEALQ_FAIL name=$name reason=lane_run_unknown run=$lr hint=postdeploy-seal.tsv lane column names a run pf-task does not know (a generation id?); fix the column"; fail=1; continue 2 ;; esac
    case "$lst" in awaiting_release|released) ;; *) echo "SEALQ_FAIL name=$name reason=lane_not_idle run=$lr state=${lst:-unknown} hint=wait for the lane's HANDBACK, then reseal"; fail=1; continue 2 ;; esac
  done
  if [ "$RESEAL" = 1 ] && [ -e "$dir/felboot-request.json" ]; then
    strip=$(grep -v -e '  felboot-request.json$' -e '  dut-host-key.pub$' \
      "$dir/SHA256SUMS" | sha256sum | cut -c1-64)
    if [ "$strip" != "$want" ]; then echo "SEALQ_FAIL name=$name reason=reseal_template_mismatch want=${want:0:12} stripped=${strip:0:12} lane=$lane"; fail=1; continue; fi
    if [ "$DRY" = 1 ]; then echo "SEALQ_DRY name=$name reseal=would_restore template=${want:0:12}"; continue; fi
    oh=$(jq -r '.SeedHandle // ""' "$dir/felboot-request.json" 2>/dev/null)
    if [[ $oh =~ ^[0-9a-f]{32}$ ]]; then
      (cd "$dir" && timeout 90 python3 ./seal-request.py --kit "$dir" --discard "$oh") >"$G/.sealq-$name.discard" 2>&1; drc=$?
      echo "SEALQ_DISCARD name=$name handle=${oh:0:8} rc=$drc last=$(tail -n 1 "$G/.sealq-$name.discard" | cut -c1-160)"
    fi
    mkdir -p "$G/consumed-requests"
    arch="$G/consumed-requests/$name-$(date -u +%Y%m%dT%H%M%SZ).json"
    mv "$dir/felboot-request.json" "$arch" || { echo "SEALQ_FAIL name=$name reason=request_archive_failed"; fail=1; continue; }
    find "$dir/dut-host-key.pub" -maxdepth 0 -type f -delete 2>/dev/null
    grep -v -e '  felboot-request.json$' -e '  dut-host-key.pub$' \
      "$dir/SHA256SUMS" > "$dir/SHA256SUMS.new" && mv "$dir/SHA256SUMS.new" "$dir/SHA256SUMS"
    echo "SEALQ_RESTORED name=$name template=${want:0:12} archived=$arch"
  fi
  got=$(sha256sum < "$dir/SHA256SUMS" 2>/dev/null | cut -c1-64)
  if [ "$got" != "$want" ]; then echo "SEALQ_FAIL name=$name reason=template_changed want=${want:0:12} got=${got:0:12} lane=$lane"; fail=1; continue; fi
  if [ -e "$dir/felboot-request.json" ]; then echo "SEALQ_FAIL name=$name reason=stale_sealed_request hint=the lane must discard its handle and restore the template lane=$lane"; fail=1; continue; fi
  # 2026-10-12 etc2 s4 brought 35 KB home as 18 DutExec chunks over serial; the 8 KiB per-request cap never fired.
  # Owner rule: serial = control only. A kit carrying chunked-collection code needs a gpu-14 transport review,
  # keyed by its template manifest sha in transport-reviews.tsv (sha<TAB>date<TAB>verdict), before it is sealed.
  if grep -rlsE 'archive-chunk|collect-response-chunk|result_chunk_bytes|chunk_bytes=' "$dir" 2>/dev/null \
       | grep -vqE '/(fixtures|payload-input|real-output-fixtures|r49-artifacts)/|\.tar\.gz$|\.(txt|md)$' \
     && ! awk -F'\t' -v s="$want" '$1==s{f=1}END{exit !f}' "$G/transport-reviews.tsv" 2>/dev/null; then
    echo "SEALQ_FAIL name=$name reason=serial_chunk_transport_unreviewed template=${want:0:12} hint=read the kit's result path; if results come home by FAT/USB-NCM/SSH (serial = control only), add '$want<TAB>date<TAB>verdict' to transport-reviews.tsv"; fail=1; continue
  fi
  # 2026-10-12 (g2d r7): the template's queue.tsv still pointed at the r6 dir; row_path_mismatch fired only AFTER the
  # seal had staged a seed handle on the node. Check the template's own row path before sealing.
  tpath=$(awk -F'\t' '!/^#/ && NF>=3 {print $3; exit}' "$dir/queue.tsv" 2>/dev/null)
  if [ -n "$tpath" ] && [ "$(readlink -f "$tpath")" != "$(readlink -f "$dir")" ]; then
    echo "SEALQ_FAIL name=$name reason=template_row_path_mismatch row_path=$tpath hint=the lane points the kit's queue.tsv row at its own dir; no handle was staged"; fail=1; continue
  fi
  if [ "$DRY" = 1 ]; then echo "SEALQ_DRY name=$name template=${want:0:12} ok"; continue; fi
  out=$(timeout 300 bash -c "$cmd" 2>"$G/.sealq-$name.err"); rc=$?
  if [ "$rc" -ne 0 ]; then echo "SEALQ_FAIL name=$name reason=seal_rc_$rc last=$(tail -n 2 "$G/.sealq-$name.err" | tr '\n' ' ' | cut -c1-200)"; fail=1; continue; fi
  n=$(grep -cE '^[A-Z0-9_]+_QUEUE_LINE ' <<<"$out")
  [ "$n" = 1 ] || { echo "SEALQ_FAIL name=$name reason=queue_lines_$n"; fail=1; continue; }
  row=$(grep -m1 -E '^[A-Z0-9_]+_QUEUE_LINE ' <<<"$out" | cut -d' ' -f2-)
  # 2026-10-11: seal scripts print readlink -f paths; on the laptop /home/matt/recovery -> /home/matt/programming/pocketforge-os/recovery,
  # which does not exist on pf-node-01, so build7-proof-r1 would have refused image_path_not_node_recovery_path. Same file on the laptop.
  row=${row//\/home\/matt\/programming\/pocketforge-os\/recovery\//\/home\/matt\/recovery\/}
  IFS=$'\t' read -r rname rtype rpath rsha rmf _rest <<<"$row"
  transport_receipt=$(sed -n 's/.*--transport-receipt-dir \([^ ]*\).*/\1/p' <<<"$_rest")
  why=""
  [ "$rtype" = kit ] || why="row_type_$rtype"
  [ -z "$why" ] && [ "$(readlink -f "$rpath")" = "$(readlink -f "$dir")" ] || why=${why:-row_path_mismatch}
  [ -z "$why" ] && [ "$(sha256sum < "$rpath/$rmf" | cut -c1-64)" = "$rsha" ] || why=${why:-row_manifest_mismatch}
  [ -z "$why" ] && (cd "$rpath" && sha256sum -c --quiet "$rmf" >/dev/null 2>&1) || why=${why:-reseal_check_failed}
  [ -z "$why" ] && jq -e '(.SeedHandle // "") | test("^[0-9a-f]{32}$")' "$rpath/felboot-request.json" >/dev/null 2>&1 || why=${why:-sealed_seed_handle_missing}
  # 2026-10-11: a re-sealed kit re-emits its fixed row name (build7-proof-r1 after the smoke fix), which queue.done
  # already holds; the name is only a label, so take the first free -sN suffix instead of refusing.
  taken() { awk -F'\t' '{print $1}' "$Q" | sed 's/^#[^ ]* //' | grep -qxF "$1" || grep -qxF "$1" "$QDONE" 2>/dev/null; }
  if [ -z "$why" ] && taken "$rname"; then
    i=2; while taken "$rname-s$i"; do i=$((i+1)); done
    echo "SEALQ_RENAME name=$name row=$rname -> $rname-s$i (name already in queue or queue.done)"
    rname="$rname-s$i"; row="$rname"$'\t'"${row#*$'\t'}"
  fi
  if [ -z "$why" ] && [ -n "${check:-}" ] && [ "$check" != - ]; then
    # The check runs with ssh/scp/curl stubbed on PATH: a smoke that reaches the node would consume the live handle
    # (build7-proof-r1's refusal cases did), so any such call fails the check instead of touching the node.
    gd=$(mktemp -d "$G/.sealq-guard.XXXXXX"); for t in ssh scp curl; do printf '#!/bin/sh\necho "$0 $*" >> %s/calls\nexit 99\n' "$gd" > "$gd/$t"; chmod +x "$gd/$t"; done
    (cd "$rpath" && PATH="$gd:$PATH" SEALQ_TRANSPORT_RECEIPT="$transport_receipt" \
      timeout 600 bash -c "$check") >"$G/.sealq-$name.check" 2>&1; crc=$?
    ncalls=$( [ -f "$gd/calls" ] && wc -l < "$gd/calls" || echo 0 ); [ "$ncalls" = 0 ] || { echo "postseal_net_calls=$ncalls first=$(head -1 "$gd/calls" | cut -c1-120)" >> "$G/.sealq-$name.check"; crc=98; }
    find "$gd" -delete 2>/dev/null
    if [ "$crc" -ne 0 ]; then
      h=$(jq -r '.SeedHandle // ""' "$rpath/felboot-request.json" 2>/dev/null)
      python3 "$rpath/seal-request.py" --kit "$rpath" --discard "$h" >>"$G/.sealq-$name.check" 2>&1 && why=postseal_check_failed_handle_discarded || why=postseal_check_failed_DISCARD_FAILED_handle_$h
      if [ -n "$transport_receipt" ] && [ -x "$rpath/pf-kit-transport.py" ]; then
        "$rpath/pf-kit-transport.py" teardown-key --receipt-dir "$transport_receipt" \
          >>"$G/.sealq-$name.check" 2>&1 || why=${why}_KEY_TEARDOWN_FAILED
      fi
      echo "SEALQ_CHECK name=$name last=$(tail -n 2 "$G/.sealq-$name.check" | tr '\n' ' ' | cut -c1-200)"
    fi
  elif [ -z "$why" ]; then echo "SEALQ_WARN name=$name reason=no_postseal_check hint=add the kit's smoke as column 6"; fi
  # 2026-10-12 build8-feature-proof-r2: its smoke ran under `env PATH=/usr/bin:/bin`, which bypassed the ssh/scp/curl stubs
  # above; its teardown discarded the REAL handle while the check printed PASS, and FelBoot later failed
  # seed_handle_unknown. The PATH guard can be bypassed, so prove the handle still exists on the node after the check
  # (read-only preflight) for every kit.
  if [ -z "$why" ]; then
    h=$(jq -r '.SeedHandle // ""' "$rpath/felboot-request.json" 2>/dev/null)
    # A kit with a FAT payload must bind it: a bare preflight answers kit_payload_unbound (g2d-build8-r5 false alarm).
    kp=$(jq -c '.KitPayload // empty' "$rpath/felboot-request.json" 2>/dev/null); kparg=""; [ -n "$kp" ] && kparg=" --kit-payload-json '$kp'"
    if ! ssh -n -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 matt@pf-node-01.lan \
         "sudo -n /usr/local/libexec/pocketforge/redfish/pf-seed-flash.py preflight --handle '$h'$kparg" 2>>"$G/.sealq-$name.check" \
         | grep -q '^PF_SEED_PREFLIGHT '; then
      why=postseal_seed_handle_absent
      echo "SEALQ_CHECK name=$name reason=seed handle ${h:0:8} not staged on pf-node-01 after the postseal check (consumed or never registered)"
    fi
  fi
  if [ -n "$why" ]; then echo "SEALQ_FAIL name=$name reason=$why row_name=$rname hint=the handle stays staged; discard it with the kit's seal-request.py --discard if abandoned"; fail=1; continue; fi
  { cat "$Q"; printf '%s\n' "$row"; } > "$Q.new" && mv "$Q.new" "$Q" && echo "$name" >> "$D"
  echo "SEALQ_QUEUED name=$name row=$rname manifest=${rsha:0:12} lane=$lane"
done 3< "$L"
[ "$fail" = 0 ] && echo "SEALQ_DONE restart_runner_if_exited=yes" || { echo "SEALQ_PARTIAL see SEALQ_FAIL lines"; exit 4; }
