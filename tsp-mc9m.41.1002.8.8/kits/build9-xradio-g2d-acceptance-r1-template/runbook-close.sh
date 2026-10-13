#!/usr/bin/env bash
set -u -o pipefail

if [[ $# -ne 8 ]]; then
    printf 'BUILD9_CLOSE state=FAIL reason=arguments\n' >&2
    exit 2
fi
mode=$1 kit=$2 run=$3 anchor=$4 live_repo=$5 SQ_DIR=$6 SQ_QUEUE=$7 generation=$8
case $mode in auto|failure) ;; *) printf 'BUILD9_CLOSE state=FAIL reason=mode\n' >&2; exit 2 ;; esac

teardown_rc=0
python3 "$kit/pf-kit-transport.py" teardown-key \
    --receipt-dir "$run/seed-transport" || teardown_rc=$?
if [[ $teardown_rc -ne 0 ]]; then
    printf 'BUILD9_CLOSE state=WARN reason=teardown_key_failed rc=%s action=continue_to_close\n' \
        "$teardown_rc" >&2
fi

close_reason=failure
if [[ $mode == auto ]]; then
    derived=$(
        "$kit/receipt-tools.sh" close-reason \
            "$run/series/revision-000.json" \
            "$run/series/revision-001.json" \
            "$run/series/revision-002.json" 2>/dev/null
    ) || derived=failure
    case $derived in success|failure) close_reason=$derived ;; esac
fi

mkdir -p "$run/requests" "$run/row-receipts"
jq -n --arg anchor "$anchor" --arg repo "$live_repo" --arg reason "$close_reason" \
    --arg receipt "$run/series/terminal.json" \
    '{Anchor:$anchor,Live:{Repo:$repo},Receipt:$receipt,Reason:$reason}' \
    >"$run/requests/close.json"
env SQ_DIR="$SQ_DIR" SQ_QUEUE="$SQ_QUEUE" "$SQ_DIR/seal-resume-row.sh" \
    "build9-accept-close-$generation" kit-resume-close "$run/requests/close.json" \
    "$run/row-receipts/close" -
printf 'BUILD9_CLOSE state=QUEUED reason=%s teardown_key_rc=%s\n' \
    "$close_reason" "$teardown_rc"
