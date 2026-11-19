#!/bin/bash
# Install 99-usbip.rules and apply it to the devices already connected.
#
# Activation is staged so local input cannot be lost:
#   1. install the rule and reload udev
#   2. use `udevadm test` (which never executes RUN) to prove that the rule
#      would not export a keyboard, mouse, or hub
#   3. unbind any input device exported by an earlier setup
#   4. trigger add events for the devices already plugged in
#   5. verify what is actually exported
#
# Run as root or as a user allowed to use sudo.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RULE="$SCRIPT_DIR/99-usbip.rules"
TARGET=/etc/udev/rules.d/99-usbip.rules

[ -f "$RULE" ] || { echo "Missing rule file: $RULE" >&2; exit 1; }
command -v usbip >/dev/null || { echo "usbip is not installed: sudo apt install usbip" >&2; exit 1; }

run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

UNSAFE_RULE=0
cleanup() {
    if [ "$UNSAFE_RULE" -eq 1 ]; then
        echo "==> Removing unsafe rule: $TARGET" >&2
        run_root rm -f "$TARGET"
        run_root udevadm control --reload-rules || true
    fi
}
trap cleanup EXIT

props_of() { udevadm info -q property -p "$1" 2>/dev/null || true; }

# True if the installed rule would export this device.
rule_exports() {
    udevadm test --action=add "$1" 2>&1 | grep -q "run: '/usr/bin/usbip bind"
}

is_input() {
    case "$1" in
        *:030101:*|*:030102:*) return 0 ;;
        *) return 1 ;;
    esac
}

# Check the interfaces directly in sysfs too, in case the udev database is stale.
has_boot_hid() {
    local d=$1 iface c s p
    for iface in "$d":*; do
        [ -d "$iface" ] || continue
        c=$(cat "$iface/bInterfaceClass" 2>/dev/null || true)
        s=$(cat "$iface/bInterfaceSubClass" 2>/dev/null || true)
        p=$(cat "$iface/bInterfaceProtocol" 2>/dev/null || true)
        if [ "$c" = "03" ] && [ "$s" = "01" ]; then
            case "$p" in
                01|02) return 0 ;;
            esac
        fi
    done
    return 1
}

echo "==> Installing $RULE -> $TARGET"
run_root install -m 644 "$RULE" "$TARGET"
run_root udevadm control --reload-rules

# Safety gate: the rule must leave every current keyboard, mouse and hub alone.
echo "==> Checking that keyboards, mice and hubs are excluded"
for d in /sys/bus/usb/devices/*-* /sys/bus/usb/devices/usb*; do
    [ -f "$d/idVendor" ] || continue
    busid=$(basename "$d")
    ifaces=$(props_of "$d" | sed -n 's/^ID_USB_INTERFACES=//p')
    devclass=$(cat "$d/bDeviceClass" 2>/dev/null || true)

    kind=
    if has_boot_hid "$d" || is_input "$ifaces"; then
        kind="input device"
    elif [ "$devclass" = "09" ]; then
        kind="hub"
    fi
    [ -n "$kind" ] || continue

    out=$(udevadm test --action=add "$d" 2>&1 || true)
    if printf '%s\n' "$out" | grep -q "run: '/usr/bin/usbip bind"; then
        echo "ERROR: the rule would export $kind $busid ($ifaces)." >&2
        echo "       Not triggering. Check $RULE." >&2
        UNSAFE_RULE=1
        exit 1
    fi
    echo "    ok: $busid $kind stays local"
done

# Release anything already exported that the new rule no longer wants.
# This covers keyboards, mice, hubs, and devices excluded by VID:PID (e.g. webcam).
echo "==> Releasing exported devices the rule no longer exports"
while IFS= read -r busid; do
    [ -n "$busid" ] || continue
    d=/sys/bus/usb/devices/$busid
    [ -d "$d" ] || continue
    if rule_exports "$d"; then
        continue
    fi
    echo "    usbip unbind -b $busid"
    run_root usbip unbind -b "$busid" || true
done < <(find /sys/bus/usb/drivers/usbip-host -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null)

echo "==> Applying the rule to devices already connected"
run_root udevadm trigger --action=add --subsystem-match=usb
sleep 2

echo "==> Exported devices:"
exported=$(find /sys/bus/usb/drivers/usbip-host -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | sort || true)
if [ -n "$exported" ]; then
    while IFS= read -r busid; do
        [ -n "$busid" ] || continue
        echo "    $busid"
    done <<< "$exported"
else
    echo "    (none)"
fi

# Final check: every remaining export must still be wanted by the rule.
FAILED=0
while IFS= read -r busid; do
    [ -n "$busid" ] || continue
    d=/sys/bus/usb/devices/$busid
    [ -d "$d" ] || continue
    if rule_exports "$d"; then
        continue
    fi
    echo "WARNING: $busid is exported but the rule says it should stay local; unbinding it now." >&2
    run_root usbip unbind -b "$busid" || true
    FAILED=1
done <<< "$exported"

[ "$FAILED" -eq 0 ] || exit 1

echo "==> Done. Rule is active."
if command -v systemctl >/dev/null && ! systemctl is-active --quiet usbipd.service 2>/dev/null; then
    echo "WARNING: usbipd.service is not running; exported devices are not reachable yet." >&2
    echo "         sudo systemctl enable --now usbipd" >&2
fi
