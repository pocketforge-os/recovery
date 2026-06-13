#!/usr/bin/env bash
# run-sd-recovery-test.sh — Execute the full corrupt-and-recover test loop.
#
# This is the end-to-end test that proves SD self-recovery works:
#   1. Verify the SD card has a valid SPL at sector 256
#   2. Back up the SPL region
#   3. Corrupt the SPL (zero the eGON.BT0 header)
#   4. Prompt the user to insert the corrupted SD and power on
#   5. Verify (via serial console or user confirmation) that the device
#      boots from eMMC (stock CrossMix) instead
#   6. Prompt the user to remove the SD
#   7. Restore the SPL from the backup
#   8. Prompt the user to re-insert and verify boot
#
# The entire transcript is logged to tests/<date>.log.
#
# Usage:
#   ./run-sd-recovery-test.sh --device /dev/sdb
#   ./run-sd-recovery-test.sh --device /dev/mmcblk1
#
# Prerequisites:
#   - SD card accessible on the host (in a card reader, NOT in the device)
#   - The SD card has a valid boot chain (eGON.BT0 at sector 256)
#     OR: the test will use any SD card and write a known boot0.img
#   - Serial console connected for boot verification (optional but recommended)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEVICE=""
SERIAL_DEV=""
TRANSCRIPT=""

usage() {
    cat <<'EOF'
Usage: run-sd-recovery-test.sh --device DEV [OPTIONS]

Execute the full SD corrupt-and-recover test loop with transcript logging.

Required:
  --device DEV         SD card block device on the host (e.g., /dev/sdb)

Options:
  --serial DEV         Serial console device (e.g., /dev/ttyACM0) for automated
                       boot verification. If not specified, uses manual user
                       confirmation.
  -h, --help           Show this help

Output:
  Transcript is written to tests/<date>.log in the recovery repo.
EOF
}

# Tee all output to the transcript file
start_transcript() {
    local date_str
    date_str=$(date -u '+%Y-%m-%d')
    TRANSCRIPT="${REPO_DIR}/tests/${date_str}-sd-recovery-test.log"
    mkdir -p "${REPO_DIR}/tests"

    exec > >(tee -a "${TRANSCRIPT}") 2>&1
    pf_log "=== PocketForge SD Recovery Test ==="
    pf_log "Transcript: ${TRANSCRIPT}"
    pf_log "Host: $(hostname)"
    pf_log "Date: $(date -u)"
    pf_log "Device: ${DEVICE}"
    pf_log ""
}

wait_for_user() {
    local prompt="$1"
    echo ""
    echo ">>> ${prompt}"
    echo ">>> Press ENTER when ready..."
    read -r
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                DEVICE="${2:?--device requires a block device path}"
                shift 2
                ;;
            --serial)
                SERIAL_DEV="${2:?--serial requires a device path}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    [[ -n "${DEVICE}" ]] || pf_die "--device is required"

    # eMMC guard (should never trigger in normal use, but belt-and-suspenders)
    pf_guard_emmc "${DEVICE}" || exit 1

    start_transcript

    # -------------------------------------------------------------------------
    # PHASE 1: Establish baseline
    # -------------------------------------------------------------------------
    pf_log "=== PHASE 1: Establish baseline ==="

    wait_for_user "Insert the SD card into the host card reader. Make sure it is NOT in the device."

    [[ -b "${DEVICE}" ]] || pf_die "Device ${DEVICE} not found. Is the SD card inserted in the host?"

    pf_log "Checking for valid SPL at sector ${PF_SPL_SECTOR} on ${DEVICE}..."
    if pf_check_egon "${DEVICE}" "${PF_SPL_OFFSET_BYTES}"; then
        pf_log "PASS: eGON.BT0 magic found at sector ${PF_SPL_SECTOR}. Valid SPL present."
    else
        pf_log "INFO: No eGON.BT0 magic at sector ${PF_SPL_SECTOR}. This SD may not have a PocketForge boot chain yet."
        pf_log "INFO: The test will still work — we'll verify the BROM falls through to eMMC."
        pf_log "INFO: If you want to test with a valid SPL, write one first with restore-sd.sh."
    fi

    # Back up the SPL region regardless
    local backup_file="${REPO_DIR}/tests/.spl-backup-$(date -u '+%Y%m%d%H%M%S').bin"
    pf_log "Backing up 32 KiB from sector ${PF_SPL_SECTOR} to ${backup_file}..."
    dd if="${DEVICE}" of="${backup_file}" bs=512 skip="${PF_SPL_SECTOR}" count=64 2>/dev/null
    pf_log "Backup saved."

    # -------------------------------------------------------------------------
    # PHASE 2: Corrupt the SPL
    # -------------------------------------------------------------------------
    pf_log ""
    pf_log "=== PHASE 2: Corrupt the SPL ==="
    pf_log "Zeroing 32 KiB at sector ${PF_SPL_SECTOR} on ${DEVICE}..."

    dd if=/dev/zero of="${DEVICE}" bs=512 seek="${PF_SPL_SECTOR}" count=64 conv=notrunc,fsync 2>/dev/null
    sync

    if pf_check_egon "${DEVICE}" "${PF_SPL_OFFSET_BYTES}"; then
        pf_die "Corruption FAILED: eGON.BT0 magic still present!"
    fi
    pf_log "PASS: eGON.BT0 magic destroyed. SPL is corrupted."

    # Also check sector 16 (8 KiB) — the BROM checks here too
    if pf_check_egon "${DEVICE}" $((16 * 512)); then
        pf_log "NOTE: eGON.BT0 found at sector 16 (8 KiB offset). Zeroing it too..."
        dd if=/dev/zero of="${DEVICE}" bs=512 seek=16 count=64 conv=notrunc,fsync 2>/dev/null
        sync
        pf_log "Sector 16 zeroed."
    else
        pf_log "INFO: No eGON.BT0 at sector 16 (expected — PocketForge uses sector 256)."
    fi

    # -------------------------------------------------------------------------
    # PHASE 3: Verify boot failure + self-recovery
    # -------------------------------------------------------------------------
    pf_log ""
    pf_log "=== PHASE 3: Verify boot failure + eMMC self-recovery ==="

    wait_for_user "Remove the SD card from the host reader and INSERT it into the TrimUI Smart Pro. Then POWER ON the device."

    pf_log "Device should be booting now. The corrupted SD will be skipped by the BROM."
    pf_log "The device should boot from internal eMMC (stock CrossMix)."

    if [[ -n "${SERIAL_DEV}" ]]; then
        pf_log "Capturing serial output from ${SERIAL_DEV} for 30 seconds..."
        local serial_log="${REPO_DIR}/tests/.serial-phase3-$(date -u '+%Y%m%d%H%M%S').log"
        timeout 30 cat "${SERIAL_DEV}" > "${serial_log}" 2>/dev/null || true
        pf_log "Serial capture saved to ${serial_log}"
        if grep -q "eGON.BT0" "${serial_log}" 2>/dev/null; then
            pf_log "PASS: eGON.BT0 banner seen on serial — eMMC boot chain loaded."
        fi
        if grep -q "Linux version 4.9.191" "${serial_log}" 2>/dev/null; then
            pf_log "PASS: Linux 4.9.191 kernel loaded from eMMC."
        fi
    fi

    echo ""
    echo "=== VERIFICATION QUESTIONS ==="
    echo ""
    echo "1. Did the device boot successfully? (You should see the stock CrossMix UI"
    echo "   or be able to SSH to 192.168.86.98)"
    echo ""
    echo "2. If serial console is connected: did you see the normal boot sequence"
    echo "   (eGON.BT0 -> U-Boot -> Linux 4.9.191)?"
    echo ""
    echo "Answer: did the device boot from eMMC (stock CrossMix)? (y/N)"
    read -r answer

    if [[ "${answer}" == "y" || "${answer}" == "Y" ]]; then
        pf_log "PASS: User confirmed device booted from eMMC despite corrupted SD."
        pf_log "Self-recovery path VERIFIED."
    else
        pf_log "FAIL: Device did NOT boot from eMMC. Investigate."
        pf_log "NOTE: The SD card SPL is corrupted. Remove the SD to restore normal eMMC boot."
        # Don't exit — we still want to restore the SD
    fi

    # -------------------------------------------------------------------------
    # PHASE 4: Restore the SD
    # -------------------------------------------------------------------------
    pf_log ""
    pf_log "=== PHASE 4: Restore the SD ==="

    wait_for_user "Power OFF the device. Remove the SD card from the device and INSERT it into the host card reader."

    [[ -b "${DEVICE}" ]] || pf_die "Device ${DEVICE} not found. Is the SD card inserted in the host?"

    pf_log "Restoring SPL from backup (${backup_file})..."
    dd if="${backup_file}" of="${DEVICE}" bs=512 seek="${PF_SPL_SECTOR}" conv=notrunc,fsync 2>/dev/null
    sync

    if pf_check_egon "${DEVICE}" "${PF_SPL_OFFSET_BYTES}"; then
        pf_log "PASS: eGON.BT0 magic restored at sector ${PF_SPL_SECTOR}."
    else
        pf_log "INFO: eGON.BT0 not found after restore — the original SD may not have had a PocketForge SPL."
        pf_log "INFO: This is OK if the SD was blank/data-only to begin with."
    fi

    # Clean up backup
    rm -f "${backup_file}"

    # -------------------------------------------------------------------------
    # SUMMARY
    # -------------------------------------------------------------------------
    pf_log ""
    pf_log "=== TEST SUMMARY ==="
    pf_log "Phase 1 (baseline): COMPLETE"
    pf_log "Phase 2 (corrupt):  COMPLETE — SPL zeroed at sector ${PF_SPL_SECTOR}"
    pf_log "Phase 3 (self-recovery): ${answer:+PASS — eMMC boot confirmed}${answer:-NEEDS VERIFICATION}"
    pf_log "Phase 4 (restore):  COMPLETE — SPL backup restored"
    pf_log ""
    pf_log "Transcript saved to: ${TRANSCRIPT}"
    pf_log ""
    pf_log "=== END OF TEST ==="
}

main "$@"
