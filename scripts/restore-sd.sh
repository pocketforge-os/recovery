#!/usr/bin/env bash
# restore-sd.sh — Write a PocketForge boot chain onto an SD card.
#
# This is the "re-image" half of the recovery flow. It writes:
#   1. The vendor SPL (boot0.img) at sector 256 (128 KiB) on the SD card
#   2. Optionally, a full .img file via dd
#
# Usage:
#   ./restore-sd.sh --device /dev/sdb --boot0 /path/to/boot0.img
#   ./restore-sd.sh --device /dev/sdb --image /path/to/pocketforge-tsp.img
#
# The --device argument REFUSES mmcblk0 (eMMC) by default.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEVICE=""
BOOT0=""
IMAGE=""
EMMC_OVERRIDE=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: restore-sd.sh --device DEV [OPTIONS]

Write a PocketForge boot chain onto an SD card.

Required:
  --device DEV         Target block device (e.g., /dev/sdb, /dev/mmcblk1)

One of:
  --boot0 FILE         Write only the SPL (boot0.img) at sector 256
  --image FILE         Write a full SD image (dd the entire .img)

Options:
  --dry-run            Show what would be done without writing
  --touch-emmc=YES_I_KNOW_WHAT_IM_DOING
                       Override the eMMC write protection (DANGEROUS)
  -h, --help           Show this help

Safety:
  - Refuses to write to mmcblk0 (internal eMMC) unless explicitly overridden.
  - Verifies the boot0 file contains eGON.BT0 magic before writing.
  - Requires explicit confirmation before writing.
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                DEVICE="${2:?--device requires a block device path}"
                shift 2
                ;;
            --boot0)
                BOOT0="${2:?--boot0 requires a file path}"
                shift 2
                ;;
            --image)
                IMAGE="${2:?--image requires a file path}"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
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

    # Validate arguments
    [[ -n "${DEVICE}" ]] || pf_die "--device is required"
    [[ -n "${BOOT0}" || -n "${IMAGE}" ]] || pf_die "One of --boot0 or --image is required"
    [[ -z "${BOOT0}" || -z "${IMAGE}" ]] || pf_die "Specify --boot0 OR --image, not both"

    # eMMC guard
    pf_guard_emmc "${DEVICE}" "${EMMC_OVERRIDE}" || exit 1

    # Validate device exists
    [[ -b "${DEVICE}" ]] || pf_die "Device ${DEVICE} does not exist or is not a block device"

    if [[ -n "${BOOT0}" ]]; then
        write_boot0
    elif [[ -n "${IMAGE}" ]]; then
        write_image
    fi
}

write_boot0() {
    [[ -f "${BOOT0}" ]] || pf_die "boot0 file not found: ${BOOT0}"

    # Verify eGON.BT0 magic
    if ! pf_check_egon "${BOOT0}"; then
        pf_die "File ${BOOT0} does not contain eGON.BT0 magic at offset 4. Not a valid SPL."
    fi

    local size
    size=$(stat -c %s "${BOOT0}")

    pf_log "Writing SPL to ${DEVICE} at sector ${PF_SPL_SECTOR} (offset ${PF_SPL_OFFSET_BYTES} bytes)"
    pf_log "  Source: ${BOOT0} (${size} bytes)"
    pf_log "  eGON.BT0 magic: verified"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        pf_log "DRY RUN: would run: dd if=${BOOT0} of=${DEVICE} bs=512 seek=${PF_SPL_SECTOR} conv=notrunc,fsync"
        return 0
    fi

    echo ""
    echo "WARNING: This will write ${size} bytes to ${DEVICE} at offset ${PF_SPL_OFFSET_BYTES}."
    echo "Press Ctrl+C within 5 seconds to abort..."
    sleep 5

    dd if="${BOOT0}" of="${DEVICE}" bs=512 seek="${PF_SPL_SECTOR}" conv=notrunc,fsync 2>&1
    sync

    pf_log "SPL write complete."

    # Verify it was written correctly
    if pf_check_egon "${DEVICE}" "${PF_SPL_OFFSET_BYTES}"; then
        pf_log "Verification: eGON.BT0 magic confirmed at sector ${PF_SPL_SECTOR} on ${DEVICE}"
    else
        pf_die "Verification FAILED: eGON.BT0 magic NOT found at sector ${PF_SPL_SECTOR} on ${DEVICE}"
    fi
}

write_image() {
    [[ -f "${IMAGE}" ]] || pf_die "Image file not found: ${IMAGE}"

    local size
    size=$(stat -c %s "${IMAGE}")
    local size_mb=$(( size / 1024 / 1024 ))

    pf_log "Writing full image to ${DEVICE}"
    pf_log "  Source: ${IMAGE} (${size_mb} MiB)"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        pf_log "DRY RUN: would run: dd if=${IMAGE} of=${DEVICE} bs=4M conv=fsync status=progress"
        return 0
    fi

    echo ""
    echo "WARNING: This will OVERWRITE ALL DATA on ${DEVICE} (${size_mb} MiB)."
    echo "Press Ctrl+C within 5 seconds to abort..."
    sleep 5

    dd if="${IMAGE}" of="${DEVICE}" bs=4M conv=fsync status=progress 2>&1
    sync

    pf_log "Image write complete."

    # Verify SPL is present
    if pf_check_egon "${DEVICE}" "${PF_SPL_OFFSET_BYTES}"; then
        pf_log "Verification: eGON.BT0 magic confirmed at sector ${PF_SPL_SECTOR}"
    else
        pf_log "WARNING: eGON.BT0 magic not found at sector ${PF_SPL_SECTOR}. Image may use a different layout."
    fi
}

main "$@"
