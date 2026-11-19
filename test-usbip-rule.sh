#!/bin/bash
# Test 99-usbip.rules from this folder with the real udev rule engine.
# Nothing is installed. udevadm test only prints RUN lines, never executes them.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RULE="$SCRIPT_DIR/99-usbip.rules"
BASE="${TMPDIR:-/tmp}/usbip-rule-test"
PR="$BASE/proot-root/usr/bin/proot"
SHADOW="$BASE/udev-rules"

[ -f "$RULE" ] || { echo "Missing rule file: $RULE" >&2; exit 1; }
mkdir -p "$BASE"

# Fetch proot on demand (no root needed).
if [ ! -x "$PR" ]; then
    cd "$BASE" || exit 1
    apt-get download proot >/dev/null 2>&1 || { echo "cannot download proot" >&2; exit 1; }
    rm -rf "$BASE/proot-root"; mkdir -p "$BASE/proot-root"
    dpkg-deb -x proot_*.deb "$BASE/proot-root"
fi

# Shadow copy of the real rules dir, plus the rule under test.
rm -rf "$SHADOW"; mkdir -p "$SHADOW"
cp -a /etc/udev/rules.d/. "$SHADOW"/ 2>/dev/null
cp "$RULE" "$SHADOW"/99-usbip.rules

echo "Rule under test: $RULE"
echo
printf '%-8s %-12s %-34s %s\n' BUSID VID:PID DEVICE DECISION
printf '%-8s %-12s %-34s %s\n' ------ ------- ------ --------

test_one() {
    local dir=$1 label=$2
    local out dec
    out=$("$PR" -b "$SHADOW:/etc/udev/rules.d" \
              udevadm test --action=add "$dir" 2>&1)
    if printf '%s\n' "$out" | grep -q "run: '/usr/bin/usbip bind"; then
        dec="EXPORT via usbip"
    else
        dec="keep local / skip"
    fi
    printf '%-8s %-12s %-34.34s %s\n' "$label" "$3" "$4" "$dec"
}

# Real USB devices (non-root).
for d in /sys/bus/usb/devices/*-*; do
    [ -f "$d/idVendor" ] || continue
    busid=$(basename "$d")
    vidpid=$(cat "$d/idVendor"):$(cat "$d/idProduct")
    product=$(cat "$d/product" 2>/dev/null || echo "?")
    test_one "$d" "$busid" "$vidpid" "$product"
done

# Root hubs: proof that class 09 hubs are skipped.
for d in /sys/bus/usb/devices/usb*; do
    [ -f "$d/idVendor" ] || continue
    test_one "$d" "$(basename "$d")" "hub" "USB root hub"
done

echo
echo "No device was bound. Current usbip-host bindings:"
ls /sys/bus/usb/drivers/usbip-host/ 2>/dev/null | grep -vE '^(bind|match_busid|module|rebind|uevent|unbind)$' || echo "  (none)"
