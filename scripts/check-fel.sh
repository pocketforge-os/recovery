#!/usr/bin/env bash
# check-fel.sh — Detect an Allwinner device in FEL mode (USB ID 1f3a:efe8).
#
# Exits 0 if a FEL device is found and sunxi-fel can communicate with it.
# Exits 1 otherwise.
#
# Usage:
#   ./check-fel.sh              # check once
#   ./check-fel.sh --wait 60    # poll for up to 60 seconds
#
# Used as a precondition by other recovery scripts before any flash operation.

set -euo pipefail

readonly FEL_VID="1f3a"
readonly FEL_PID="efe8"
readonly FEL_USB_ID="${FEL_VID}:${FEL_PID}"

WAIT_SECONDS=0

usage() {
    cat <<'EOF'
Usage: check-fel.sh [OPTIONS]

Detect an Allwinner A133 device in FEL mode (USB ID 1f3a:efe8).

Options:
  --wait SECONDS    Poll for up to SECONDS before giving up (default: 0 = check once)
  -h, --help        Show this help

Exit codes:
  0   FEL device found and sunxi-fel communication verified
  1   No FEL device found (or sunxi-fel not installed)

Prerequisites:
  - sunxi-tools installed (provides sunxi-fel)
  - USB-OTG cable connected between host and TrimUI Smart Pro
  - Device in FEL mode (see docs/fel-entry.md)
EOF
}

check_prerequisites() {
    if ! command -v sunxi-fel >/dev/null 2>&1; then
        echo "ERROR: sunxi-fel not found. Install sunxi-tools:" >&2
        echo "  sudo apt install sunxi-tools" >&2
        return 1
    fi

    if ! command -v lsusb >/dev/null 2>&1; then
        echo "ERROR: lsusb not found. Install usbutils:" >&2
        echo "  sudo apt install usbutils" >&2
        return 1
    fi
}

# Check if a FEL device is visible on the USB bus.
usb_fel_present() {
    lsusb -d "${FEL_USB_ID}" >/dev/null 2>&1
}

# Verify sunxi-fel can actually talk to the device.
fel_verify() {
    local output
    if output=$(sunxi-fel ver 2>&1); then
        echo "FEL device found:"
        echo "  USB ID: ${FEL_USB_ID}"
        echo "  ${output}"
        return 0
    else
        echo "WARNING: USB device ${FEL_USB_ID} present but sunxi-fel ver failed:" >&2
        echo "  ${output}" >&2
        return 1
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wait)
                WAIT_SECONDS="${2:?--wait requires a number of seconds}"
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

    check_prerequisites || exit 1

    local deadline=$((SECONDS + WAIT_SECONDS))

    while true; do
        if usb_fel_present; then
            if fel_verify; then
                exit 0
            fi
        fi

        if [[ $SECONDS -ge $deadline ]]; then
            break
        fi

        sleep 1
    done

    echo "ERROR: No FEL device found (USB ID ${FEL_USB_ID})." >&2
    echo "" >&2
    echo "To enter FEL mode on the TrimUI Smart Pro:" >&2
    echo "  1. Remove all bootable media (SD card), OR" >&2
    echo "  2. Short the FEL pads on the PCB while powering on" >&2
    echo "See docs/fel-entry.md for the full procedure." >&2
    exit 1
}

main "$@"
