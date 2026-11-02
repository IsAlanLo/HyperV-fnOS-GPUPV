#!/usr/bin/env bash
# lib/verify.sh - functional gates, in the only order that means anything.
#
# Gate order matters: an earlier gate failing makes every later gate's result
# meaningless, and a green NVML with a dead cuInit is the classic
# "looks fixed, isn't" on this stack.

# --- gate: cuInit / device identity ---------------------------------------
_cuda_probe_py() {
	cat <<'PY'
import ctypes, sys, os
lib = None
for cand in ("/usr/lib/wsl/lib/libcuda.so.1", "libcuda.so.1", "libcuda.so"):
    try:
        lib = ctypes.CDLL(cand)
        break
    except OSError:
        continue
if lib is None:
    print("  libcuda not loadable")
    sys.exit(1)
rc = lib.cuInit(0)
print("  cuInit              =", rc)
if rc != 0:
    print("  (100 = CUDA_ERROR_NO_DEVICE, 999 = unknown/segfault-adjacent)")
    sys.exit(1)
n = ctypes.c_int()
lib.cuDeviceGetCount(ctypes.byref(n))
print("  cuDeviceGetCount    =", n.value)
if n.value < 1:
    sys.exit(1)
d = ctypes.c_int()
lib.cuDeviceGet(ctypes.byref(d), 0)
buf = ctypes.create_string_buffer(128)
lib.cuDeviceGetName(buf, 128, d)
print("  cuDeviceGetName     =", buf.value.decode(errors="replace"))
mem = ctypes.c_size_t()
for fn in ("cuDeviceTotalMem_v2", "cuDeviceTotalMem"):
    if hasattr(lib, fn):
        getattr(lib, fn)(ctypes.byref(mem), d)
        break
print("  cuDeviceTotalMem    =", mem.value // 1048576, "MiB")
ver = ctypes.c_int()
lib.cuDriverGetVersion(ctypes.byref(ver))
print("  cuDriverGetVersion  =", ver.value)
PY
}

# --- gate: nvenc / cuvid matrix ------------------------------------------
_codec_matrix() {
	local ff=$1 src out c rc sz
	local enc_ok=0 dec_ok=0
	local tmpd
	tmpd=$(mktemp -d "${TMPDIR:-/tmp}/gpupv.XXXXXX") || return 1

	sub "encode"
	for c in h264_nvenc hevc_nvenc; do
		out="$tmpd/$c.mp4"
		"$ff" -hide_banner -loglevel error -nostdin \
			-f lavfi -i testsrc2=size=1920x1080:rate=30:duration=5 \
			-c:v "$c" -preset p4 -y "$out" >"$tmpd/$c.log" 2>&1
		rc=$?
		sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
		if [ "$rc" -eq 0 ] && [ "$sz" -gt 10000 ]; then
			mark_ok "$c encoded ($sz bytes)"
			enc_ok=$((enc_ok + 1))
		else
			mark_fail "$c encode" "rc=$rc size=$sz $(head -c 160 "$tmpd/$c.log" | tr '\n' ' ')"
		fi
	done

	# av1_nvenc is silicon, not stack, on GA104-class cards (3060Ti/3070/3080).
	if "$ff" -hide_banner -h encoder=av1_nvenc >/dev/null 2>&1; then
		out="$tmpd/av1.mp4"
		"$ff" -hide_banner -loglevel error -nostdin \
			-f lavfi -i testsrc2=size=1920x1080:rate=30:duration=2 \
			-c:v av1_nvenc -preset p4 -y "$out" >"$tmpd/av1.log" 2>&1
		rc=$?
		if [ "$rc" -eq 0 ] && [ "$(stat -c%s "$out" 2>/dev/null || echo 0)" -gt 10000 ]; then
			mark_ok "av1_nvenc encoded (Turing/Ada or newer - this GPU has an AV1 encoder)"
		else
			warn "av1_nvenc unavailable - GA104-class silicon cannot encode AV1; not a stack fault"
		fi
	fi

	sub "decode"
	for pair in "h264_nvenc:h264_cuvid" "hevc_nvenc:hevc_cuvid"; do
		src=${pair%%:*}; c=${pair##*:}
		[ -s "$tmpd/$src.mp4" ] || { note "skip $c (no $src output to decode)"; continue; }
		"$ff" -hide_banner -loglevel error -nostdin \
			-c:v "$c" -i "$tmpd/$src.mp4" -f null - >"$tmpd/$c.log" 2>&1
		rc=$?
		if [ "$rc" -eq 0 ]; then mark_ok "$c decoded"; dec_ok=$((dec_ok + 1)); else
			mark_fail "$c decode" "rc=$rc $(head -c 160 "$tmpd/$c.log" | tr '\n' ' ')"
		fi
	done
	# AV1 decode is present on GA104; test it on a synthetic AV1 file if ffmpeg can make one.
	if "$ff" -hide_banner -encoders 2>/dev/null | grep -q libaom-av1; then
		: # encoding AV1 in software to test av1_cuvid is slow; not worth the runtime
	fi
	printf '  %s(nvenc %d/2, cuvid %d/2)%s\n' "$C_CYA" "$enc_ok" "$dec_ok" "$C_OFF"
	rm -rf "$tmpd"
}

cmd_verify() {
	local quick=0 ff smi out rc
	[ "${1:-}" = "--quick" ] && quick=1

	say "gate 1/5: module and device node"
	if lsmod 2>/dev/null | grep -q '^dxgkrnl'; then mark_ok "dxgkrnl loaded"; else mark_fail "dxgkrnl loaded"; fi
	if [ -e /dev/dxg ]; then mark_ok "/dev/dxg present"; else mark_fail "/dev/dxg present"; fi
	local boundary=0
	for d in /sys/bus/vmbus/devices/*/; do
		[ -d "$d" ] || continue
		case "$(cat "$d/class_id" 2>/dev/null)" in
			*6e382d18*|*dde9cbc0*)
				boundary=$((boundary + 1))
				[ -e "$d/driver" ] || mark_fail "dxg channel $(basename "$d") has no driver bound";;
		esac
	done
	[ "$boundary" -ge 2 ] && mark_ok "both dxg VMBus channels bound" || mark_fail "dxg VMBus channels" "found $boundary"
	if [ "$GPUPV_FAILS" -gt 0 ]; then
		note "kernel path is not up; later gates cannot pass. Run: $PROG triage"
		summary "gates"; return $?
	fi

	say "gate 2/5: userland payload shape"
	local ds
	if ds=$(ds_pick); then
		local n ns
		n=$(count_entries "$ds"); ns=$(count_nonso "$ds")
		note "$ds: $n files, $ns non-.so"
		if [ "$n" -ge 150 ] && [ "$ns" -gt 0 ]; then
			mark_ok "driverstore complete"
		else
			mark_fail "driverstore trimmed" "expected ~153 files with metadata; see: $PROG driverstore install"
		fi
	else
		mark_fail "no DriverStore directory found" "$WSL_DRIVERS/$NVSTORE_GLOB"
	fi

	say "gate 3/5: NVML (monitoring path only)"
	smi=$(nvidia_smi)
	if [ -n "$smi" ]; then
		out=$("$smi" --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1); rc=$?
		printf '%s\n' "$out" | sed 's/^/  /'
		if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi 'failed\|blocked\|no devices'; then
			mark_ok "nvidia-smi answered (layer 2 of 4 - not success)"
		else
			mark_fail "nvidia-smi" "layer: $(classify_nvml "$out")"
		fi
	else
		mark_fail "nvidia-smi not found"
	fi

	say "gate 4/5: CUDA (first real gate)"
	local py rc
	py=$(mktemp "${TMPDIR:-/tmp}/gpupv-cuda.XXXXXX.py")
	_cuda_probe_py > "$py"
	python3 "$py"; rc=$?
	rm -f "$py"
	mark "$rc" "cuInit 0 with >=1 device"

	say "gate 5/5: real consumer (NVENC / CUVID)"
	if [ "$quick" -eq 1 ]; then
		note "skipped (--quick)"
	else
		ff=$(ffmpeg_pick)
		if [ -z "$ff" ]; then
			mark_fail "ffmpeg not found" "- set FFMPEG=/path/to/ffmpeg"
		else
			note "ffmpeg: $ff"
			note "$("$ff" -version 2>/dev/null | head -1)"
			# A bundled static 9.x build reports "nvenc API 13.1 vs 13.0" on a
			# perfectly healthy stack: ffmpeg newer than the driver, not GPU-PV.
			_codec_matrix "$ff"
		fi
	fi

	summary "gates"
	local r=$?
	if [ "$r" -eq 0 ]; then
		printf '\n%sGPU-PV is functional: module -> partition -> CUDA -> codecs.%s\n' "$C_GRN" "$C_OFF"
		printf 'AV1 note: av1_nvenc failing on GA104-class cards (3060Ti/3070/3080) is silicon.\n'
	else
		printf '\n%sNot functional. Do not report success from nvidia-smi alone.%s\n' "$C_YEL" "$C_OFF"
	fi
	return "$r"
}

# --- probe: build and run the /dev/dxg probe -----------------------------
cmd_probe() {
	local tmpd
	tmpd=$(mktemp -d "${TMPDIR:-/tmp}/gpupv-probe.XXXXXX") || die "mktemp failed"
	local src="$tmpd/dxg_probe.c"
	asset_write dxg_probe.c "$src" || die "cannot materialise src/dxg_probe.c (rebuild with tools/build-single.sh)"
	local inc out bin
	local -a incs=()
	for inc in /usr/src/dxgkrnl-*/include/uapi/misc; do
		[ -f "$inc/d3dkmthk.h" ] && incs+=("-I$inc")
	done
	if [ "${#incs[@]}" -eq 0 ]; then
		# no local source tree: try to fetch the uapi header
		local cache="$CACHE_DIR/uapi"
		mkdir -p "$cache"
		fetch "https://raw.githubusercontent.com/microsoft/WSL2-Linux-Kernel/linux-msft-wsl-6.18.y/include/uapi/misc/d3dkmthk.h" "$cache/d3dkmthk.h" \
			|| die "cannot find or fetch uapi d3dkmthk.h (run: $PROG module build)"
		incs+=("-I$cache")
	fi
	have gcc || die "gcc not found"
	bin=$(mktemp "${TMPDIR:-/tmp}/dxg_probe.XXXXXX") || die "mktemp failed"
	# shellcheck disable=SC2068
	if ! gcc -O0 -o "$bin" "$src" "${incs[@]}" -I"$SELF_DIR/src" 2>"$bin.log"; then
		sed 's/^/  /' "$bin.log"; rm -f "$bin" "$bin.log"
		die "probe did not compile"
	fi
	rm -f "$bin.log"
	out=$("$bin" 2>&1); local rc=$?
	printf '%s\n' "$out" | sed 's/^/  /'
	rm -rf "$tmpd" 
	say "verdict"
	case "$rc" in
		0) note "kernel path OK: module -> VMBus channel -> host partition all live."
		   note "if CUDA still fails, the fault is userland ($WSL_DRIVERS payload) - run: $PROG verify" ;;
		1) note "no /dev/dxg: module not loaded ($PROG triage, then module build)" ;;
		2) note "no adapter started: host offered no usable partition (see host/gpupv-host.ps1)" ;;
		3) note "adapter enumerated but would not open: DXCore-level failure, usually the module build branch" ;;
		*) note "unexpected exit $rc" ;;
	esac
	return "$rc"
}
