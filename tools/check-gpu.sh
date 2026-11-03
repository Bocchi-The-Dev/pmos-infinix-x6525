#!/bin/sh
# Is the GPU really doing the work, or is the session on the CPU?
#
#   sh tools/check-gpu.sh            # on the phone, as the normal user
#
# "Compiled in" proves nothing: wlroots/KWin fall back to pixman/llvmpipe
# silently. This script looks for what cannot be faked:
#   1. panfrost bound to the GPU, and the GPU model it found;
#   2. the compositor process holds the render node open and has the Panfrost
#      Mesa driver mapped (software rendering maps LLVM/swrast instead);
#   3. the GPU's job interrupt counter and devfreq state move while you use the UI;
#   4. the GPU clocks left their 26 MHz reset parent (patches 0028/0029);
#   5. thermal: the GPU's thermal zone has a passive trip and a devfreq cooling
#      device bound to it, and the GPU is throttled when it is over the trip.
# It only reads state. sudo is used, when available, for dmesg and clk_summary.
# clk_summary columns are: clock enable prepare protect rate accuracy phase duty.
# Every line is PASS, FAIL or INFO; a final VERDICT line sums it up.

R=0 F=0
pass() { printf 'PASS  %s\n' "$*"; R=$((R + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; F=$((F + 1)); }
info() { printf 'INFO  %s\n' "$*"; }
S=; command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && S='sudo -n'
[ -n "$S" ] || [ "$(id -u)" = 0 ] || info "no passwordless sudo: run 'sudo -v' first for the dmesg and clock checks"

echo "== 1. Panfrost bound to the GPU =="
if lsmod 2>/dev/null | grep -q '^panfrost'; then pass "panfrost module loaded"
else fail "panfrost module not loaded (modprobe panfrost)"; fi
dm=$($S dmesg 2>/dev/null | grep -iE 'panfrost|mali' | tail -12)
if [ -n "$dm" ]; then printf '%s\n' "$dm" | sed 's/^/      /'; fi
case "$dm" in
*"GPU model not found"*) fail "Panfrost does not know this GPU id (needs a GPU_MODEL entry)" ;;
*"failed"*|*"error"*) fail "Panfrost reported an error (see above)" ;;
*"mali-g57"*|*"Mali-G57"*|*"mali-g"*) pass "Panfrost identified the GPU" ;;
*) info "no Panfrost line in dmesg (need sudo, or the ring buffer wrapped)" ;;
esac
render=
for n in /sys/class/drm/renderD*; do
	[ -e "$n" ] || continue
	d=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)")
	info "$(basename "$n") -> driver $d"
	[ "$d" = panfrost ] && render=/dev/dri/$(basename "$n")
done
[ -n "$render" ] && pass "render node $render belongs to panfrost" || fail "no render node owned by panfrost"

echo "== 2. The compositor really uses it =="
cp=
for p in phoc kwin_wayland; do
	pid=$(pgrep -o "$p" 2>/dev/null) && [ -n "$pid" ] && { cp=$p; break; }
done
if [ -z "$cp" ]; then
	fail "no phoc or kwin_wayland process (is the session running? run this over SSH while logged in)"
else
	info "compositor: $cp (pid $pid)"
	fds=$($S ls -l /proc/"$pid"/fd 2>/dev/null)
	maps=$($S cat /proc/"$pid"/maps 2>/dev/null)
	[ -n "$maps" ] || info "cannot read /proc/$pid/maps (run with sudo)"
	if printf '%s\n' "$fds" | grep -q 'renderD'; then pass "$cp holds a render node open"
	else fail "$cp holds NO render node: it is composing on the CPU (pixman/QPainter) or on the display card only"; fi
	if printf '%s\n' "$maps" | grep -qE 'panfrost_dri|libgallium|kmsro_dri|libvulkan_panfrost'; then pass "$cp has the Mesa Panfrost/gallium driver mapped"
	elif [ -n "$maps" ]; then fail "no Panfrost Mesa driver mapped in $cp"; fi
	# libLLVM alone proves nothing: recent Mesa links it into the one library every gallium driver shares
	sw=$(printf '%s\n' "$maps" | grep -E 'swrast|llvmpipe|libvulkan_lvp|lvp_icd' | head -1)
	if [ -n "$sw" ]; then fail "$cp has a software rasterizer mapped ($sw): software rendering is in use"
	elif [ -n "$maps" ]; then pass "no LLVM/swrast in $cp"; fi
	env=$($S tr '\0' '\n' < /proc/"$pid"/environ 2>/dev/null | grep -E '^(WLR_|KWIN_|LIBGL_|GSK_|MESA_|EGL_)')
	[ -n "$env" ] && printf '%s\n' "$env" | sed 's/^/      env /'
	case "$env" in
	*WLR_RENDERER=pixman*|*LIBGL_ALWAYS_SOFTWARE=1*|*KWIN_COMPOSE=Q*) fail "a software-rendering variable is set (above)" ;;
	esac
fi
j=$(journalctl -b --no-pager 2>/dev/null | grep -iE 'renderer|gles2|pixman|vulkan' | tail -5)
[ -n "$j" ] && { info "compositor renderer log:"; printf '%s\n' "$j" | sed 's/^/      /'; }
if command -v eglinfo >/dev/null 2>&1; then
	e=$(eglinfo -B 2>/dev/null | grep -iE 'OpenGL (core )?(profile )?renderer|OpenGL ES profile renderer' | head -3)
	[ -n "$e" ] && printf '%s\n' "$e" | sed 's/^/      /'
	case "$e" in *llvmpipe*) fail "Mesa clients get llvmpipe" ;; *Mali*|*Panfrost*) pass "Mesa clients get Panfrost" ;; esac
fi

tz=
for z in /sys/class/thermal/thermal_zone*; do
	[ "$(cat "$z"/type 2>/dev/null)" = gpu-thermal ] && { tz=$z; break; }
done
tpeak=0 cpeak=0
echo "== 3. The GPU does work while the UI moves =="
irq() { awk '/panfrost|mali/ && /job|gpu|mmu/ {for(i=2;i<NF;i++) if ($i ~ /^[0-9]+$/) s+=$i} END{print s+0}' /proc/interrupts; }
dev=$(ls -d /sys/class/devfreq/*gpu* 2>/dev/null | head -1)
a=$(irq)
if [ -n "$dev" ]; then
	info "devfreq: $(basename "$dev") governor $(cat "$dev"/governor 2>/dev/null), available $(cat "$dev"/available_frequencies 2>/dev/null)"
	f0=$(cat "$dev"/cur_freq 2>/dev/null)
else
	fail "no GPU devfreq device (no OPP table, or Panfrost not bound)"
fi
echo "      for the next 6 s: swipe the shade up and down / scroll an app / run a video"
mx=0; i=0
while [ "$i" -lt 12 ]; do
	[ -n "$dev" ] && { f=$(cat "$dev"/cur_freq 2>/dev/null); [ "${f:-0}" -gt "$mx" ] && mx=$f; }
	if [ -n "$tz" ]; then
		t=$(cat "$tz"/temp 2>/dev/null); [ "${t:-0}" -gt "$tpeak" ] && tpeak=$t
		for c in "$tz"/cdev*; do
			[ -e "$c" ] || continue
			case "$(cat "$c"/type 2>/dev/null)" in *gpu*|*devfreq*|*mali*) ;; *) continue ;; esac
			cs_=$(cat "$c"/cur_state 2>/dev/null); [ "${cs_:-0}" -gt "$cpeak" ] && cpeak=$cs_
		done
	fi
	sleep 0.5; i=$((i + 1))
done
b=$(irq)
d=$((b - a))
if [ "$d" -gt 20 ]; then pass "GPU interrupts advanced by $d in 6 s"
elif [ "$d" -gt 0 ]; then info "GPU interrupts advanced only $d: barely used; scroll more and re-run"
else fail "GPU interrupts did not move: nothing is being rendered on the GPU"; fi
[ -n "$dev" ] && info "GPU frequency: ${f0:-?} Hz at start, highest seen ${mx} Hz"
[ -n "$dev" ] && [ "$mx" -gt 384000000 ] 2>/dev/null && pass "devfreq scaled above the lowest OPP" ||
	{ [ -n "$dev" ] && info "devfreq never left the lowest OPP (normal if the UI is light)"; }

echo "== 4. GPU clocks left their 26 MHz reset parent =="
cs=$($S cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'gpu')
if [ -z "$cs" ]; then info "clk_summary not readable (needs root and debugfs)"
else
	printf '%s\n' "$cs" | sed 's/^/      /'
	printf '%s\n' "$cs" | grep -iE 'gpu.*(core|mem)' | awk '{ if ($5+0 > 0 && $5+0 <= 26000000) bad=1 } END{exit bad}' &&
		pass "GPU core/mem clocks run above 26 MHz" || fail "a GPU clock is still at <= 26 MHz (patches 0028/0029 not effective)"
fi

echo "== 5. Faults =="
f=$($S dmesg 2>/dev/null | grep -iE 'panfrost.*(fault|timeout|error|reset)|gpu sched timeout|iommu.* fault' | tail -5)
[ -n "$f" ] && { fail "GPU faults in dmesg:"; printf '%s\n' "$f" | sed 's/^/      /'; } || pass "no GPU faults in dmesg"

echo "== 6. Thermal: the GPU is throttled before it overheats =="
# The board dts gives the SoC's gpu-thermal zone one passive trip (70 C) and binds
# Panfrost's devfreq cooling device to it. This checks that wiring, then what the
# GPU did during section 3. To see throttling itself, keep the GPU loaded for a
# few minutes (a WebGL page or a long video) and re-run: INFO lines below
# report the peak temperature and cooling state seen.
if [ -z "$tz" ]; then
	fail "no thermal zone of type gpu-thermal (the SoC's sensor node is not registered)"
else
	temp=$(cat "$tz"/temp 2>/dev/null)
	info "$(basename "$tz") gpu-thermal: ${temp:-?} m C now, policy $(cat "$tz"/policy 2>/dev/null)"
	trip=; ttype=; n=0
	while [ -e "$tz/trip_point_${n}_temp" ]; do
		tt=$(cat "$tz/trip_point_${n}_type" 2>/dev/null); tv=$(cat "$tz/trip_point_${n}_temp" 2>/dev/null)
		info "trip $n: $tt at $tv m C"
		[ "$tt" = passive ] && [ -z "$trip" ] && { trip=$tv; ttype=$n; }
		n=$((n + 1))
	done
	if [ -n "$trip" ]; then pass "gpu-thermal has a passive trip at $trip m C"
	else fail "gpu-thermal has no passive trip: nothing throttles the GPU (dts gpu-thermal override missing)"; fi
	cd_=
	for c in "$tz"/cdev*; do
		[ -e "$c" ] || continue
		ty=$(cat "$c"/type 2>/dev/null)
		case "$ty" in *gpu*|*devfreq*|*mali*) cd_=$c; info "cooling device: $ty, state $(cat "$c"/cur_state 2>/dev/null) of max $(cat "$(readlink -f "$c")"/max_state 2>/dev/null)" ;; esac
	done
	[ -n "$cd_" ] && pass "a devfreq cooling device is bound to gpu-thermal" ||
		fail "no GPU cooling device bound to gpu-thermal (#cooling-cells missing on the gpu node, or no cooling-maps)"
	info "peak during the 6 s test: ${tpeak} m C, cooling state ${cpeak}"
	if [ -n "$trip" ] && [ "${temp:-0}" -ge "$trip" ] 2>/dev/null; then
		st=$(cat "$cd_"/cur_state 2>/dev/null)
		[ "${st:-0}" -gt 0 ] && pass "over the trip and throttling (cooling state $st)" ||
			fail "over the trip ($temp >= $trip m C) but the cooling state is 0: the GPU is not being throttled"
	else info "below the trip: throttling is not expected yet (load the GPU for a few minutes to see it)"; fi
	[ -n "$dev" ] && info "GPU frequency now: $(cat "$dev"/cur_freq 2>/dev/null) Hz, limit max_freq $(cat "$dev"/max_freq 2>/dev/null) Hz"
fi

echo
if [ "$F" -eq 0 ]; then echo "VERDICT: the GPU is in use ($R checks passed)"
else echo "VERDICT: NOT fully accelerated ($F failed, $R passed): read the FAIL lines above"; fi
