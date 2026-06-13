#!/usr/bin/env bash
# corrupt-sd-spl.sh — Deliberately corrupt the SPL on an SD card for recovery testing.
#
# This is the "corrupt" half of the corrupt-and-recover test loop.
# It zeroes the eGON.BT0 header region at sector 256 on the SD card,
# which prevents the Allwinner A133 BROM from finding a valid SPL.
#
# Usage:
#   ./corrupt-sd-spl.sh --device /dev/sdb
#
# The --device argument REFUSES mmcblk0 (eMMC) by default.
# After corruption, the device will NOT boot from this SD card.
# Self-recovery: remove the SD card and the device boots from internal eMMC (stock CrossMix).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEVICE=""
EMMC_OVERRIDE=""
BACKUP_FILE=""

usage() {
    cat <<'EOF'
Usage: corrupt-sd-spl.sh --device DEV [OPTIONS]

Deliberately corrupt the SPL (boot0) on an SD card for recovery testing.
Zeroes 32 KiB at sector 256 (128 KiB offset), destroying the eGON.BT0 header.

Required:
  --device DEV         Target block device (e.g., /dev/sdb, /dev/mmcblk1)

Options:
  --backup FILE        Save the original SPL region to FILE before corrupting
  --touch-emmc=YES_I_KNOW_WHAT_IM_DOING
                       Override the eMMC write protection (DANGEROUS)
  -h, --help           Show this help

After corruption:
  - The A133 BROM will skip this SD card (no valid eGON.BT0 signature).
  - Self-recovery: remove the SD card. The device boots from internal eMMC.
  - To restore: use restore-sd.sh --device DEV --boot0 <boot0.img>
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                DEVICE="${2:?--device requires a block device path}"
                shift 2
                ;;
            --backup)
                BACKUP_FILE="${2:?--backup requires a file path}"
                shift 2
                ;;
            --touch-emmc=*)
                EMMC_OVERRIDE="$1"
                shift
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

    # eMMC guard
    pf_guard_emmc "${DEVICE}" "${EMMC_OVERRIDE}" || exit 1

    # Validate device exists
    [[ -b "${DEVICE}" ]] || pf_die "Device ${DEVICE} does not exist or is not a block device"

    # Confirm the SPL is currently present
    pf_log "Checking for existing SPL at sector ${PF_SPL_SECTOR} on ${DEVICE}..."
    if pf_check_egon "${DEVICE}" "${PF_SPL_OFFSET_BYTES}"; then
        pf_log "eGON.BT0 magic found — valid SPL present at sector ${PF_SPL_SECTOR}."
    else
        pf_log "WARNING: No eGON.BT0 magic found at sector ${PF_SPL_SECTOR}. SPL may already be corrupt or absent."
        echo "Continue anyway? (y/N) " >&2
        read -r answer
        [[ "${answer}" == "y" || "${answer}" == "Y" ]] || exit 1
    fi

    # Backup if requested
    if [[ -n "${BACKUP_FILE}" ]]; then
        pf_log "Backing up 32 KiB from sector ${PF_SPL_SECTOR} to ${BACKUP_FILE}..."
        dd if="${DEVICE}" of="${BACKUP_FILE}" bs=512 skip="${PF_SPL_SECTOR}" count=64 2>/dev/null
        pf_log "Backup saved: ${BACKUP_FILE} ($(stat -c %s "${BACKUP_FILE}") bytes)"
    fi

    pf_log "CORRUPTING SPL at sector ${PF_SPL_SECTOR} on ${DEVICE} (zeroing 32 KiB)..."
    echo ""
    echo "WARNING: This will destroy the SPL on ${DEVICE}."
    echo "The device will NOT boot from this SD card after corruption."
    echo "Self-recovery: remove the SD card (device boots from eMMC)."
    echo "Press Ctrl+C within 3 seconds to abort..."
    sleep 3

    dd if=/dev/zero of="${DEVICE}" bs=512 seek="${PF_SPL_SECTOR}" count=64 conv=notrunc,fsync 2>&1
    sync

    # Verify corruption succeeded
    if pf_check_egon "${DEVICE}" "${PF_SPL_OFFSET_BYTES}"; then
        pf_die "Corruption FAILED: eGON.BT0 magic still present at sector ${PF_SPL_SECTOR}!"
    else
        pf_log "Corruption verified: eGON.BT0 magic is GONE from sector ${PF_SPL_SECTOR}."
        pf_log "The device will NOT boot from this SD card."
        pf_log "Self-recovery: remove the SD card."
    fi
}

main "$@"
