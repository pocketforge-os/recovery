#!/bin/sh
set -eu

K=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
fixture=$K/assets/test-fixtures
die() { printf 'BUILD9_G2D_PREDICATE_TEST state=FAIL reason=%s\n' "$1"; exit 1; }

[ -x "$K/verify-g2d-step.sh" ] || die predicate_helper_missing
"$K/verify-g2d-step.sh" "$fixture/g2d-pass.stdout" "$fixture/g2d-pass-result.txt" >/dev/null
if "$K/verify-g2d-step.sh" "$fixture/g2d-fail.stdout" "$fixture/g2d-pass-result.txt" >/dev/null 2>&1; then
    die failed_transport_accepted
fi
if "$K/verify-g2d-step.sh" "$fixture/g2d-pass.stdout" "$fixture/g2d-fail.stdout" >/dev/null 2>&1; then
    die missing_device_proof_accepted
fi
printf 'BUILD9_G2D_PREDICATE_TEST state=PASS real_success=accepted morning_failure=refused device_proof=required\n'
