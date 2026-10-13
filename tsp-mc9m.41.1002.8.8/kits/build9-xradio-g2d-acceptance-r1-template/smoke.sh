#!/bin/sh
set -eu
K=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
(cd "$K" && /usr/bin/sha256sum -c --strict --quiet SHA256SUMS)
raw=$(/usr/bin/sed -n 's/^build9_raw_sha256=//p' "$K/IDENTITY")
host_interface=$(/usr/bin/sed -n 's/^host_wifi_interface=//p' "$K/IDENTITY")
dut_interface=$(/usr/bin/sed -n 's/^dut_interface=//p' "$K/IDENTITY")
printf '%s\n' "$raw" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'
[ "$(/usr/bin/stat -c %s "$K/network-smoke.bin")" = 1048576 ]
[ "$(/usr/bin/sha256sum "$K/network-smoke.bin" | /usr/bin/awk '{print $1}')" = 30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58 ]
[ "$(/usr/bin/sha256sum "$K/pf-kit-payload.tar.gz" | /usr/bin/awk '{print $1}')" = 2c2c5f1f67e7ed2943a1df6afb7dbf3f37a265e5b8a85b1dc821c9a478fbd9f5 ]
[ -n "$host_interface" ] && [ -n "$dut_interface" ] && [ "$host_interface" != "$dut_interface" ]
if /usr/bin/grep -F "$host_interface" "$K/bootstrap-dut.sh" "$K/network-dut.sh" >/dev/null; then
  printf '%s\n' 'BUILD9_ACCEPTANCE_SMOKE state=FAIL reason=host_interface_in_dut_script'
  exit 1
fi
if /usr/bin/grep -En '(^|[[:space:];])insmod([[:space:];]|$)' \
    "$K/bootstrap-dut.sh" "$K/network-dut.sh" "$K/g2d-dut-run.sh" \
    "$K/run-network-step" "$K/run-g2d-step" 2>/dev/null; then
  printf '%s\n' 'BUILD9_ACCEPTANCE_SMOKE state=FAIL reason=out_of_tree_xradio_path'
  exit 1
fi
/usr/bin/grep -F 'operation=push-push-exec-pull bytes=1048576 sha256=30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58' "$K/run-network-step" >/dev/null
/usr/bin/grep -F 'G2D_RESULT state=pass format=XRGB8888 transforms=7 checksum_matches=7 node=/dev/video' "$K/g2d-dut-run.sh" >/dev/null
/usr/bin/grep -F 'G2D_IOMMU_FAULT_DELTA master=5 before=0 after=0 delta=0' "$K/g2d-dut-run.sh" >/dev/null
/usr/bin/grep -F 'kit-resume-boot-open' "$K/RUNBOOK.md" >/dev/null
/usr/bin/grep -F 'kit-resume-step' "$K/RUNBOOK.md" >/dev/null
/usr/bin/grep -F 'kit-resume-close' "$K/RUNBOOK.md" >/dev/null
printf 'BUILD9_ACCEPTANCE_SMOKE state=PASS sealed_raw=%s network_only=1 device_actions=0 seed_stage=0 queue_writes=0\n' "$raw"
