#!/usr/bin/env bash
set -euo pipefail

K=$(cd -- "$(dirname -- "$0")" && pwd)
die() { printf 'BUILD9_RENEWAL_TEST state=FAIL reason=%s\n' "$1"; exit 1; }

grep -q '/usr/bin/nmcli -t -f GENERAL.STATE device show' "$K/run-network-step" || die host_association_not_nmcli
! grep -q '/usr/sbin/iw' "$K/run-network-step" || die host_iw_dependency_present
! grep -Eq 'route get .* from ' "$K/run-network-step" || die route_forces_source
grep -q 'Argv:\[\$kit+"/run-network-step",\$host,"gamer"' "$K/RUNBOOK.md.in" || die network_user_not_gamer
grep -q 'Argv:\[\$kit+"/run-g2d-step",\$host,"gamer"' "$K/RUNBOOK.md.in" || die g2d_user_not_gamer
! grep -Eq 'Argv:.*"debug"' "$K/RUNBOOK.md.in" || die debug_ssh_user_present
grep -Fq "'{print h\" \"\$1\" \"\$2}'" "$K/RUNBOOK.md.in" || die known_hosts_not_three_fields

expected_transport=230901fd1b65d750dc4614852c6442fe0f004f05c26cf310677b3f11ceeb84f0
[ "$(sha256sum "$K/assets/pf-kit-transport.py" | awk '{print $1}')" = "$expected_transport" ] || die transport_sha_mismatch

tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/build9-renewal-test.XXXXXX")
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT
tar -xzf "$K/assets/g2d-payload.tar.gz" -C "$tmp"
helper=$tmp/run/pf-g2d/pf-v4l2-rotate
strings "$helper" | grep -Eq '(^|/)xz$|--threads=1' && die helper_execs_xz
grep -q 'latency_sample_.*_error_errno' "$K/assets/pf-v4l2-rotate.c" || die latency_failure_not_indexed
grep -q 'rotate-results.tar' "$K/assets/pf-v4l2-rotate.c" || die plain_tar_missing

grep -q 'BOUNDED_G2D_EVIDENCE_BEGIN' "$K/g2d-dut-run.sh" || die bounded_failure_evidence_missing
grep -q 'helper_rc=' "$K/run-g2d-step" || die helper_failure_not_captured
grep -q 'evidence=pulled' "$K/run-g2d-step" || die failure_pull_not_reported

printf 'BUILD9_RENEWAL_TEST state=PASS transport=%s archive=plain-tar failure_evidence=bounded latency_detail=indexed\n' "$expected_transport"
