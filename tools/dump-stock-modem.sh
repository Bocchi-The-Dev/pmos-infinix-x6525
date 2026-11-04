#!/system/bin/sh
# Collect what the STOCK Android system shows about how the cellular modem comes up.
# Read-only. Run as root on the stock system (Termux with root works):
#   su -c 'sh /sdcard/dump-stock-modem.sh'      # writes /sdcard/modem-dump/
# then pull or attach /sdcard/modem-dump. Nothing identifying is collected: the
# IMEI, serial numbers and the modem's NV data are filtered out or skipped.
OUT=${1:-/sdcard/modem-dump}
mkdir -p "$OUT"
W() { echo "=== $*" >> "$OUT/info.txt"; }

W "kernel and boot"
{ uname -a; cat /proc/cmdline | sed -E 's/androidboot\.(serialno|wifimacaddr|btmacaddr)=[^ ]*//g'; } >> "$OUT/info.txt" 2>&1

W "kernel log: modem, cp, sipc, mailbox, sblock, spool, seth, sim, rfboard"
dmesg 2>/dev/null | grep -i -E "modem|sipc|sblock|spool|smsg|mailbox|cproc|cp_|seth|sprd-sim|sim_|rfboard|pubcp|wtlcp|l_modem|cp boot|cpboot|vddsim|SIM" | head -400 >> "$OUT/info.txt"

W "modem related modules"
lsmod 2>/dev/null | grep -i -E "modem|sipc|sblock|spool|seth|sim|cp|mbox|mailbox|wwan|ril|rpmsg" >> "$OUT/info.txt"
ls /vendor_dlkm/lib/modules 2>/dev/null | grep -i -E "modem|sipc|sblock|spool|seth|sim|cp|mbox|ril" >> "$OUT/info.txt"

W "device nodes the radio stack uses"
ls -l /dev 2>/dev/null | grep -i -E "slog|stty|spipe|sblock|seth|spool|sdiag|modem|sipc|at|ril|gnss|ttyS|wwan|mbim|rmnet|ccci" >> "$OUT/info.txt"
ls /sys/class 2>/dev/null | grep -i -E "modem|sipc|sblock|spool|seth|wwan|remoteproc|net" >> "$OUT/info.txt"
ls /sys/class/net >> "$OUT/info.txt" 2>&1

W "interrupts and memory"
grep -i -E "mbox|mailbox|sipc|modem|cp|ipi" /proc/interrupts >> "$OUT/info.txt" 2>&1
grep -i -E "modem|cp|sipc|smem" /proc/iomem >> "$OUT/info.txt" 2>&1

W "ril and sim properties (identifiers removed)"
getprop 2>/dev/null | grep -i -E "ril|gsm|sim|radio|telephony|modem|rfboard|persist.vendor.radio|ro.vendor.radio|operator" | grep -v -i -E "imei|imsi|iccid|serial|meid|number|msisdn" >> "$OUT/info.txt"

W "radio stack processes and services"
ps -A 2>/dev/null | grep -i -E "rild|ril|radio|modem|phoneprocess|refnotify|slog|cp_diskserver|modem_control|vendor.*ril|connmgr|nvitemd|engpc" >> "$OUT/info.txt"
getprop 2>/dev/null | grep -i -E "init.svc.*(ril|modem|radio|cp|nvitem|engpc|refnotify|connmgr)" >> "$OUT/info.txt"

W "modem partitions"
ls -l /dev/block/by-name 2>/dev/null | grep -i -E "modem|ldsp|gdsp|agdsp|pm_sys|nv|prodnv|miscdata|l_" >> "$OUT/info.txt"

W "live device tree: modem and sipc nodes"
D=/proc/device-tree
for n in $(ls "$D" 2>/dev/null | grep -i -E "modem|sipc|cp|mailbox"); do
	echo "-- $n" >> "$OUT/info.txt"
	ls "$D/$n" >> "$OUT/info.txt" 2>&1
done

# libraries and configs of the radio stack (no NV data, no per-unit files)
for f in /vendor/etc/modem_sp_info.xml /vendor/etc/init/*ril* /vendor/etc/init/*modem* /vendor/etc/init/*cp* \
	/vendor/etc/init/*nv* /vendor/etc/init/*engpc* /vendor/etc/init/*refnotify* /vendor/etc/init/*connmgr*; do
	[ -f "$f" ] && cp "$f" "$OUT"/ 2>/dev/null
done
for f in /vendor/bin/hw/*ril* /vendor/bin/*modem_control* /vendor/bin/*refnotify* /vendor/bin/*nvitemd* /vendor/bin/*connmgr*; do
	[ -f "$f" ] && [ "$(wc -c < "$f")" -lt 6000000 ] && cp "$f" "$OUT"/ 2>/dev/null
done
for k in $(find /vendor_dlkm/lib/modules /vendor/lib/modules -name '*.ko' 2>/dev/null | grep -i -E "modem|sipc|sblock|spool|seth|sim|cproc|mailbox|mbox|ril|cp_"); do
	cp "$k" "$OUT"/ 2>/dev/null
done

echo "wrote $OUT ($(ls "$OUT" | wc -l) files)"
