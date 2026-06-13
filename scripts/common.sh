#!/usr/bin/env bash
# common.sh — Shared constants and helpers for PocketForge recovery scripts.
#
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"

# -- Device constants ----------------------------------------------------------

# Allwinner A133 FEL USB ID
readonly PF_FEL_VID="1f3a"
readonly PF_FEL_PID="efe8"
readonly PF_FEL_USB_ID="${PF_FEL_VID}:${PF_FEL_PID}"

# A133 sunxi-tools constants (from sunxi-tools/soc_info.c)
readonly PF_SOC_ID="0x1855"
readonly PF_SPL_ADDR="0x20000"
readonly PF_SRAM_SIZE="148K"

# SD card boot-chain offsets (Allwinner A133 BROM convention)
# The BROM checks sector 16 (8 KiB) first, then sector 256 (128 KiB).
# PocketForge (and KNULLI/muOS/CrossMix) uses sector 256 for the SPL.
readonly PF_SPL_SECTOR=256
readonly PF_SPL_OFFSET_BYTES=$((PF_SPL_SECTOR * 512))  # 131072 = 128 KiB

# boot_package.fex offset (16 MiB)
readonly PF_BOOTPKG_OFFSET_BYTES=$((16 * 1024 * 1024))  # 16777216

# eGON.BT0 magic (vendor SPL signature)
readonly PF_EGON_MAGIC="eGON.BT0"

# Internal eMMC device (NEVER write to this without explicit override)
readonly PF_EMMC_DEV="mmcblk0"

# -- eMMC write protection -----------------------------------------------------

# Refuse operations on eMMC unless the caller explicitly opts in.
# Usage: pf_guard_emmc "$device_path" [--touch-emmc=YES_I_KNOW_WHAT_IM_DOING]
pf_guard_emmc() {
    local device="$1"
    local override="${2:-}"

    # Normalize: strip /dev/ prefix for comparison
    local dev_name="${device#/dev/}"

    # Check if the device is the internal eMMC (mmcblk0 or any of its partitions/boot areas)
    if [[ "${dev_name}" == ${PF_EMMC_DEV}* ]]; then
        if [[ "${override}" != "--touch-emmc=YES_I_KNOW_WHAT_IM_DOING" ]]; then
            echo "REFUSED: target device '${device}' is the internal eMMC (${PF_EMMC_DEV})." >&2
            echo "" >&2
            echo "PocketForge runs from SD; the stock eMMC OS is your safety net." >&2
            echo "Writing to eMMC risks bricking the device with no self-recovery path." >&2
            echo "" >&2
            echo "If you REALLY need to write eMMC (you almost certainly don't):" >&2
            echo "  Add --touch-emmc=YES_I_KNOW_WHAT_IM_DOING to the command." >&2
            echo "" >&2
            echo "For normal SD recovery, specify the SD card device (e.g., /dev/sdb or /dev/mmcblk1)." >&2
            return 1
        fi
        echo "WARNING: eMMC write override accepted. Proceeding with ${device}." >&2
        echo "WARNING: You are writing to the internal eMMC. This voids self-recovery." >&2
    fi
    return 0
}

# -- Helpers -------------------------------------------------------------------

# Check if a file starts with eGON.BT0 magic at the expected offset.
# Usage: pf_check_egon <file_or_device> [offset_bytes]
pf_check_egon() {
    local target="$1"
    local offset="${2:-0}"

    local magic
    magic=$(dd if="${target}" bs=1 skip=$((offset + 4)) count=8 2>/dev/null | tr -d '\0') || return 1

    if [[ "${magic}" == "${PF_EGON_MAGIC}" ]]; then
        return 0
    fi
    return 1
}

# Print a timestamped log line (for transcript capture).
pf_log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

# Die with an error message.
pf_die() {
    echo "FATAL: $*" >&2
    exit 1
}
