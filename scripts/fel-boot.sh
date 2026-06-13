#!/usr/bin/env bash
# fel-boot.sh — Boot the TrimUI Smart Pro from a host machine via FEL (USB recovery).
#
# Pushes the vendor SPL and U-Boot over USB-OTG to an A133 device in FEL mode,
# then executes U-Boot. From there, U-Boot can load a kernel from SD, tftp, etc.
#
# This is the "recover from FEL" path: the device has no bootable media,
# or the FEL pads were shorted, and we need to push a bootloader over USB.
#
# Usage:
#   ./fel-boot.sh --boot0 /path/to/boot0.img --uboot /path/to/u-boot.bin
#   ./fel-boot.sh --boot0 /path/to/boot0.img  # SPL only (drops to FEL SPL shell)
#
# Prerequisites:
#   - Device in FEL mode (check-fel.sh passes)
#   - sunxi-tools installed (sunxi-fel)
#   - USB-OTG cable connected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BOOT0=""
UBOOT=""

usage() {
    cat <<'EOF'
Usage: fel-boot.sh --boot0 FILE [--uboot FILE]

Push bootloader(s) to an Allwinner A133 device in FEL mode via USB-OTG.

Required:
  --boot0 FILE     Vendor SPL (boot0.img) — loaded and executed first

Optional:
  --uboot FILE     U-Boot binary (u-boot.bin) — loaded after SPL, executed at 0x4a000000

Flow:
  1. Verify FEL device is present (USB ID 1f3a:efe8)
  2. Push boot0.img as SPL via sunxi-fel
  3. If --uboot given: push u-boot.bin to DRAM and execute

Notes:
  - The A133 SPL address is 0x20000 (from sunxi-tools soc_info.c)
  - U-Boot load address is 0x4a000000 (standard for sun50iw10/A133)
  - After U-Boot runs, the device can boot from SD, network, etc.
  - This does NOT write anything persistent — it only boots from RAM.

Prerequisites:
  - sunxi-tools installed
  - Device in FEL mode (use check-fel.sh to verify)
  - USB-OTG cable connected between host and device
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --boot0)
                BOOT0="${2:?--boot0 requires a file path}"
                shift 2
                ;;
            --uboot)
                UBOOT="${2:?--uboot requires a file path}"
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

    [[ -n "${BOOT0}" ]] || pf_die "--boot0 is required"
    [[ -f "${BOOT0}" ]] || pf_die "boot0 file not found: ${BOOT0}"

    if [[ -n "${UBOOT}" ]]; then
        [[ -f "${UBOOT}" ]] || pf_die "u-boot file not found: ${UBOOT}"
    fi

    # Verify boot0 is a valid SPL
    if ! pf_check_egon "${BOOT0}"; then
        pf_die "File ${BOOT0} does not contain eGON.BT0 magic at offset 4. Not a valid SPL."
    fi

    # Check FEL device is present
    pf_log "Checking for FEL device..."
    "${SCRIPT_DIR}/check-fel.sh" || pf_die "No FEL device found. See docs/fel-entry.md for entry procedure."

    # Push SPL
    pf_log "Pushing SPL via sunxi-fel spl..."
    pf_log "  Source: ${BOOT0}"
    sunxi-fel spl "${BOOT0}" 2>&1
    pf_log "SPL loaded and executing."

    if [[ -n "${UBOOT}" ]]; then
        # Give SPL time to initialize DRAM
        pf_log "Waiting 3 seconds for SPL to initialize DRAM..."
        sleep 3

        pf_log "Pushing U-Boot to 0x4a000000..."
        pf_log "  Source: ${UBOOT}"
        sunxi-fel write 0x4a000000 "${UBOOT}" 2>&1
        pf_log "U-Boot loaded. Executing..."
        sunxi-fel exe 0x4a000000 2>&1
        pf_log "U-Boot should now be running. Check serial console."
    else
        pf_log "No --uboot specified. SPL is running; device is in SPL FEL state."
        pf_log "You can now use sunxi-fel commands directly (write, exe, etc.)."
    fi
}

main "$@"
