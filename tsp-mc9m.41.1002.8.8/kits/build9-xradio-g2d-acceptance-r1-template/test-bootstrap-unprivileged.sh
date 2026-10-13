#!/bin/sh
set -eu
K=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
IMAGE=${1:?published-build9-image.img}
dut_interface=wlan0
host_wifi_interface=wlp4s0
D=$(mktemp -d "${RUNNER_TEMP:-/tmp}/build9-bootstrap-unprivileged.XXXXXX")
cleanup() { find "$D" -mindepth 1 -delete; rmdir "$D"; }
trap cleanup EXIT HUP INT TERM
chmod 0755 "$D"

# The DUT name is image-owned, not inherited from the laptop. Accept either
# the instantiated service or the per-interface supplicant configuration.
start=$(/sbin/sfdisk -J "$IMAGE" 2>/dev/null | /usr/bin/python3 -c '
import json,sys
p=json.load(sys.stdin)["partitiontable"]; ss=p.get("sectorsize",512)
parts=p["partitions"]
named=[x for x in parts if x.get("name")=="userdata"]
linux=[x for x in parts if x.get("type","").upper()=="0FC63DAF-8483-4772-8E79-3D69D8477DE4"]
pick=(named or sorted(linux,key=lambda x:x["size"])[-1:])
print(pick[0]["start"]*ss if pick else "")')
[ -n "$start" ] || { printf '%s\n' 'BUILD9_BOOTSTRAP_TEST state=FAIL reason=rootfs_partition_missing'; exit 1; }
rootfs="$IMAGE?offset=$start"
config=/etc/wpa_supplicant/wpa_supplicant-$dut_interface.conf
unit=/etc/systemd/system/multi-user.target.wants/wpa_supplicant@$dut_interface.service
template_unit=/lib/systemd/system/wpa_supplicant@.service
network_file=/etc/systemd/network/20-$dut_interface.network
specific=0
if /usr/sbin/debugfs -R "stat $config" "$rootfs" 2>&1 | /usr/bin/grep -q '^Inode:' ||
   /usr/sbin/debugfs -R "stat $unit" "$rootfs" 2>&1 | /usr/bin/grep -q '^Inode:'; then
    specific=1
fi
if [ "$specific" -ne 1 ] &&
   { ! /usr/sbin/debugfs -R "stat $template_unit" "$rootfs" 2>&1 | /usr/bin/grep -q '^Inode:' ||
     ! /usr/sbin/debugfs -R "cat $network_file" "$rootfs" 2>/dev/null | /usr/bin/grep -Fx "Name=$dut_interface" >/dev/null; }; then
    printf 'BUILD9_BOOTSTRAP_TEST state=FAIL reason=dut_interface_not_in_image interface=%s\n' "$dut_interface"
    exit 1
fi
if /usr/bin/grep -F "$host_wifi_interface" "$K/bootstrap-dut.sh" "$K/network-dut.sh" >/dev/null; then
    printf 'BUILD9_BOOTSTRAP_TEST state=RED reason=host_interface_in_dut_script host=%s dut=%s\n' \
        "$host_wifi_interface" "$dut_interface"
    exit 1
fi

# DutExec is uid 1001. Reproduce the original defect against a root-owned 0755
# runtime directory without creating anything there.
probe=/run/build9-bootstrap-uid1001-$$
# shellcheck disable=SC2024 # Capture sudo/setpriv diagnostics as the test owner.
if sudo -n /usr/bin/setpriv --reuid=1001 --regid=1001 --clear-groups \
    /bin/sh -c ': >"$1"' sh "$probe" \
    >"$D/run-write.out" 2>"$D/run-write.err"; then
    printf '%s\n' 'BUILD9_BOOTSTRAP_TEST state=FAIL reason=run_writable_by_uid1001'
    exit 1
fi
grep -Eqi 'permission denied|operation not permitted' "$D/run-write.err"

# wpa_supplicant's control socket is root-owned. Model the uid-1001 refusal
# that revision 001 exposed, before asserting that production uses sudo.
mkdir "$D/wpa_supplicant"
printf '%s\n' control >"$D/wpa_supplicant/$dut_interface"
chmod 0600 "$D/wpa_supplicant/$dut_interface"
wpa_rc=0
# shellcheck disable=SC2024 # Capture sudo/setpriv diagnostics as the test owner.
sudo -n /usr/bin/setpriv --reuid=1001 --regid=1001 --clear-groups \
    /usr/bin/cat "$D/wpa_supplicant/$dut_interface" \
    >"$D/wpa.out" 2>"$D/wpa.err" || wpa_rc=$?
if [ "$wpa_rc" -eq 0 ]; then
    printf '%s\n' 'BUILD9_BOOTSTRAP_TEST state=FAIL reason=wpa_control_readable_by_uid1001'
    exit 1
fi
grep -Eqi 'permission denied|operation not permitted' "$D/wpa.err"

# The production bootstrap must keep cloud-init output in the shell process,
# type a command/permission refusal as INVALID, and contain no fixed /run file.
if grep -F '/run/build9-cloud-init.' "$K/bootstrap-dut.sh"; then
    printf '%s\n' 'BUILD9_BOOTSTRAP_TEST state=RED reason=fixed_run_path'
    exit 1
fi
grep -F "cloud_output=\$(/usr/bin/cloud-init status --wait 2>&1)" "$K/bootstrap-dut.sh" >/dev/null
# shellcheck disable=SC2016 # These are literal production-code assertions.
if ! grep -F 'status=$(/usr/bin/sudo -n /usr/sbin/wpa_cli -i "$dut_interface" status 2>&1)' "$K/bootstrap-dut.sh" >/dev/null; then
    printf '%s\n' 'BUILD9_BOOTSTRAP_TEST state=RED reason=wpa_cli_not_sudo'
    exit 1
fi
# shellcheck disable=SC2016 # These are literal production-code assertions.
grep -F 'sudo_output=$(/usr/bin/sudo -n true 2>&1)' "$K/bootstrap-dut.sh" >/dev/null
# shellcheck disable=SC2016 # These are literal production-code assertions.
grep -F 'invalid_refusal wpa_cli "$status"' "$K/bootstrap-dut.sh" >/dev/null
grep -F 'reason=instrument_refused instrument=%s detail="%s"' "$K/bootstrap-dut.sh" >/dev/null
if grep -F 'invalid instrument_refused' "$K/bootstrap-dut.sh" >/dev/null; then
    printf '%s\n' 'BUILD9_BOOTSTRAP_TEST state=FAIL reason=untyped_instrument_refusal'
    exit 1
fi
# shellcheck disable=SC2016 # These are literal production-code assertions.
grep -F 'ssh_output=$(/usr/bin/sudo -n /usr/bin/systemctl is-active ssh 2>&1)' "$K/bootstrap-dut.sh" >/dev/null
grep -F 'printf '\''BUILD9_WPA_CLI instrument=wpa_cli interface=%s rc=%s\n'\''' "$K/bootstrap-dut.sh" >/dev/null

# Positive control: uid 1001 can capture and inspect output without filesystem
# scratch space.
sudo -n /usr/bin/setpriv --reuid=1001 --regid=1001 --clear-groups /bin/sh -c '
  cloud_output=$(printf "status: done\n")
  printf "%s\n" "$cloud_output" | /usr/bin/grep -F "status: done" >/dev/null
'
printf 'BUILD9_BOOTSTRAP_TEST state=PASS uid=1001 dut_interface=%s image_assertion=pass run_write=refused wpa_refusal=pass shell_capture=pass refusal_class=INVALID\n' "$dut_interface"
