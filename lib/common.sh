#!/usr/bin/env bash
# lib/common.sh - shared helpers for the gpupv toolkit.
#
# Sourced by gpupv.sh only; it defines functions/variables and runs nothing.
# Conventions used everywhere in this repo:
#   * never aggregate a command's exit code through a pipe
#   * a check either prints OK/FAIL on its own line or it does not count
#   * nothing here assumes root; commands that need it say so and stop

GPUPV_VERSION="1.0.0"
GPUPV_KERNEL_RUNNING="$(uname -r)"
# how this file was invoked, so hints read correctly in both the modular tree and
# the single-file build
PROG=$(basename -- "$0" 2>/dev/null || echo gpupv-fnos.sh)

WSL_LIB="${WSL_LIB:-/usr/lib/wsl/lib}"
WSL_DRIVERS="${WSL_DRIVERS:-/usr/lib/wsl/drivers}"
NVSTORE_GLOB="nv_dispi.inf_amd64_*"
CACHE_DIR="${GPUPV_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gpupv}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
	C_CYA=$'\033[36m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
	C_RED=; C_GRN=; C_YEL=; C_CYA=; C_BLD=; C_OFF=
fi

GPUPV_CHECKS=0
GPUPV_FAILS=0
GPUPV_FAILED_LIST=""

say()  { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }
sub()  { printf '\n  %s%s%s\n' "$C_CYA" "$*" "$C_OFF"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  %sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
# --- helpers that must exist without a repo checkout ---------------------
# The single-file build (dist/gpupv-fnos.sh) carries src/* as base64, so the C
# probe and the transfer receiver can be materialised on a machine that only has
# this one file. When a checkout IS present the real file is preferred, so the
# generated script never drifts from src/ during development.
asset_write() {
	local name=$1 dest=$2 var
	case "$name" in
		dxg_probe.c)         var=GPUPV_ASSET_DXG_PROBE_B64 ;;
		http_put_server.py)  var=GPUPV_ASSET_HTTP_PUT_SERVER_B64 ;;
		ldpreload_trace.c)   var=GPUPV_ASSET_LDPRELOAD_TRACE_B64 ;;
		abi_gates.sh)        var=GPUPV_ASSET_ABI_GATES_B64 ;;
		*) return 1 ;;
	esac
	if [ -f "$SELF_DIR/src/$name" ]; then
		cp -a "$SELF_DIR/src/$name" "$dest"
		return 0
	fi
	local b64=""
	eval "b64=\${$var:-}"
	[ -n "$b64" ] || return 1
	printf '%s' "$b64" | base64 -d > "$dest" || return 1
	return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# Run the offline ABI gates on a .ko. In a checkout the real file is used; in the
# single-file build it is materialised from the embedded copy. Keeping one entry
# point means callers never care which layout they run in.
abi_gates_run() {
	local ko=$1 other=${2:-}
	if [ -f "$SELF_DIR/lib/abi_gates.sh" ]; then
		if [ -n "$other" ]; then
			bash "$SELF_DIR/lib/abi_gates.sh" "$ko" "$other"
		else
			bash "$SELF_DIR/lib/abi_gates.sh" "$ko"
		fi
		return
	fi
	local tmp
	tmp=$(mktemp "${TMPDIR:-/tmp}/gpupv-abi.XXXXXX.sh") || return 1
	asset_write abi_gates.sh "$tmp" || return 1
	if [ -n "$other" ]; then
		bash "$tmp" "$ko" "$other"
	else
		bash "$tmp" "$ko"
	fi
	local rc=$?
	rm -f "$tmp"
	return $rc
}

mark_ok() {
	GPUPV_CHECKS=$((GPUPV_CHECKS + 1))
	printf '  %s OK %s  %s\n' "$C_GRN" "$C_OFF" "$1"
}

mark_fail() {
	GPUPV_CHECKS=$((GPUPV_CHECKS + 1))
	GPUPV_FAILS=$((GPUPV_FAILS + 1))
	GPUPV_FAILED_LIST="${GPUPV_FAILED_LIST}${1}"$'\n'
	if [ -n "${2:-}" ]; then
		printf '  %sFAIL%s  %s (%s)\n' "$C_RED" "$C_OFF" "$1" "$2"
	else
		printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$1"
	fi
}

# Reset the tallies so a phase's summary describes THAT phase. Without this,
# 'setup' (which runs several sub-commands) reports the running total and a
# successful run ends with "gates: 15 checks, 4 failed" from steps that were
# fixed or skipped earlier.
checks_reset() {
	GPUPV_CHECKS=0
	GPUPV_FAILS=0
	GPUPV_FAILED_LIST=""
}

# mark <rc> <description> [detail]
mark() {
	if [ "$1" -eq 0 ]; then mark_ok "$2"; else mark_fail "$2" "${3:-rc=$1}"; fi
}

is_root() { [ "$(id -u)" -eq 0 ]; }

need_root() {
	is_root && return 0
	if [ $# -gt 0 ]; then
		die "this needs root: sudo $PROG $*"
	fi
	die "this needs root: re-run the same command with sudo"
}

kver() { uname -r; }

# --- DriverStore location -------------------------------------------------
# The <hash> segment changes with every NVIDIA driver update, so it is never
# hard-coded: resolve it, and refuse to guess when there is more than one.
ds_dirs() {
	local d
	for d in "$WSL_DRIVERS"/$NVSTORE_GLOB; do
		[ -d "$d" ] && printf '%s\n' "$d"
	done
}

ds_pick() {
	local -a c=()
	local d
	while IFS= read -r d; do c+=("$d"); done < <(ds_dirs)
	if [ "${#c[@]}" -eq 0 ]; then return 1; fi
	if [ "${#c[@]}" -gt 1 ]; then
		warn "more than one DriverStore folder - pass --driverstore explicitly:" >&2
		printf '        %s\n' "${c[@]}" >&2
		return 1
	fi
	printf '%s\n' "${c[0]}"
}

count_entries() { [ -d "$1" ] && ls -1 "$1" 2>/dev/null | wc -l || echo 0; }
count_nonso()   { [ -d "$1" ] && ls -1 "$1" 2>/dev/null | grep -vc '\.so' || echo 0; }

# A trimmed DriverStore (a hand-picked .so subset) is the single most common
# cause of "NVML green, cuInit segfaults". Two counts settle it.
ds_verdict() {
	local d=$1 n ns
	n=$(count_entries "$d"); ns=$(count_nonso "$d")
	printf '%s files, %s non-.so' "$n" "$ns"
	if [ "$n" -lt 20 ] || [ "$ns" -eq 0 ]; then
		printf ' <- TRIMMED (this is your bug before anything else)\n'
		return 1
	fi
	printf ' <- complete\n'
	return 0
}

nvstore_keyfiles() {
	local d=$1 f
	for f in nvinfo.pb nvapi64.dll nvml.dll nvEncodeAPI64.dll libcuda.so.1.1 libnvidia-ml.so.1; do
		if [ -e "$d/$f" ]; then
			printf '  present %-24s %s bytes\n' "$f" "$(stat -c%s "$d/$f" 2>/dev/null)"
		else
			printf '  MISSING %s\n' "$f"
		fi
	done
}

# --- misc probes ----------------------------------------------------------
# Locate the uapi d3dkmthk.h of the source tree the running module was built
# from. Depths vary ( /usr/src/dxgkrnl-<hash>/include/uapi/misc/ = 5 levels ),
# so a fixed -maxdepth silently finds nothing and the ABI gate gets skipped.
find_uapi_header() {
	local p
	for p in $(find /usr/src -maxdepth 6 -path '*uapi/misc/d3dkmthk.h' 2>/dev/null); do
		printf '%s\n' "$p"
		return 0
	done
	[ -f "$CACHE_DIR/uapi/d3dkmthk.h" ] && { printf '%s\n' "$CACHE_DIR/uapi/d3dkmthk.h"; return 0; }
	return 1
}

ffmpeg_pick() {
	local c
	for c in "${FFMPEG:-}" /usr/bin/ffmpeg /usr/local/bin/ffmpeg \
	         /usr/trim/lib/mediasrv/ffmpeg; do
		[ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
	done
	command -v ffmpeg 2>/dev/null
}

nvidia_smi() {
	if [ -x /usr/bin/nvidia-smi ]; then
		printf '%s\n' /usr/bin/nvidia-smi
	else
		command -v nvidia-smi 2>/dev/null
	fi
}

# nvidia-smi has three distinct failure messages on three different layers.
# Naming the layer is the whole point: chasing libs with the wrong message
# wastes hours.
# resolve a relative symlink target to its basename (vmbus driver links are
# relative paths like ../../../../bus/vmbus/drivers/dxgkrnl)
drv_name() { local d; d=$(readlink "$1" 2>/dev/null) || { echo none; return; }; echo "${d##*/}"; }

classify_nvml() {
	case "$1" in
		*"GPU access blocked by the operating system"*) echo "dxg-adapter (no /dev/dxg, or no adapter started)" ;;
		*"couldn't communicate with the NVIDIA driver"*) echo "wsl-lib (dxg works, userland payload wrong/misplaced)" ;;
		*"Failed to initialize NVML"*) echo "module (dxgkrnl never loaded)" ;;
		*"No devices were found"*) echo "adapter (module loaded, host offered no partition)" ;;
		*) echo "answered" ;;
	esac
}

# --- network --------------------------------------------------------------
lan_ip() {
	ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# --- http ----------------------------------------------------------------
fetch() {
	have curl || die "curl is required"
	curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || return 1
}

# --- summary -------------------------------------------------------------
summary() {
	local label=${1:-gates}
	printf '\n%s==== %s: %d checks, %d failed ====%s\n' \
		"$C_BLD" "$label" "$GPUPV_CHECKS" "$GPUPV_FAILS" "$C_OFF"
	if [ "$GPUPV_FAILS" -gt 0 ]; then
		printf 'failed:\n%s' "$(printf '%s' "$GPUPV_FAILED_LIST" | sed 's/^/  - /')"
	fi
	return "$GPUPV_FAILS"
}
