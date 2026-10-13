#!/bin/sh
set -eu

K=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
fixture=$K/assets/test-fixtures
D=$(mktemp -d "${RUNNER_TEMP:-/tmp}/build9-receipt-side-files.XXXXXX")
cleanup() { find "$D" -mindepth 1 -delete; rmdir "$D"; }
trap cleanup EXIT HUP INT TERM
die() { printf 'BUILD9_RECEIPT_TEST state=FAIL reason=%s\n' "$1"; exit 1; }

[ -x "$K/receipt-tools.sh" ] || die receipt_reader_missing
cp "$fixture/revision-004-step-000.stdout" "$D/revision-004-step-000.stdout"
jq --arg path "$D/revision-004-step-000.stdout" \
  '.StepResults[0].Stdout.Path=$path' "$fixture/revision-004.json" >"$D/pass.json"
"$K/receipt-tools.sh" stdout "$D/pass.json" 0 "$D/verified.stdout" "$D" >/dev/null
cmp "$fixture/revision-004-step-000.stdout" "$D/verified.stdout"
grep -F 'BUILD9_BOOTSTRAP state=PASS dut_interface=wlan0 address=192.168.86.14' "$D/verified.stdout" >/dev/null

jq '.StepResults[0].Stdout.SHA256=("0"*64)' "$D/pass.json" >"$D/bad-sha.json"
if "$K/receipt-tools.sh" stdout "$D/bad-sha.json" 0 "$D/bad-sha.stdout" "$D" >"$D/bad-sha.log" 2>&1; then
  die sha_mismatch_accepted
fi
grep -F 'state=INVALID reason=sha256_mismatch' "$D/bad-sha.log" >/dev/null
jq '.StepResults[0].Stdout="inline output is forbidden"' "$D/pass.json" >"$D/inline.json"
if "$K/receipt-tools.sh" stdout "$D/inline.json" 0 "$D/inline.stdout" "$D" >"$D/inline.log" 2>&1; then
  die inline_stdout_accepted
fi
grep -F 'state=INVALID reason=descriptor_invalid' "$D/inline.log" >/dev/null
jq '.StepResults[0].Stdout.Bytes+=1' "$D/pass.json" >"$D/bad-bytes.json"
if "$K/receipt-tools.sh" stdout "$D/bad-bytes.json" 0 "$D/bad-bytes.stdout" "$D" >"$D/bad-bytes.log" 2>&1; then
  die byte_mismatch_accepted
fi
grep -F 'state=INVALID reason=byte_count_mismatch' "$D/bad-bytes.log" >/dev/null

[ "$("$K/receipt-tools.sh" close-reason "$D/pass.json" "$D/pass.json")" = success ] || die pass_reason_not_success
jq '.Outcome="fail" | .StepResults[0].RC=66' "$D/pass.json" >"$D/fail.json"
[ "$("$K/receipt-tools.sh" close-reason "$D/pass.json" "$D/fail.json")" = failure ] || die failed_step_not_failure
[ "$("$K/receipt-tools.sh" close-reason "$D/pass.json" "$D/missing.json")" = failure ] || die missing_step_not_failure

printf 'BUILD9_RECEIPT_TEST state=PASS fixture=revision-004 sha256_verified=pass inline_refused=pass byte_count_verified=pass close_reason=derived\n'
