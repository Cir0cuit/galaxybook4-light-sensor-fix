#!/usr/bin/env bash
# Rescale the Samsung Galaxy Book4 ambient light sensor by 10x so that KDE
# Plasma's automatic brightness has a usable lux range to learn in.
#
# The sensor (Intel ISH sensor hub, HID 8087:0AC2) declares its illuminance in
# milli-lux but sends values about ten times too small. This installs a HID-BPF
# program that patches the report descriptor (unit exponent -3 -> -2) and a udev
# rule that loads it on every boot. Source: src/0010-Samsung__GalaxyBook4-ALS-scale.bpf.c
#
# Usage: ./install.sh [--force] | --uninstall | --status
#   --force      apply on a model other than the one this was verified on (960XGL)
#   --uninstall  remove the program and the udev rule
#   --status     show whether the patch is active
#
# Works on Fedora and Debian/Ubuntu based distributions. Needs a kernel with
# HID-BPF struct_ops (6.11 or newer) and the udev-hid-bpf package.

set -euo pipefail

NAME=0010-Samsung__GalaxyBook4-ALS-scale
OBJ_SHA256=7389515322b741c82ee9530e5c8f0503fd1f63e2f1bbb0b3ede59c0d1b2be6bc
MODALIAS=hid:b001Fg0003v00008087p00000AC2
RDESC_SIZE=1230
EXP_OFFSETS=(419 1162) # value byte of each illuminance Unit Exponent item
TESTED_MODEL=960XGL

INSTALLED_OBJ=/etc/udev-hid-bpf/$NAME.bpf.o
INSTALLED_RULE=/etc/udev/rules.d/99-hid-bpf-$NAME.rules

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

find_device() {
    local d
    for d in /sys/bus/hid/devices/*; do
        [ -r "$d/modalias" ] && [ "$(cat "$d/modalias")" = "$MODALIAS" ] && { echo "$d"; return 0; }
    done
    return 1
}

current_scale() {
    local f
    f=$(find "$(readlink -f "$1")" -name in_illuminance_scale 2>/dev/null | head -n1)
    [ -n "$f" ] && cat "$f"
}

rdesc_byte() { od -An -tu1 -j "$2" -N1 "$1/report_descriptor" | tr -d ' '; }

# The descriptor must be the one the program was written for: same size, and
# exponent -3 (13, unpatched) or -2 (14, already patched) at both offsets.
check_descriptor() {
    local size off b
    size=$(wc -c < "$1/report_descriptor")
    [ "$size" -eq "$RDESC_SIZE" ] || die "sensor hub descriptor is $size bytes, expected $RDESC_SIZE; this firmware is not supported"
    for off in "${EXP_OFFSETS[@]}"; do
        b=$(rdesc_byte "$1" "$off")
        [ "$b" = 13 ] || [ "$b" = 14 ] || die "unexpected descriptor contents at offset $off; this firmware is not supported"
    done
}

wait_for_scale() {
    local i s
    for i in $(seq 1 20); do
        s=$(current_scale "$1" || true)
        [ -n "$s" ] && { echo "$s"; return 0; }
        sleep 0.5
    done
    return 1
}

status() {
    local dev s
    dev=$(find_device) || die "no Intel ISH sensor hub (8087:0AC2) found"
    s=$(current_scale "$dev" || true)
    echo "device:    $dev"
    echo "installed: $([ -e "$INSTALLED_OBJ" ] && [ -e "$INSTALLED_RULE" ] && echo yes || echo no)"
    case "$s" in
        0.01000*) echo "scale:     $s (patch active)" ;;
        "") echo "scale:     unknown (no light sensor exposed)" ;;
        *) echo "scale:     $s (patch not active)" ;;
    esac
}

install_packages() {
    local missing=()
    command -v udev-hid-bpf > /dev/null || missing+=(udev-hid-bpf)
    # KWin reads the sensor through iio-sensor-proxy
    [ -x /usr/libexec/iio-sensor-proxy ] || [ -x /usr/lib/iio-sensor-proxy ] ||
        command -v iio-sensor-proxy > /dev/null || command -v monitor-sensor > /dev/null ||
        missing+=(iio-sensor-proxy)
    [ ${#missing[@]} -eq 0 ] && return 0

    info "installing ${missing[*]}"
    if command -v dnf > /dev/null; then
        dnf install -y "${missing[@]}"
    elif command -v apt-get > /dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
        die "neither dnf nor apt-get found; install ${missing[*]} manually"
    fi || die "could not install ${missing[*]}; udev-hid-bpf needs Fedora 41+, Debian 13+ or Ubuntu 25.04+"
    command -v udev-hid-bpf > /dev/null || die "udev-hid-bpf is still not available"
}

uninstall() {
    local dev
    if dev=$(find_device) && command -v udev-hid-bpf > /dev/null; then
        udev-hid-bpf remove "$dev" || true
    fi
    rm -f "$INSTALLED_OBJ" "$INSTALLED_RULE"
    udevadm control --reload
    info "removed; the sensor is back to its original scale"
}

install() {
    local force=$1 dev model scale

    model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
    if [ "$model" != "$TESTED_MODEL" ] && [ "$force" != 1 ]; then
        die "this was verified only on the Galaxy Book4 Ultra ($TESTED_MODEL), this machine is '$model'.
       The same sensor hub ID is used on many laptops whose readings are correct.
       Check your sensor as described in the README, then re-run with --force."
    fi

    [ -e /sys/kernel/btf/vmlinux ] || die "kernel has no BTF (/sys/kernel/btf/vmlinux); HID-BPF cannot be used"
    dev=$(find_device) || die "no Intel ISH sensor hub (8087:0AC2) found"
    check_descriptor "$dev"
    install_packages

    TMPDIR_OBJ=$(mktemp -d)
    tmp=$TMPDIR_OBJ
    trap 'rm -rf "$TMPDIR_OBJ"' EXIT
    sed '1,/^__BPF_OBJECT_BASE64__$/d' "$0" | base64 -d > "$tmp/$NAME.bpf.o"
    echo "$OBJ_SHA256  $tmp/$NAME.bpf.o" | sha256sum -c --quiet - || die "embedded program is corrupted"

    info "installing $INSTALLED_OBJ"
    udev-hid-bpf install --force "$tmp/$NAME.bpf.o" > /dev/null
    udevadm control --reload

    info "loading it on $(basename "$dev")"
    udev-hid-bpf remove "$dev" 2> /dev/null || true
    udevadm trigger --action=add "$dev"
    udevadm settle

    scale=$(wait_for_scale "$dev") || die "the light sensor did not come back after loading; run '$0 --uninstall' and reboot"
    case "$scale" in
        0.01000*) ;;
        *) die "program installed but the scale is still $scale; the kernel may lack HID-BPF struct_ops (needs 6.11+). Check 'journalctl -b | grep -i hid-bpf'" ;;
    esac

    info "done: the sensor now reports 10x larger values (scale $scale)"
    cat <<'EOF'

Plasma's previously learned brightness curve no longer fits, so the screen will
probably jump to full brightness. Make sure automatic brightness is enabled in
System Settings > Display & Monitor, then set the brightness you like in two or
three lighting conditions (dark room, lamp light, daylight) and it will re-learn.
EOF
}

action=install
force=0
for arg in "$@"; do
    case "$arg" in
        --force) force=1 ;;
        --uninstall) action=uninstall ;;
        --status) action=status ;;
        -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $arg (see --help)" ;;
    esac
done

if [ "$action" = status ]; then
    status
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    command -v sudo > /dev/null || die "run this script as root"
    exec sudo -- "$BASH" "$0" "$@"
fi

if [ "$action" = uninstall ]; then
    uninstall
else
    install "$force"
fi
exit 0

__BPF_OBJECT_BASE64__
f0VMRgIBAQAAAAAAAAAAAAEA9wABAAAAAAAAAAAAAAAAAAAAAAAAAHARAAAAAAAAAAAAAEAAAAAA
AEAADQABAAAuc3RydGFiAC5zeW10YWIAc3RydWN0X29wcy9oaWRfcmRlc2NfZml4dXAAc3lzY2Fs
bAAuc3RydWN0X29wcy5saW5rAGxpY2Vuc2UALmJzcwAuaGlkX2JwZl9jb25maWcAMDAxMC1TYW1z
dW5nX19HYWxheHlCb29rNC1BTFMtc2NhbGUuYnBmLmMAZ2FsYXh5Ym9va19hbHNfZml4X3JkZXNj
AGhpZF9icGZfZ2V0X2RhdGEAcHJvYmUAZ2FsYXh5Ym9va19hbHNfc2NhbGUAX2xpY2Vuc2UAX19w
cmludGtfc3RyAF9kZXZpY2VfaWRzAC5yZWxzdHJ1Y3Rfb3BzL2hpZF9yZGVzY19maXh1cAAucmVs
LnN0cnVjdF9vcHMubGluawAuQlRGAC5CVEYuZXh0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AGIAAAAEAPH/AAAAAAAAAAAAAAAAAAAAAAAAAAADAAMAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAQA
AAAAAAAAAAAAAAAAAAAAAIwAAAASAAMAAAAAAAAAAAD4AAAAAAAAAKUAAAAgAAAAAAAAAAAAAAAA
AAAAAAAAALYAAAASAAQAAAAAAAAAAAA4AAAAAAAAALwAAAARAAUAAAAAAAAAAABAAAAAAAAAANEA
AAARAAYAAAAAAAAAAAAEAAAAAAAAANoAAAARAAcAAAAAAAAAAADBAAAAAAAAAOcAAAARAAgAAAAA
AAAAAAAoAAAAAAAAAHkRAAAAAAAAtAIAAAAAAAC3AwAAABAAAIUQAAD/////FQAYAAAAAABxAZEB
AAAAAFYBCgAKAAAAcQGSAQAAAABWAQgA0QAAAHEBkwEAAAAAVgEGAAQAAABxAaIBAAAAAFYBBABV
AAAAcQGjAQAAAABWAQIADQAAALQBAAAOAAAAcxCjAQAAAABxAXgEAAAAAFYBCgAKAAAAcQF5BAAA
AABWAQgA0QAAAHEBegQAAAAAVgEGAAQAAABxAYkEAAAAAFYBBABVAAAAcQGKBAAAAABWAQIADQAA
ALQBAAAOAAAAcxCKBAAAAAC0AAAAAAAAAJUAAAAAAAAAYRMEAAAAAAC0AgAAAAAAABYDAQDOBAAA
tAIAAOr///9jIQgQAAAAALQAAAAAAAAAlQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAR1BMAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAAAAAAAAAAKAAAABQAAACAAAAAAAAAAAgAA
AAQAAACf6wEAGAAAAAAAAAAABgAAAAYAAPAEAAAAAAAAAAAAAgIAAAABAAAAAAAAAQgAAABAAAAA
AAAAAAEAAA0EAAAAFAAAAAEAAAAYAAAAAAAAAQQAAAAgAAABHAAAAAEAAAwDAAAAAAAAAAMAAA0H
AAAAAAAAAAoAAAAAAAAADgAAAAAAAAARAAAAAAAAAAAAAAIIAAAANQAAAAAAAAgJAAAAOgAAAAAA
AAEBAAAACAAAAAAAAAAAAAACCwAAAEgAAAADAAAEEAAAAFQAAAAMAAAAAAAAAFgAAAANAAAAQAAA
AAAAAAAPAAAAYAAAAAAAAAAAAAACQAAAAGcAAAAAAAAIDgAAAG0AAAAAAAABBAAAACAAAAAAAAAA
AgAABQQAAAB6AAAAEAAAAAAAAACBAAAAEAAAAAAAAACGAAAAAAAACAQAAAAAAAAAAAAAChIAAACM
AAAAAAAACBMAAACTAAAAAAAACBQAAACjAAAAAAAACBUAAAC0AAAAAAAAAQgAAABAAAAAwgAAAAIA
AAwGAAAAAAAAAAAAAAIYAAAA0wAAAAQAAAQMEAAAVAAAAA4AAAAAAAAA5gAAAA4AAAAgAAAA8QAA
ABkAAABAAAAAegAAAAQAAABAgAAAAAAAAAAAAAMAAAAACQAAABoAAAAAEAAA9wAAAAAAAAEEAAAA
IAAAAAAAAAABAAANBAAAABQAAAAXAAAACwEAAAEAAAwbAAAAEQEAAAgAAARAAAAAHQEAAAQAAAAA
AAAAJAEAAB4AAAAgAAAAKgEAAB8AAABAAAAALwEAACEAAADAAAAAQAEAACYAAAAAAQAAUAEAACgA
AABAAQAAXwEAACsAAACAAQAAdAEAAAwAAADAAQAAeQEAAAAAAAgNAAAAfQEAAAIAAAQQAAAAhwEA
ACAAAAAAAAAAjAEAACAAAABAAAAAAAAAAAAAAAIfAAAAAAAAAAAAAAIiAAAAAAAAAAMAAA0EAAAA
AAAAAAoAAAAAAAAAIwAAAAAAAAAkAAAAkQEAAAQAAAYEAAAAoQEAAAAAAACyAQAAAQAAAMQBAAAC
AAAA1wEAAAMAAADoAQAAAAAACCUAAADsAQAAAAAACAIAAAAAAAAAAAAAAicAAAAAAAAAAQAADQQA
AAAAAAAACgAAAAAAAAAAAAACKQAAAAAAAAAFAAANBAAAAAAAAAAKAAAAAAAAAAkAAAAAAAAAIwAA
AAAAAAAqAAAAAAAAACQAAADyAQAABgAABgQAAAAEAgAAAQAAABcCAAACAAAAKAIAAAMAAAA9AgAA
CQAAAFACAAAKAAAAYQIAAAsAAAAAAAAAAAAAAiwAAAAAAAAAAgAADQQAAAAAAAAACgAAAAAAAAAk
AAAAdgIAAAAAAA4dAAAAAQAAAIsCAAAAAAABAQAAAAgAAAEAAAAAAAAAAwAAAAAuAAAAGgAAAAQA
AACQAgAAAAAADi8AAAABAAAAAAAAAAAAAAMAAAAALgAAABoAAADBAAAAmQIAAAAAAA4xAAAAAQAA
AAAAAAABAAAFKAAAAKYCAAA0AAAAAAAAAAAAAAAFAAAEKAAAAK8CAAA1AAAAAAAAALQCAAA3AAAA
QAAAALgCAAA5AAAAgAAAAL4CAAA7AAAAwAAAAMICAAA9AAAAAAEAAAAAAAAAAAACNgAAAAAAAAAA
AAADAAAAAAQAAAAaAAAAAAAAAAAAAAAAAAACOAAAAAAAAAAAAAADAAAAAAQAAAAaAAAAHwAAAAAA
AAAAAAACOgAAAAAAAAAAAAADAAAAAAQAAAAaAAAAAwAAAAAAAAAAAAACPAAAAAAAAAAAAAADAAAA
AAQAAAAaAAAAh4AAAAAAAAAAAAACPgAAAAAAAAAAAAADAAAAAAQAAAAaAAAAwgoAAMYCAAAAAAAO
MwAAAAEAAADSAgAAAAAABwAAAACYBAAAAQAAD0AAAAAtAAAAAAAAAEAAAACpBAAAAQAADwQAAAAw
AAAAAAAAAAQAAACxBAAAAQAAD8EAAAAyAAAAAAAAAMEAAAC2BAAAAQAADygAAAA/AAAAAAAAACgA
AADGBAAAAQAADwAAAAAWAAAAAAAAAAAAAAAAdW5zaWduZWQgbG9uZyBsb25nAGN0eABpbnQAZ2Fs
YXh5Ym9va19hbHNfZml4X3JkZXNjAF9fdTgAdW5zaWduZWQgY2hhcgBoaWRfYnBmX2N0eABoaWQA
YWxsb2NhdGVkX3NpemUAX191MzIAdW5zaWduZWQgaW50AHJldHZhbABzaXplAF9fczMyAHNpemVf
dABfX2tlcm5lbF9zaXplX3QAX19rZXJuZWxfdWxvbmdfdAB1bnNpZ25lZCBsb25nAGhpZF9icGZf
Z2V0X2RhdGEAaGlkX2JwZl9wcm9iZV9hcmdzAHJkZXNjX3NpemUAcmRlc2MAX19BUlJBWV9TSVpF
X1RZUEVfXwBwcm9iZQBoaWRfYnBmX29wcwBoaWRfaWQAZmxhZ3MAbGlzdABoaWRfZGV2aWNlX2V2
ZW50AGhpZF9yZGVzY19maXh1cABoaWRfaHdfcmVxdWVzdABoaWRfaHdfb3V0cHV0X3JlcG9ydABo
ZGV2AHUzMgBsaXN0X2hlYWQAbmV4dABwcmV2AGhpZF9yZXBvcnRfdHlwZQBISURfSU5QVVRfUkVQ
T1JUAEhJRF9PVVRQVVRfUkVQT1JUAEhJRF9GRUFUVVJFX1JFUE9SVABISURfUkVQT1JUX1RZUEVT
AHU2NABfX3U2NABoaWRfY2xhc3NfcmVxdWVzdABISURfUkVRX0dFVF9SRVBPUlQASElEX1JFUV9H
RVRfSURMRQBISURfUkVRX0dFVF9QUk9UT0NPTABISURfUkVRX1NFVF9SRVBPUlQASElEX1JFUV9T
RVRfSURMRQBISURfUkVRX1NFVF9QUk9UT0NPTABnYWxheHlib29rX2Fsc19zY2FsZQBjaGFyAF9s
aWNlbnNlAF9fcHJpbnRrX3N0cgBfZW50cnkzMABuYW1lAGJ1cwBncm91cAB2aWQAcGlkAF9kZXZp
Y2VfaWRzAGhpZF9kZXZpY2UALi8wMDEwLVNhbXN1bmdfX0dhbGF4eUJvb2s0LUFMUy1zY2FsZS5i
cGYuYwBpbnQgQlBGX1BST0coZ2FsYXh5Ym9va19hbHNfZml4X3JkZXNjLCBzdHJ1Y3QgaGlkX2Jw
Zl9jdHggKmhjdHgpAAlfX3U4ICpkYXRhID0gaGlkX2JwZl9nZXRfZGF0YShoY3R4LCAwIC8qIG9m
ZnNldCAqLywgNDA5NiAvKiBzaXplICovKTsACWlmICghZGF0YSkACWlmIChkYXRhW2l0ZW0gLSAx
N10gPT0gMHgwYSAmJiBkYXRhW2l0ZW0gLSAxNl0gPT0gMHhkMSAmJiBkYXRhW2l0ZW0gLSAxNV0g
PT0gMHgwNCAmJgAJICAgIGRhdGFbaXRlbV0gPT0gMHg1NSAmJiBkYXRhW2l0ZW0gKyAxXSA9PSBF
WFBfTUlOVVNfMykACQlkYXRhW2l0ZW0gKyAxXSA9IEVYUF9NSU5VU18yOwAJY3R4LT5yZXR2YWwg
PSBjdHgtPnJkZXNjX3NpemUgIT0gUkRFU0NfU0laRTsACWlmIChjdHgtPnJldHZhbCkACXJldHVy
biAwOwAuc3RydWN0X29wcy5saW5rAGxpY2Vuc2UALmJzcwAuaGlkX2JwZl9jb25maWcALmtzeW1z
AHN0cnVjdF9vcHMvaGlkX3JkZXNjX2ZpeHVwAHN5c2NhbGwAn+sBACAAAAAAAAAAJAAAACQAAADk
AQAACAIAAAAAAAAIAAAAzQQAAAEAAAAAAAAABQAAAOgEAAABAAAAAAAAABwAAAAQAAAAzQQAABoA
AAAAAAAA3QIAAAkDAAAFqAAACAAAAN0CAABKAwAAD7AAACAAAADdAgAAkQMAAAa4AAAoAAAA3QIA
AJ0DAAAGkAAAMAAAAN0CAACdAwAAHpAAADgAAADdAgAAnQMAACGQAABAAAAA3QIAAJ0DAAA5kAAA
SAAAAN0CAACdAwAAPJAAAFAAAADdAgAAnQMAAFSQAABYAAAA3QIAAPMDAAAGlAAAYAAAAN0CAADz
AwAAGZQAAGgAAADdAgAA8wMAAByUAABwAAAA3QIAAPMDAAAZlAAAgAAAAN0CAAAtBAAAEpgAAIgA
AADdAgAAnQMAAAaQAACQAAAA3QIAAJ0DAAAekAAAmAAAAN0CAACdAwAAIZAAAKAAAADdAgAAnQMA
ADmQAACoAAAA3QIAAJ0DAAA8kAAAsAAAAN0CAACdAwAAVJAAALgAAADdAgAA8wMAAAaUAADAAAAA
3QIAAPMDAAAZlAAAyAAAAN0CAADzAwAAHJQAANAAAADdAgAA8wMAABmUAADgAAAA3QIAAC0EAAAS
mAAA6AAAAN0CAAAJAwAABagAAOgEAAADAAAAAAAAAN0CAABNBAAAFfgAABAAAADdAgAAewQAAAb8
AAAoAAAA3QIAAI0EAAACCAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAADAAAAIAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAA
NQEAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAJAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAB4
AQAAAAAAAAgBAAAAAAAAAQAAAAAAAAAIAAAAAAAAABgAAAAAAAAAEQAAAAEAAAAGAAAAAAAAAAAA
AAAAAAAAgAIAAAAAAAD4AAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAACwAAAABAAAABgAA
AAAAAAAAAAAAAAAAAHgDAAAAAAAAOAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAA0AAAA
AQAAAAMAAAAAAAAAAAAAAAAAAACwAwAAAAAAAEAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAA
AAAARQAAAAEAAAADAAAAAAAAAAAAAAAAAAAA8AMAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAQAAAAAA
AAAAAAAAAAAAAE0AAAAIAAAAAwAAAAAAAAAAAAAAAAAAAPQDAAAAAAAAwQAAAAAAAAAAAAAAAAAA
AAEAAAAAAAAAAAAAAAAAAABSAAAAAQAAAAMAAAAAAAAAAAAAAAAAAAD4AwAAAAAAACgAAAAAAAAA
AAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAA8wAAAAkAAABAAAAAAAAAAAAAAAAAAAAAIAQAAAAAAAAQ
AAAAAAAAAAIAAAADAAAACAAAAAAAAAAQAAAAAAAAABIBAAAJAAAAQAAAAAAAAAAAAAAAAAAAADAE
AAAAAAAAEAAAAAAAAAACAAAABQAAAAgAAAAAAAAAEAAAAAAAAAAnAQAAAQAAAAAAAAAAAAAAAAAA
AAAAAABABAAAAAAAAAgLAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAALAEAAAEAAAAAAAAA
AAAAAAAAAAAAAAAASA8AAAAAAAAoAgAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAA==
