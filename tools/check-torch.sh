#!/bin/sh
# Try every flash LED channel in turn and say which are present.
#
# The X6525 has two dual-LED flash chips on i2c5 (AW36515 at 0x63, OCP81375 at
# 0x64), four channels in all, exposed by leds-sprd-flash as
# /sys/class/leds/white:flash, white:flash-1, -2, -3. Which one is the rear and
# which the front light is not known; this lights each for 3 s so you can tell.
# Run it from a shell on the phone: sh check-torch.sh
S=$(command -v sudo >/dev/null 2>&1 && echo "sudo -n")
echo "== drivers and chips"
$S dmesg | grep -i -E "leds-sprd-flash|5-00(63|64)" | tail -8
for a in 63 64; do
	d=/sys/bus/i2c/devices/5-00$a
	[ -e "$d/driver" ] && echo "chip 0x$a: driver $(basename "$(readlink "$d/driver")")" || echo "chip 0x$a: NO driver bound"
done
echo
echo "== channels"
n=0
for l in /sys/class/leds/white:flash*; do
	[ -d "$l" ] || continue
	n=$((n + 1))
	max=$(cat "$l"/max_brightness)
	echo "$(basename "$l") (max $max): on for 3 s, watch the phone"
	echo "$max" | $S tee "$l"/brightness >/dev/null
	sleep 3
	echo 0 | $S tee "$l"/brightness >/dev/null
	sleep 1
done
[ "$n" -eq 0 ] && echo "no white:flash* LED: the driver did not register any channel"
echo
echo "Tell me which line lit the rear light, which the front one, and whether any was dim."
