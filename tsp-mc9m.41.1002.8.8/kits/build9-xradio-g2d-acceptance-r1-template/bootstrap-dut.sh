#!/bin/sh
set -eu
dut_interface=wlan0

stop() { printf 'BUILD9_STOP state=STOP stage=bootstrap reason=%s\n' "$1"; exit 64; }
is_refusal() {
    printf '%s\n' "$1" | /usr/bin/grep -Eqi \
        'permission denied|operation not permitted|access denied|authentication is required|command not found'
}
invalid_refusal() {
    instrument=$1
    output=$2
    detail=$(printf '%s\n' "$output" | /usr/bin/awk '
        {
            if (first == "") first=$0
            if (tolower($0) ~ /permission denied|operation not permitted|access denied|authentication is required|command not found/) {
                line=$0
                found=1
                exit
            }
        }
        END {
            if (!found) line=first
            if (line == "") line="nonzero exit with no diagnostic"
            gsub(/[\\"]/, "_", line)
            print substr(line,1,160)
        }')
    printf 'BUILD9_NETWORK state=INVALID stage=bootstrap reason=instrument_refused instrument=%s detail="%s"\n' \
        "$instrument" "$detail"
    exit 65
}

status_rc=0
cloud_output=$(/usr/bin/cloud-init status --wait 2>&1) || status_rc=$?
printf '%s\n' "$cloud_output"
if is_refusal "$cloud_output"; then invalid_refusal cloud-init "$cloud_output"; fi
case "$status_rc" in 0|2) ;; *) stop cloud_init_failed ;; esac
printf '%s\n' "$cloud_output" | /usr/bin/grep -F 'status: done' >/dev/null || stop cloud_init_not_done
cmdline_rc=0
cmdline=$(/usr/bin/cat /proc/cmdline 2>&1) || cmdline_rc=$?
if [ "$cmdline_rc" -ne 0 ]; then
    if is_refusal "$cmdline"; then invalid_refusal cat_proc_cmdline "$cmdline"; fi
    stop cmdline_unreadable
fi
case "$cmdline" in *modprobe.blacklist=xradio*) stop extra_boot_args_present ;; esac
/usr/bin/test -d /sys/module/xradio || stop stock_xradio_absent
modinfo_rc=0
module_path=$(/usr/sbin/modinfo -n xradio 2>&1) || modinfo_rc=$?
if [ "$modinfo_rc" -ne 0 ]; then
    if is_refusal "$module_path"; then invalid_refusal modinfo "$module_path"; fi
    stop modinfo_failed
fi
case "$module_path" in /lib/modules/*/kernel/drivers/net/wireless/xradio/xradio.ko*) ;; *) stop xradio_not_in_tree ;; esac
sudo_rc=0
sudo_output=$(/usr/bin/sudo -n true 2>&1) || sudo_rc=$?
if [ "$sudo_rc" -ne 0 ]; then invalid_refusal sudo "$sudo_output"; fi
status_rc=0
status=$(/usr/bin/sudo -n /usr/sbin/wpa_cli -i "$dut_interface" status 2>&1) || status_rc=$?
printf '%s\n' "$status"
printf 'BUILD9_WPA_CLI instrument=wpa_cli interface=%s rc=%s\n' "$dut_interface" "$status_rc"
if [ "$status_rc" -ne 0 ]; then
    if is_refusal "$status"; then invalid_refusal wpa_cli "$status"; fi
    stop association_unreadable
fi
case "$status" in FAIL*) invalid_refusal wpa_cli "$status" ;; esac
printf '%s\n' "$status" | /usr/bin/grep -Fx 'wpa_state=COMPLETED' >/dev/null || stop association_incomplete
printf '%s\n' "$status" | /usr/bin/grep -Fx 'pairwise_cipher=CCMP' >/dev/null || stop pairwise_not_ccmp
ip_rc=0
ip_output=$(/usr/sbin/ip -4 -o addr show dev "$dut_interface" scope global 2>&1) || ip_rc=$?
if [ "$ip_rc" -ne 0 ]; then
    if is_refusal "$ip_output"; then invalid_refusal ip_addr "$ip_output"; fi
    stop address_unreadable
fi
address=$(printf '%s\n' "$ip_output" | /usr/bin/awk 'NR==1 {split($4,a,"/"); print a[1]}')
/usr/bin/test -n "$address" || stop dhcpv4_lease_missing
route_rc=0
route_output=$(/usr/sbin/ip -4 route show default dev "$dut_interface" 2>&1) || route_rc=$?
if [ "$route_rc" -ne 0 ]; then
    if is_refusal "$route_output"; then invalid_refusal ip_route "$route_output"; fi
    stop route_unreadable
fi
printf '%s\n' "$route_output" | /usr/bin/grep -q '^default ' || stop dut_default_route_missing
ssh_rc=0
ssh_output=$(/usr/bin/sudo -n /usr/bin/systemctl is-active ssh 2>&1) || ssh_rc=$?
if is_refusal "$ssh_output"; then invalid_refusal systemctl "$ssh_output"; fi
[ "$ssh_rc" -eq 0 ] || stop ssh_listener_inactive
key_rc=0
host_key=$(/usr/bin/cat /etc/ssh/ssh_host_ed25519_key.pub 2>&1) || key_rc=$?
if [ "$key_rc" -ne 0 ]; then
    if is_refusal "$host_key"; then invalid_refusal ssh_host_key "$host_key"; fi
    stop host_key_missing
fi
printf 'BUILD9_BOOTSTRAP state=PASS dut_interface=%s address=%s stock_xradio=in-tree extra_boot_args=absent ssh=active\n' "$dut_interface" "$address"
printf '%s\n' "$host_key"
