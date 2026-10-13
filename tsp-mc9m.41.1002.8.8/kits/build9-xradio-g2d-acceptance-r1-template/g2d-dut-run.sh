#!/bin/sh
set -eu

payload=${1:?payload}; out=/run/pf-build9-acceptance/g2d; root=/run/pf-g2d
/usr/bin/install -d -m 0700 "$out/diagnostics"
bounded_result() {
    state=$1 reason=$2 receipt=$out/result/rotate/rotate-receipt.tsv
    {
        printf 'BUILD9_G2D state=%s reason=%s\n' "$state" "$reason"
        printf 'BOUNDED_G2D_EVIDENCE_BEGIN max_bytes_per_file=16384\n'
        for evidence in "$receipt" "$out/result/helper.stderr" "$out/g2d-result.stderr"; do
            [ -f "$evidence" ] || continue
            printf 'EVIDENCE_FILE path=%s\n' "$evidence"
            /usr/bin/head -c 16384 "$evidence"
            printf '\nEVIDENCE_FILE_END path=%s\n' "$evidence"
        done
        printf 'BOUNDED_G2D_EVIDENCE_END\n'
    } >"$out/acceptance-result.txt"
    if [ -f "$receipt" ]; then
        /usr/bin/cp "$receipt" "$out/rotate-receipt.tsv"
    else
        printf 'result\tunavailable\nreason\t%s\n' "$reason" >"$out/rotate-receipt.tsv"
    fi
    if [ -f "$out/result/v4l2-compliance.txt" ]; then
        /usr/bin/cp "$out/result/v4l2-compliance.txt" "$out/v4l2-compliance.txt"
    else
        printf 'unavailable: %s\n' "$reason" >"$out/v4l2-compliance.txt"
    fi
    /usr/bin/cat "$out/acceptance-result.txt"
}
invalid() { bounded_result INVALID "$1"; exit 65; }
fail() { bounded_result FAIL "$1"; exit 66; }
[ "$(/usr/bin/id -u)" = 0 ] || invalid root_required
for binary in /bin/bash /bin/sh /usr/bin/awk /usr/bin/basename /usr/bin/cat \
    /usr/bin/cp /usr/bin/dmesg /usr/bin/env /usr/bin/find /usr/bin/grep \
    /usr/bin/head /usr/bin/id /usr/bin/install /usr/bin/mkdir /usr/bin/mktemp \
    /usr/bin/python3 /usr/bin/rmdir /usr/bin/sed /usr/bin/sha256sum \
    /usr/bin/tar /usr/bin/tee /usr/bin/timeout /usr/bin/v4l2-ctl \
    /usr/bin/v4l2-compliance; do
    [ -x "$binary" ] || invalid "binary_missing_$(/usr/bin/basename "$binary")"
done
[ -f "$payload" ] || invalid payload_missing
[ "$(/usr/bin/sha256sum "$payload" | /usr/bin/awk '{print $1}')" = d93f822eadecc90cebaf4ed6acc9c6422e154ddd292b419284a0ee380c28ae5a ] || invalid payload_sha_mismatch
/usr/bin/tar --no-overwrite-dir -xzf "$payload" -C /
/usr/bin/python3 "$root/verify-image-dtb.py" >"$out/image-dtb.txt" || fail image_dtb_gate
/usr/bin/cat /proc/interrupts >"$out/diagnostics/irq-before.raw"
/usr/bin/dmesg >"$out/diagnostics/dmesg-before.raw"
"$root/pf-g2d-regdump" before >"$out/diagnostics/regs-before.txt" || fail regdump_before
helper_rc=0
PF_G2D_OBSERVER=disabled /usr/bin/timeout -s TERM -k 5 240 "$root/g2d-dut" run "$out/result" >"$out/g2d-result.txt" 2>"$out/g2d-result.stderr" || helper_rc=$?
[ "$helper_rc" = 0 ] || fail "helper_or_score_rc_$helper_rc"
/usr/bin/cat /proc/interrupts >"$out/diagnostics/irq-after.raw"
/usr/bin/dmesg >"$out/diagnostics/dmesg-after.raw"
"$root/pf-g2d-regdump" after >"$out/diagnostics/regs-after.txt" || fail regdump_after
/usr/bin/python3 "$root/g2d-diagnose.py" irq-delta "$out/diagnostics/irq-before.raw" "$out/diagnostics/irq-after.raw" >"$out/irq-delta.txt"
/usr/bin/python3 "$root/g2d-diagnose.py" iommu-delta "$out/diagnostics/dmesg-before.raw" "$out/diagnostics/dmesg-after.raw" >"$out/iommu-delta.txt"
result=$out/g2d-result.txt
/usr/bin/grep -Eq '^G2D_ROTATION format=XRGB8888 angle=0 hflip=0 vflip=0 result=pass mismatches=0 output_sha256=([0-9a-f]{64}) reference_sha256=\1 checksum_match=1$' "$result" || fail identity_reference_failed
/usr/bin/grep -Eq '^G2D_ROTATION format=XRGB8888 angle=90 hflip=0 vflip=0 result=pass mismatches=0 output_sha256=([0-9a-f]{64}) reference_sha256=\1 checksum_match=1$' "$result" || fail rotate90_reference_failed
/usr/bin/grep -Eq '^G2D_PERF samples=[1-9][0-9]* median_us=[0-9]+ p95_us=[0-9]+ max_us=[0-9]+ errors=0 throughput_mib_s=[0-9.]+$' "$result" || fail latency_errors_nonzero
/usr/bin/grep -Eq '^G2D_RESULT state=pass format=XRGB8888 transforms=7 checksum_matches=7 node=/dev/video[0-9]+$' "$result" || fail final_result_failed
/usr/bin/grep -Eq '^G2D_IRQ_DELTA before=[0-9]+ after=[0-9]+ delta=[1-9][0-9]*$' "$out/irq-delta.txt" || fail irq_delta_not_positive
/usr/bin/grep -Fx 'G2D_IOMMU_FAULT_DELTA master=5 before=0 after=0 delta=0' "$out/iommu-delta.txt" >/dev/null || fail iommu_fault_delta_nonzero
{
  /usr/bin/cat "$out/image-dtb.txt"
  /usr/bin/cat "$result"
  /usr/bin/cat "$out/irq-delta.txt"
  /usr/bin/cat "$out/iommu-delta.txt"
  printf 'DEVICE_PROOF verdict=PASS image_dtb=owned identity=pass rotate90=pass cpu_reference=match latency_errors=0 irq_delta=positive iommu_fault_delta=0\n'
} >"$out/acceptance-result.txt"
/usr/bin/cp "$out/result/rotate/rotate-receipt.tsv" "$out/rotate-receipt.tsv"
/usr/bin/cp "$out/result/v4l2-compliance.txt" "$out/v4l2-compliance.txt"
/usr/bin/cat "$out/acceptance-result.txt"
