#!/usr/bin/env bash
# gpu-14 2026-10-10 (bead tsp-mc9m.41.995.65): send a lane message with the CI_WAIT ending appended,
# so every lane learns it without gpu-14 remembering to write it.
# 2026-10-15: send.sh moved out of a session scratchpad (it would vanish with the session) to /home/matt/recovery/gpu14/send.sh.
# usage: lane-msg.sh <run_id> <message-file> <idempotency-key> <TOKEN>
set -euo pipefail
run=$1 file=$2 key=$3 TOK=$4
[[ $TOK =~ ^[A-Z0-9_]+$ ]] || { echo "LANE_MSG refused reason=bad_token"; exit 2; }
# The driver re-sends <lane>-continue.txt on every CONTINUE; a message written there goes stale and was
# re-sent for hours (found 2026-10-10: 14 lanes' continue files held old specific orders).
case "$file" in *-continue.txt) echo "LANE_MSG refused reason=continue_file_is_not_a_message"; exit 2 ;; esac
# 2026-10-12 (lin): `tmpl.sh lin-ci.txt … ; lane-msg.sh … lin-ci.txt` — tmpl refused (file existed) and the `;` sent
# a 7 h old order ("do no new work, CI_WAIT gamescope#12"). Refuse a stale file or one already sent, unless overridden.
[ -s "$file" ] || { echo "LANE_MSG refused reason=empty_or_missing_file file=$file"; exit 2; }
age=$(( $(date +%s) - $(stat -c %Y "$file") ))
if [ "$age" -gt 1800 ] && [ "${LANE_MSG_ALLOW_OLD:-0}" != 1 ]; then
  echo "LANE_MSG refused reason=stale_message_file age_s=$age file=$file hint=write a fresh file (tmpl.sh) or LANE_MSG_ALLOW_OLD=1 if resending on purpose"; exit 2
fi
ledger=/home/matt/recovery/gpu14/.lane-msg-sent.tsv
fsha=$(sha256sum < "$file" | cut -c1-64)
if grep -q "	$fsha$" "$ledger" 2>/dev/null && [ "${LANE_MSG_ALLOW_OLD:-0}" != 1 ]; then
  echo "LANE_MSG refused reason=already_sent file=$file prior=$(grep -m1 "	$fsha$" "$ledger" | cut -f1-3 | tr '\t' ' ')"; exit 2
fi
grep -q "state=CI_WAIT" "$file" || cat >>"$file" <<EOF

Standard ending after a push: \`$TOK state=CI_WAIT pr=<owner/repo>#<n> head=<40-hex sha>\`. The driver waits for that exact head's CI and re-prompts you with GREEN (do the review and the merge dry-run) or RED (the failing lines). Do not wait on CI inside your turn. Start any command expected to run over 2 min (builds, long tests) detached with output to a file, then end the turn (CI_WAIT, or BUILD_RUNNING run=<id>, or CONTINUE and read the file next turn); never poll or wait on it in-turn: each poll re-sends your whole context. Device windows: hand a sealed kit to the window queue with \`$TOK state=HANDBACK reason=BOOT_READY pkg=<package-dir> gen=<32-hex> steps=<n> label=<label>\` (the kit's sealed PREFLIGHT names ENTRYPOINT=<file>, or STEP_DRIVEN=<n> plus exactly n STEP=<request.json> lines, n = steps), and end a window with \`$TOK state=WINDOW_DONE gen=<32-hex> plan=complete|incomplete\`; the driver queues, closes and continues you without a coordinator turn. Merge-ready: \`$TOK state=HANDBACK reason=MERGE_READY pr=<owner/repo>#<n> head=<40-hex> bead=<id> acceptance=met|device_proof bead_complete=yes|no\` (no = more PRs or device proof remain for this bead; the driver merges and you continue it). Use HANDBACK only for merge-ready, decisions or blockers.
EOF
/home/matt/recovery/gpu14/send.sh "$run" "$file" "$key"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$run" "$file" "$fsha" >> "$ledger"
