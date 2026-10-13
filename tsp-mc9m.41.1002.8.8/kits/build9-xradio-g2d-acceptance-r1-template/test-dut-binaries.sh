#!/bin/sh
set -eu
K=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
IMAGE=${1:?published-image.img}
CHECK=/home/matt/recovery/gpu14/dut-binary-check.sh
D=$(mktemp -d "${RUNNER_TEMP:-/tmp}/build9-acceptance-dut-binaries.XXXXXX")
cleanup() { find "$D" -mindepth 1 -delete; rmdir "$D"; }
trap cleanup EXIT HUP INT TERM

for file in bootstrap-dut.sh network-dut.sh g2d-dut-run.sh; do
    sed -n '1,$p' "$K/$file"
done >"$D/all-dut-commands.txt"
# Payload helpers run these image-owned programs through PATH or exec. List
# their absolute image paths so the checker covers commands not spelled out in
# the three wrapper scripts.
printf '%s\n' \
    /bin/sh /bin/busybox \
    /usr/bin/awk /usr/bin/basename /usr/bin/cat /usr/bin/cloud-init \
    /usr/bin/dmesg /usr/bin/dirname /usr/bin/env /usr/bin/grep /usr/bin/id \
    /usr/bin/install /usr/bin/python3 /usr/bin/sed /usr/bin/sha256sum \
    /usr/bin/stat /usr/bin/sudo /usr/bin/systemctl /usr/bin/tar /usr/bin/test \
    /usr/bin/timeout /usr/bin/v4l2-compliance /usr/bin/v4l2-ctl \
    /usr/sbin/ip /usr/sbin/modinfo /usr/sbin/wpa_cli \
    >>"$D/all-dut-commands.txt"
"$CHECK" "$IMAGE" "$D/all-dut-commands.txt"
