#!/usr/bin/env bash
# gpupv-fnos.sh - Hyper-V GPU-PV (GPU partitioning) tool for the Linux guest.
#
# The whole job, in the order it is usually needed:
#   deps         the build toolchain (a stock fnOS has make but NO gcc)
#   triage       root-free: which layer is broken (guest / kernel / userland / host)
#   verify       functional gates: /dev/dxg -> DriverStore -> NVML -> CUDA -> NVENC/CUVID
#   doctor       deeper: offline module ABI gates, DriverStore hash diff, LD_DEBUG trace
#   module       fetch + build dxgkrnl for THIS kernel, verify, install, restore
#   driverstore  compare / install / roll back the host's nv_dispi folder
#   service      boot loader + self-test units
#   receive      HTTP PUT receiver (when the Windows host has no SSH path)
#   report       markdown evidence file
#
# Design rules this tool follows, because breaking them cost days of wrong answers:
#   * NVML printing a table is NOT success; cuInit is the first real gate.
#   * a deploy script's "SUCCESS" line proves nothing (they are full of `|| true`).
#   * count files before theorising about mechanisms.
#   * never hard-code a kernel string, a driver version or a DriverStore <hash>.
#   * a missing dependency is reported as a missing dependency, not as a build
#     failure: fnOS ships make without gcc, and kbuild only says "Error 127".
#
# Host side lives in gpupv-windows.ps1 (Windows PowerShell).
set -u

# ---------------------------------------------------------------------
# GENERATED FILE - do not edit. Source of truth: gpupv.sh + lib/*.sh.
# Rebuild with:  bash tools/build-single.sh
# ---------------------------------------------------------------------

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)


# ====================== lib/common.sh ======================
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
	local b64
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

# ====================== lib/assets.sh ======================
# GENERATED by tools/build-assets.sh from src/* and lib/abi_gates.sh - do not edit.
# Base64 payloads let the single-file build (gpupv-fnos.sh) materialise the
# helper files it needs without a repo checkout.

GPUPV_ASSET_DXG_PROBE_B64='LyoKICogZHhnX3Byb2JlLmMgLSBwcm92ZSB0aGUgR1BVLVBWIGtlcm5lbCBwYXRoIHdpdGhvdXQgcm9vdCBhbmQgd2l0aG91dCBudmlkaWEtc21pLgogKgogKiBCdWlsZDogZ2NjIC1PMCAtbyAvdG1wL2R4Z19wcm9iZSBkeGdfcHJvYmUuYyAtSTxkeGdrcm5sIHNvdXJjZSB0cmVlPi9pbmNsdWRlL3VhcGkvbWlzYwogKiAgICAgICAgKHRoZSB0cmVlIHBhdGggaXMgIC91c3Ivc3JjL2R4Z2tybmwtPGhhc2g+ICAtIHNlZSBncHVwdi5zaCBwcm9iZSkKICogUnVuOiAgIC90bXAvZHhnX3Byb2JlICAgICAgICAgICAgKGFueSB1c2VyOiAvZGV2L2R4ZyBpcyBtb2RlIDA2NjYpCiAqCiAqIFdoeTogb25jZSBkeGdrcm5sIGxvYWRzLCBudmlkaWEtc21pIGNhbm5vdCB0ZWxsIHlvdSB3aGV0aGVyIHRoZSBmYWlsdXJlIGlzCiAqIHRoZSBrZXJuZWwvaG9zdCBsaW5rLCB0aGUgRFhDb3JlIGxheWVyLCBvciB0aGUgdXNlcmxhbmQgcGF5bG9hZCB1bmRlcgogKiAvdXNyL2xpYi93c2wvZHJpdmVycy4KICoKICogUmVhZHMsIGluIG9yZGVyIG9mIHdoYXQgdGhleSBwcm92ZToKICogICBlbnVtMi9lbnVtMyBjb3VudCA+PSAxLCBvcGVuX2FkYXB0ZXIgcmV0PTAKICogICAgICAgbW9kdWxlIC0+IFZNQnVzIGNoYW5uZWwgLT4gaG9zdCBHUFUgcGFydGl0aW9uIGFyZSBhbGwgbGl2ZS4gRnJvbSBoZXJlCiAqICAgICAgIGEgQ1VEQS9OVk1MIGZhaWx1cmUgY2FuIG9ubHkgYmUgdXNlcmxhbmQtc2lkZTsgc3RvcCB0b3VjaGluZyB0aGUga2VybmVsLgogKiAgIFFVRVJZQURBUFRFUklORk8gdHlwZSAxNSAvIDU3ICAoQURBUFRFUlRZUEUgLyBBREFQVEVSVFlQRV9SRU5ERVIpCiAqICAgICAgIHZhbHVlIDB4ODEgPSByZW5kZXIgKyBwYXJhdmlydHVhbCwgaS5lLiBhIHJlYWwgcGFyYXZpcnR1YWwgcmVuZGVyIGRldmljZS4KICogICBRVUVSWUFEQVBURVJJTkZPIHR5cGUgMCAgKF9LTVRRQUlUWVBFX1VNRFJJVkVSUFJJVkFURSkKICogICAgICAgSG93IGxpYmR4Y29yZSBhc2tzIGZvciB0aGUgYWRhcHRlcidzIHByaXZhdGUgZGVzY3JpcHRpb24gKGRyaXZlci1zdG9yZQogKiAgICAgICBwYXRoIGFuZCBmcmllbmRzKS4gSXQgaXMgU0laRS1TRU5TSVRJVkU6IHRoZSBob3N0IG9ubHkgYW5zd2VycyB0aGUKICogICAgICAgZXhhY3Qgc3RydWN0dXJlIHNpemUgdGhlIGNhbGxlciB1c2VzIChsaWJjdWRhIHNlbmRzIH45MzA4IGFuZCB+NDk1NTkKICogICAgICAgYnl0ZXMgYW5kIGdldHMgYSBidWZmZXIgc3RhcnRpbmcgd2l0aCB0aGUgQVNDSUkgbWFnaWMgIk5WREEiID0KICogICAgICAgMHg0ZTU2NDQ0MSkuIEFueSBvdGhlciBzaXplIHJldHVybnMgRUlOVkFMLCBzbyBFSU5WQUwgaW4gdGhlIHR3byBwcm9iZXMKICogICAgICAgYmVsb3cgaXMgZXhwZWN0ZWQgYW5kIHByb3ZlcyBub3RoaW5nIGFib3V0IERYQ29yZSBvciB0aGUgaG9zdCDigJQgZG8gbm90CiAqICAgICAgIHJlYWQgaXQgYXMgInRoZSBicmFuY2ggaXMgd3JvbmciLgogKgogKiBVc2VzIHRoZSBtb2R1bGUncyBvd24gdWFwaSBoZWFkZXIgb24gcHVycG9zZSAoc3RydWN0IGxheW91dHMgYW5kIExYX0RYKiBpb2N0bAogKiBudW1iZXJzIGNvbWUgZnJvbSBkeGdrcm5sIGl0c2VsZiksIHNvIHRoZSBwcm9iZSBzdGF5cyBpbiBzeW5jIHdpdGggd2hhdGV2ZXIKICogbW9kdWxlIHRoZSBndWVzdCBoYXBwZW5zIHRvIGJlIHJ1bm5pbmcuCiAqLwojaW5jbHVkZSA8c3RkaW8uaD4KI2luY2x1ZGUgPHN0ZGludC5oPgojaW5jbHVkZSA8c3RkbGliLmg+CiNpbmNsdWRlIDxzdHJpbmcuaD4KI2luY2x1ZGUgPGZjbnRsLmg+CiNpbmNsdWRlIDxlcnJuby5oPgojaW5jbHVkZSA8dW5pc3RkLmg+CiNpbmNsdWRlIDxzeXMvaW9jdGwuaD4KI2luY2x1ZGUgPGxpbnV4L3R5cGVzLmg+CgojaW5jbHVkZSAiZDNka210aGsuaCIKCnN0YXRpYyB2b2lkIGR1bXBfdHlwZShjb25zdCBjaGFyICp0YWcsIGNvbnN0IHN0cnVjdCBkM2RrbXRfYWRhcHRlcnR5cGUgKnQpCnsKCXByaW50ZigiJXMgdmFsdWU9MHglMDh4IHJlbmRlcj0ldSBkaXNwbGF5PSV1IHNvZnR3YXJlPSV1IHBhcmF2aXJ0PSV1ICIKCSAgICAgICAiY29tcHV0ZV9vbmx5PSV1IHByb3RvdHlwZT0ldVxuIiwgdGFnLCB0LT52YWx1ZSwKCSAgICAgICB0LT5yZW5kZXJfc3VwcG9ydGVkLCB0LT5kaXNwbGF5X3N1cHBvcnRlZCwgdC0+c29mdHdhcmVfZGV2aWNlLAoJICAgICAgIHQtPnBhcmF2aXJ0dWFsaXplZCwgdC0+Y29tcHV0ZV9vbmx5LCB0LT5wcm90b3R5cGUpOwp9CgppbnQgbWFpbih2b2lkKQp7CglpbnQgZmQgPSBvcGVuKCIvZGV2L2R4ZyIsIE9fUkRXUik7CglpZiAoZmQgPCAwKSB7CgkJcHJpbnRmKCJvcGVuIC9kZXYvZHhnIGZhaWxlZDogJXNcbiIsIHN0cmVycm9yKGVycm5vKSk7CgkJcHJpbnRmKCJSRVNVTFQ6IG1vZHVsZSBub3QgbG9hZGVkIG9yIG5vIGFkYXB0ZXIgLSBzZWUgc2tpbGwgc2VjdGlvbnMgMi8zLzVcbiIpOwoJCXJldHVybiAxOwoJfQoKCXN0cnVjdCBkM2RrbXRfYWRhcHRlcmluZm8gaW5mb1tEM0RLTVRfQURBUFRFUlNfTUFYXTsKCXN0cnVjdCBkM2RrbXRfZW51bWFkYXB0ZXJzMiBlYTsKCW1lbXNldChpbmZvLCAwLCBzaXplb2YoaW5mbykpOwoJbWVtc2V0KCZlYSwgMCwgc2l6ZW9mKGVhKSk7CgllYS5udW1fYWRhcHRlcnMgPSBEM0RLTVRfQURBUFRFUlNfTUFYOwoJZWEuYWRhcHRlcnMgPSAoX191NjQgKilpbmZvOwoKCWludCByZXQgPSBpb2N0bChmZCwgTFhfRFhFTlVNQURBUFRFUlMyLCAmZWEpOwoJcHJpbnRmKCJlbnVtX2FkYXB0ZXJzIHJldD0lZCBlcnJubz0lcyBudW1fYWRhcHRlcnM9JXVcbiIsCgkgICAgICAgcmV0LCByZXQgPyBzdHJlcnJvcihlcnJubykgOiAiLSIsIGVhLm51bV9hZGFwdGVycyk7CglpZiAocmV0IHx8ICFlYS5udW1fYWRhcHRlcnMpIHsKCQlwcmludGYoIlJFU1VMVDogbm8gYWRhcHRlciBzdGFydGVkIChrZXJuZWwvaG9zdCBzaWRlKVxuIik7CgkJY2xvc2UoZmQpOwoJCXJldHVybiAyOwoJfQoKCWZvciAodW5zaWduZWQgaSA9IDA7IGkgPCBlYS5udW1fYWRhcHRlcnMgJiYgaSA8IEQzREtNVF9BREFQVEVSU19NQVg7IGkrKykKCQlwcmludGYoIiAgYWRhcHRlclsldV0gaGFuZGxlPSUwOHggbHVpZD0lMDh4LSUwOHggbnVtX3NvdXJjZXM9JXVcbiIsCgkJICAgICAgIGksIGluZm9baV0uYWRhcHRlcl9oYW5kbGUudiwKCQkgICAgICAgaW5mb1tpXS5hZGFwdGVyX2x1aWQuYSwgaW5mb1tpXS5hZGFwdGVyX2x1aWQuYiwKCQkgICAgICAgaW5mb1tpXS5udW1fc291cmNlcyk7CgoJLyogTmV3ZXIgRFhDb3JlIC8gbGliY3VkYSBlbnVtZXJhdGUgdGhyb3VnaCB0aGUgZmlsdGVyZWQgdmFyaWFudCB0b28uICovCglzdHJ1Y3QgZDNka210X2FkYXB0ZXJpbmZvIGkzW0QzREtNVF9BREFQVEVSU19NQVhdOwoJc3RydWN0IGQzZGttdF9lbnVtYWRhcHRlcnMzIGUzOwoJbWVtc2V0KGkzLCAwLCBzaXplb2YoaTMpKTsKCW1lbXNldCgmZTMsIDAsIHNpemVvZihlMykpOwoJZTMuYWRhcHRlcl9jb3VudCA9IEQzREtNVF9BREFQVEVSU19NQVg7CgllMy5hZGFwdGVycyA9IChfX3U2NClpMzsKCWUzLmZpbHRlci52YWx1ZSA9IDA7CglpbnQgcjMgPSBpb2N0bChmZCwgTFhfRFhFTlVNQURBUFRFUlMzLCAmZTMpOwoJcHJpbnRmKCJlbnVtX2FkYXB0ZXJzMyByZXQ9JWQgZXJybm89JXMgY291bnQ9JXVcbiIsCgkgICAgICAgcjMsIHIzID8gc3RyZXJyb3IoZXJybm8pIDogIi0iLCBlMy5hZGFwdGVyX2NvdW50KTsKCglzdHJ1Y3QgZDNka210X29wZW5hZGFwdGVyZnJvbWx1aWQgb2E7CgltZW1zZXQoJm9hLCAwLCBzaXplb2Yob2EpKTsKCW9hLmFkYXB0ZXJfbHVpZCA9IGluZm9bMF0uYWRhcHRlcl9sdWlkOwoKCXJldCA9IGlvY3RsKGZkLCBMWF9EWE9QRU5BREFQVEVSRlJPTUxVSUQsICZvYSk7CglwcmludGYoIm9wZW5fYWRhcHRlciByZXQ9JWQgZXJybm89JXMgaGFuZGxlPSUwOHhcbiIsCgkgICAgICAgcmV0LCByZXQgPyBzdHJlcnJvcihlcnJubykgOiAiLSIsIG9hLmFkYXB0ZXJfaGFuZGxlLnYpOwoJaWYgKHJldCkgewoJCWNsb3NlKGZkKTsKCQlyZXR1cm4gMzsKCX0KCgljb25zdCBlbnVtIGttdHF1ZXJ5YWRhcHRlcmluZm90eXBlIHR5cGVzW10gPSB7CgkJX0tNVFFBSVRZUEVfQURBUFRFUlRZUEUsCgkJX0tNVFFBSVRZUEVfQURBUFRFUlRZUEVfUkVOREVSLAoJfTsKCWZvciAodW5zaWduZWQgaSA9IDA7IGkgPCBzaXplb2YodHlwZXMpIC8gc2l6ZW9mKHR5cGVzWzBdKTsgaSsrKSB7CgkJc3RydWN0IGQzZGttdF9hZGFwdGVydHlwZSBhdDsKCQlzdHJ1Y3QgZDNka210X3F1ZXJ5YWRhcHRlcmluZm8gcTsKCQltZW1zZXQoJmF0LCAwLCBzaXplb2YoYXQpKTsKCQltZW1zZXQoJnEsIDAsIHNpemVvZihxKSk7CgkJcS5hZGFwdGVyID0gb2EuYWRhcHRlcl9oYW5kbGU7CgkJcS50eXBlID0gdHlwZXNbaV07CgkJcS5wcml2YXRlX2RhdGEgPSAoX191NjQpJmF0OwoJCXEucHJpdmF0ZV9kYXRhX3NpemUgPSBzaXplb2YoYXQpOwoJCWVycm5vID0gMDsKCQlpbnQgciA9IGlvY3RsKGZkLCBMWF9EWFFVRVJZQURBUFRFUklORk8sICZxKTsKCQlpZiAocikgewoJCQlwcmludGYoInF1ZXJ5IHR5cGU9JWQgcmV0PSVkIGVycm5vPSVzXG4iLCB0eXBlc1tpXSwgciwKCQkJICAgICAgIHN0cmVycm9yKGVycm5vKSk7CgkJCWNvbnRpbnVlOwoJCX0KCQljaGFyIHRhZ1szMl07CgkJc25wcmludGYodGFnLCBzaXplb2YodGFnKSwgInF1ZXJ5IHR5cGU9JWQ6IiwgdHlwZXNbaV0pOwoJCWR1bXBfdHlwZSh0YWcsICZhdCk7Cgl9CgoJc2l6ZV90IHNpemVzW10gPSB7IDQwOTYsIDY1NTM2IH07Cglmb3IgKHVuc2lnbmVkIGkgPSAwOyBpIDwgc2l6ZW9mKHNpemVzKSAvIHNpemVvZihzaXplc1swXSk7IGkrKykgewoJCXZvaWQgKmJ1ZiA9IGNhbGxvYygxLCBzaXplc1tpXSk7CgkJc3RydWN0IGQzZGttdF9xdWVyeWFkYXB0ZXJpbmZvIHE7CgkJbWVtc2V0KCZxLCAwLCBzaXplb2YocSkpOwoJCXEuYWRhcHRlciA9IG9hLmFkYXB0ZXJfaGFuZGxlOwoJCXEudHlwZSA9IF9LTVRRQUlUWVBFX1VNRFJJVkVSUFJJVkFURTsKCQlxLnByaXZhdGVfZGF0YSA9IChfX3U2NClidWY7CgkJcS5wcml2YXRlX2RhdGFfc2l6ZSA9IHNpemVzW2ldOwoJCWVycm5vID0gMDsKCQlpbnQgciA9IGlvY3RsKGZkLCBMWF9EWFFVRVJZQURBUFRFUklORk8sICZxKTsKCQlwcmludGYoInF1ZXJ5IFVNRFJJVkVSUFJJVkFURSBzaXplPSUtNnp1IHJldD0lZCBlcnJubz0lcyIKCQkgICAgICAgIiVzIiwKCQkgICAgICAgc2l6ZXNbaV0sIHIsIHIgPyBzdHJlcnJvcihlcnJubykgOiAiLSIsCgkJICAgICAgIHIgPyAiICAoRUlOVkFMID0gd3Jvbmcgc2l6ZTsgbm90IGEgZmF1bHQpIiA6ICIiKTsKCQlpZiAoIXIpCgkJCXByaW50ZigiIHVzZWQ9JXUgZmlyc3Q0PSUwMnglMDJ4JTAyeCUwMngiLCBxLnByaXZhdGVfZGF0YV9zaXplLAoJCQkgICAgICAgKCh1bnNpZ25lZCBjaGFyICopYnVmKVswXSwgKCh1bnNpZ25lZCBjaGFyICopYnVmKVsxXSwKCQkJICAgICAgICgodW5zaWduZWQgY2hhciAqKWJ1ZilbMl0sICgodW5zaWduZWQgY2hhciAqKWJ1ZilbM10pOwoJCXByaW50ZigiXG4iKTsKCQlmcmVlKGJ1Zik7Cgl9CgoJc3RydWN0IGQzZGttdF9jbG9zZWFkYXB0ZXIgY2E7CgltZW1zZXQoJmNhLCAwLCBzaXplb2YoY2EpKTsKCWNhLmFkYXB0ZXJfaGFuZGxlID0gb2EuYWRhcHRlcl9oYW5kbGU7CglpbnQgcmMgPSBpb2N0bChmZCwgTFhfRFhDTE9TRUFEQVBURVIsICZjYSk7CglwcmludGYoImNsb3NlX2FkYXB0ZXIgcmV0PSVkIGVycm5vPSVzXG4iLCByYywgcmMgPyBzdHJlcnJvcihlcnJubykgOiAiLSIpOwoJcHJpbnRmKCJSRVNVTFQ6IGtlcm5lbCBwYXRoIE9LLiBJZiBudmlkaWEtc21pIHN0aWxsIGZhaWxzLCBjaGVjayB3aGV0aGVyIGEgIgoJICAgICAgICJwYXlsb2FkIHVuZGVyIC91c3IvbGliL3dzbC9kcml2ZXJzIGlzIGxvYWRlZCBhdCBhbGwgIgoJICAgICAgICIoTERfREVCVUc9ZmlsZXMpIGJlZm9yZSByZXBsYWNpbmcgbGlicy5cbiIpOwoJY2xvc2UoZmQpOwoJcmV0dXJuIDA7Cn0K'
GPUPV_ASSET_HTTP_PUT_SERVER_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJUaHJvd2F3YXkgSFRUUCBQVVQgcmVjZWl2ZXI6IG1vdmUgZmlsZXMgaG9zdCAtPiBndWVzdCB3aGVuIHRoZXJlIGlzIG5vClNNQiBzaGFyZSB0aGUgYWdlbnQgY2FuIHJlYWQgYW5kIG5vIFNTSC9XaW5STSBpbnRvIHRoZSBXaW5kb3dzIGhvc3QuCgpSdW4gaW4gdGhlIGd1ZXN0IGFzIHRoZSBhZ2VudCBhY2NvdW50IChubyByb290IG5lZWRlZCkgYWdhaW5zdCBhIGRpcmVjdG9yeSB0aGUKYWdlbnQgb3ducywgdGhlbiBwdXNoIGZyb20gV2luZG93cyB3aXRoIGN1cmwuZXhlIChwcmVzZW50IHNpbmNlIFdpbjEwIDE4MDMpOgoKICBndWVzdDogIHB5dGhvbjMgaHR0cF9wdXRfc2VydmVyLnB5IC90bXAvaW5jb21pbmcKICBob3N0OiAgIGN1cmwuZXhlIC1zIC0tbWF4LXRpbWUgNSBodHRwOi8vPGd1ZXN0LWlwPjo4ODk5LyAgICAgICAgICAgIyBleHBlY3QgJ2FsaXZlJwogIGhvc3Q6ICAgR2V0LUNoaWxkSXRlbSAnPHNyYz4nIC1GaWxlIHwgRm9yRWFjaC1PYmplY3QgeyBjdXJsLmV4ZSAtcyAtLW1heC10aW1lIDYwMCAtVCAkXy5GdWxsTmFtZSAnaHR0cDovLzxndWVzdC1pcD46ODg5OS8nIH0KCkV2ZXJ5IFBVVCBhbnN3ZXJzIGBvayA8bmFtZT4gPGJ5dGVzPmAsIHNvIHRoZSBwdXNoaW5nIGNvbnNvbGUgcHJpbnRzIGEgcGVyLWZpbGUKcmVjZWlwdCB0aGF0IGNhbiBiZSBjaGVja2VkIGFnYWluc3QgdGhlIGhvc3QgbGlzdGluZyBpbnN0ZWFkIG9mIHRydXN0aW5nIGEKc2lsZW50IGNvcHkuIE9ubHkgdGhlIGJhc2VuYW1lIGlzIHdyaXR0ZW4sIHNvIGEgY3JhZnRlZCByZXF1ZXN0IHBhdGggY2Fubm90CmVzY2FwZSB0aGUgb3V0cHV0IGRpcmVjdG9yeS4gVW5hdXRoZW50aWNhdGVkIGJ5IGRlc2lnbjogdHJ1c3RlZCBMQU4gb25seSwgYW5kCnN0b3AgaXQgYXMgc29vbiBhcyB0aGUgYmF0Y2ggaGFzIGxhbmRlZC4KIiIiCmltcG9ydCBvcwppbXBvcnQgc3lzCmZyb20gaHR0cC5zZXJ2ZXIgaW1wb3J0IEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIsIFRocmVhZGluZ0hUVFBTZXJ2ZXIKCk9VVCA9IHN5cy5hcmd2WzFdIGlmIGxlbihzeXMuYXJndikgPiAxIGVsc2UgIi90bXAvaW5jb21pbmciClBPUlQgPSBpbnQoc3lzLmFyZ3ZbMl0pIGlmIGxlbihzeXMuYXJndikgPiAyIGVsc2UgODg5OQpvcy5tYWtlZGlycyhPVVQsIGV4aXN0X29rPVRydWUpCgoKY2xhc3MgSGFuZGxlcihCYXNlSFRUUFJlcXVlc3RIYW5kbGVyKToKICAgIGRlZiBkb19QVVQoc2VsZik6CiAgICAgICAgbmFtZSA9IG9zLnBhdGguYmFzZW5hbWUoc2VsZi5wYXRoLnNwbGl0KCI/IilbMF0ucmVwbGFjZSgiXFwiLCAiLyIpKQogICAgICAgIGlmIG5vdCBuYW1lIG9yIG5hbWUgaW4gKCIuIiwgIi4uIik6CiAgICAgICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZSg0MDApCiAgICAgICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgICAgICByZXR1cm4KICAgICAgICB0b3RhbCA9IGludChzZWxmLmhlYWRlcnMuZ2V0KCJDb250ZW50LUxlbmd0aCIsIDApIG9yIDApCiAgICAgICAgZ290ID0gMAogICAgICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oT1VULCBuYW1lKSwgIndiIikgYXMgZjoKICAgICAgICAgICAgd2hpbGUgZ290IDwgdG90YWw6CiAgICAgICAgICAgICAgICBjaHVuayA9IHNlbGYucmZpbGUucmVhZChtaW4oMSA8PCAyMCwgdG90YWwgLSBnb3QpKQogICAgICAgICAgICAgICAgaWYgbm90IGNodW5rOgogICAgICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgICAgICAgICBmLndyaXRlKGNodW5rKQogICAgICAgICAgICAgICAgZ290ICs9IGxlbihjaHVuaykKICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoMjAxKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsICJ0ZXh0L3BsYWluIikKICAgICAgICBzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICBzZWxmLndmaWxlLndyaXRlKGYib2sge25hbWV9IHtnb3R9XG4iLmVuY29kZSgpKQoKICAgIGRlZiBkb19HRVQoc2VsZik6CiAgICAgICAgYm9keSA9IFsiYWxpdmUiXQogICAgICAgIGZvciBuIGluIHNvcnRlZChvcy5saXN0ZGlyKE9VVCkpOgogICAgICAgICAgICBwID0gb3MucGF0aC5qb2luKE9VVCwgbikKICAgICAgICAgICAgaWYgb3MucGF0aC5pc2ZpbGUocCk6CiAgICAgICAgICAgICAgICBib2R5LmFwcGVuZChmIntufSB7b3MucGF0aC5nZXRzaXplKHApfSIpCiAgICAgICAgZGF0YSA9ICgiXG4iLmpvaW4oYm9keSkgKyAiXG4iKS5lbmNvZGUoKQogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZSgyMDApCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1UeXBlIiwgInRleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgiKQogICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHNlbGYud2ZpbGUud3JpdGUoZGF0YSkKCiAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwgKmFyZ3MpOgogICAgICAgIHBhc3MKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgcHJpbnQoZiJsaXN0ZW5pbmcgb24gMC4wLjAuMDp7UE9SVH0sIHdyaXRpbmcgdG8ge09VVH0iLCBmbHVzaD1UcnVlKQogICAgVGhyZWFkaW5nSFRUUFNlcnZlcigoIjAuMC4wLjAiLCBQT1JUKSwgSGFuZGxlcikuc2VydmVfZm9yZXZlcigpCg=='
GPUPV_ASSET_LDPRELOAD_TRACE_B64='LyoKICogbGRwcmVsb2FkX3RyYWNlLmMg4oCUIHdobyBpcyBhY3R1YWxseSBmYWlsaW5nOiBsb2FkZXIsIHBheWxvYWQsIERYQ29yZSBvciBrZXJuZWwuCiAqCiAqIEJ1aWxkOgogKiAgIGdjYyAtc2hhcmVkIC1mUElDIC1PMCAtbyAvdG1wL3RyYWNlLnNvIHNjcmlwdHMvbGRwcmVsb2FkX3RyYWNlLmMgLWxkbAogKiBSdW46CiAqICAgTERfUFJFTE9BRD0vdG1wL3RyYWNlLnNvIG52aWRpYS1zbWkgMj4mMSB8IGdyZXAgLUUgJ15cWyhkbG9wZW58b3BlbnxtbWFwfGR4Z3xlc2NhcGUpJwogKiAgIExEX1BSRUxPQUQ9L3RtcC90cmFjZS5zbyBweXRob24zIC1jICJpbXBvcnQgY3R5cGVzO2N0eXBlcy5DRExMKCdsaWJjdWRhLnNvLjEnKS5jdUluaXQoMCkiCiAqCiAqIFdoYXQgZWFjaCBsaW5lIGlzIGZvcjoKICogICBbZGxvcGVuXSDigKYgLT4gRkFJTCAgICAgIHRoZSBleGFjdCBsaWJyYXJ5IHBhdGggdGhlIHN0YWNrIHdhbnRlZCBhbmQgZGlkIG5vdAogKiAgICAgICAgICAgICAgICAgICAgICAgICAgIGdldC4gVGhpcyBpcyBob3cgdGhlIG1pc3NpbmcgZHJpdmVyLXN0b3JlIGZvbGRlcgogKiAgICAgICAgICAgICAgICAgICAgICAgICAgICjigKYvZHJpdmVycy9udl9kaXNwaS5pbmZfYW1kNjRfPGhhc2g+L2xpYmZvbykgc2hvd3MgdXAuCiAqICAgW29wZW5dICAg4oCmIC0+IC0xIOKApiAgICAgIG1pc3NpbmcgZGV2aWNlL2ZpbGVzIChlLmcuIC9kZXYvbnZpZGlhLXV2bSwgd2hpY2ggaXMKICogICAgICAgICAgICAgICAgICAgICAgICAgICBhYnNlbnQgb24gd29ya2luZyBXU0wgdG9vIOKAlCBjaGVjayBiZWZvcmUgYmVsaWV2aW5nIGl0KS4KICogICBbbW1hcF0gICAgICAgICAgICAgICAgICBtYXBwaW5ncyBvZiAvZGV2L2R4ZzsgYSBGQUlMIGhlcmUgbWVhbnMgdGhlIEJBUi9NTUlPCiAqICAgICAgICAgICAgICAgICAgICAgICAgICAgc2lkZSBpcyBicm9rZW4sIG5vdCB0aGUgdXNlcmxhbmQuCiAqICAgW2R4Z10gbnI9MHguLiAgICAgICAgICAgZXZlcnkgZHhnIGlvY3RsIHdpdGggaXRzIHJldHVybiBjb2RlICgweDNlIGVudW0zLAogKiAgICAgICAgICAgICAgICAgICAgICAgICAgIDB4MDkgcXVlcnksIDB4MDIgY3JlYXRlZGV2aWNlLCAweDBkIGVzY2FwZSwg4oCmKS4KICogICBbZXNjYXBlXSBjaGFuZ2VkPU4g4oCmICAgIE5WQVBJIGRyaXZlci1wcml2YXRlIGVzY2FwZTogaG93IG1hbnkgYnl0ZXMgdGhlIGhvc3QKICogICAgICAgICAgICAgICAgICAgICAgICAgICB3cm90ZSBiYWNrIGFuZCB3aGVyZS4gY2hhbmdlZD0wIG1lYW5zIHRoZSBob3N0IGRpZCBub3QKICogICAgICAgICAgICAgICAgICAgICAgICAgICBhbnN3ZXI7IGEgcGxhdXNpYmxlIGhlYWx0aHkgYW5zd2VyIGlzIH4xNDYgYnl0ZXMgYW5kCiAqICAgICAgICAgICAgICAgICAgICAgICAgICAgdGhlIHNhbWUgc2lnbmF0dXJlIGluc2lkZSB0aGUgaG9zdCdzIFdTTC4KICogICBTSUdTRUdWIGJhY2t0cmFjZSAgICAgICAgdGhlIGNyYXNoaW5nIHJldHVybiBhZGRyZXNzIGluc2lkZSBsaWJjdWRhOyB0aGUgdG9wCiAqICAgICAgICAgICAgICAgICAgICAgICAgICAgZnJhbWUgYmVpbmcgdGhlIGluc3RydWN0aW9uIGFmdGVyIGEgYGNhbGwgKkdPVGAgbWVhbnMKICogICAgICAgICAgICAgICAgICAgICAgICAgICBhIE5VTEwgZnVuY3Rpb24gcG9pbnRlciwgaS5lLiBhbiBpbml0IHN0ZXAgd2FzIHNraXBwZWQuCiAqCiAqIFJlYWQgdGhlIE9SREVSLCBub3QgYSBzaW5nbGUgbGluZTogdGhlIGZpcnN0IGZhaWxpbmcgZW50cnkgaXMgdGhlIGNhdXNlLCBldmVyeQogKiBsYXRlciBlcnJvciBpcyBmYWxsb3V0LiBBIHJ1biB0aGF0IHN0b3BzIGJlZm9yZSBhbnkgZmlsZSB1bmRlcgogKiAvdXNyL2xpYi93c2wvZHJpdmVycyBpcyBuYW1lZCBuZXZlciByZWFjaGVkIHRoZSBwYXlsb2FkIGF0IGFsbC4KICovCiNkZWZpbmUgX0dOVV9TT1VSQ0UKI2luY2x1ZGUgPHN0ZGFyZy5oPgojaW5jbHVkZSA8c3RkaW8uaD4KI2luY2x1ZGUgPHN0ZGludC5oPgojaW5jbHVkZSA8c3RkbGliLmg+CiNpbmNsdWRlIDxzdHJpbmcuaD4KI2luY2x1ZGUgPGVycm5vLmg+CiNpbmNsdWRlIDxkbGZjbi5oPgojaW5jbHVkZSA8ZmNudGwuaD4KI2luY2x1ZGUgPHNpZ25hbC5oPgojaW5jbHVkZSA8dW5pc3RkLmg+CiNpbmNsdWRlIDxleGVjaW5mby5oPgojaW5jbHVkZSA8c3lzL2lvY3RsLmg+CiNpbmNsdWRlIDxzeXMvbW1hbi5oPgoKc3RhdGljIGludCAoKnJlYWxfaW9jdGwpKGludCwgdW5zaWduZWQgbG9uZywgdm9pZCAqKSA9IE5VTEw7CnN0YXRpYyB2b2lkICooKnJlYWxfbW1hcCkodm9pZCAqLCBzaXplX3QsIGludCwgaW50LCBpbnQsIG9mZl90KSA9IE5VTEw7CnN0YXRpYyBpbnQgKCpyZWFsX29wZW4pKGNvbnN0IGNoYXIgKiwgaW50LCAuLi4pID0gTlVMTDsKc3RhdGljIGludCAoKnJlYWxfb3BlbmF0KShpbnQsIGNvbnN0IGNoYXIgKiwgaW50LCAuLi4pID0gTlVMTDsKc3RhdGljIHZvaWQgKigqcmVhbF9kbG9wZW4pKGNvbnN0IGNoYXIgKiwgaW50KSA9IE5VTEw7CgpzdHJ1Y3QgZHhnX2VzY2FwZSB7Cgl1aW50MzJfdCBhZGFwdGVyOwoJdWludDMyX3QgZGV2aWNlOwoJaW50MzJfdCB0eXBlOwoJdWludDMyX3QgZmxhZ3M7Cgl1aW50NjRfdCBkYXRhOwoJdWludDMyX3Qgc2l6ZTsKCXVpbnQzMl90IGNvbnRleHQ7Cn07CgpzdGF0aWMgaW50IGludGVyZXN0aW5nKGNvbnN0IGNoYXIgKnApCnsKCWlmICghcCkKCQlyZXR1cm4gMDsKCXJldHVybiBzdHJzdHIocCwgIm52aWRpYSIpIHx8IHN0cnN0cihwLCAiZHhnIikgfHwgc3Ryc3RyKHAsICJncHVjb21wIikgfHwKCSAgICAgICBzdHJzdHIocCwgIm52dm0iKSB8fCBzdHJzdHIocCwgInByb2MvZHJpdmVyIikgfHwgc3Ryc3RyKHAsICJkcmkiKTsKfQoKc3RhdGljIGNvbnN0IGNoYXIgKmZkX3RhcmdldChpbnQgZmQsIGNoYXIgKmJ1Ziwgc2l6ZV90IG4pCnsKCWNoYXIgcGF0aFs2NF07Cglzc2l6ZV90IHI7CgoJc25wcmludGYocGF0aCwgc2l6ZW9mKHBhdGgpLCAiL3Byb2Mvc2VsZi9mZC8lZCIsIGZkKTsKCXIgPSByZWFkbGluayhwYXRoLCBidWYsIG4gLSAxKTsKCWlmIChyIDwgMCkKCQlyZXR1cm4gIj8iOwoJYnVmW3JdID0gMDsKCXJldHVybiBidWY7Cn0KCnZvaWQgKmRsb3Blbihjb25zdCBjaGFyICpuYW1lLCBpbnQgZmxhZykKewoJdm9pZCAqaDsKCglpZiAoIXJlYWxfZGxvcGVuKQoJCXJlYWxfZGxvcGVuID0gZGxzeW0oUlRMRF9ORVhULCAiZGxvcGVuIik7CgloID0gcmVhbF9kbG9wZW4obmFtZSwgZmxhZyk7CglpZiAobmFtZSkKCQlmcHJpbnRmKHN0ZGVyciwgIltkbG9wZW5dICVzIC0+ICVzXG4iLCBuYW1lLCBoID8gIk9LIiA6ICJGQUlMIik7CglyZXR1cm4gaDsKfQoKaW50IG9wZW4oY29uc3QgY2hhciAqcGF0aCwgaW50IGZsYWdzLCAuLi4pCnsKCW1vZGVfdCBtb2RlID0gMDsKCXZhX2xpc3QgYXA7CglpbnQgZmQ7CgoJaWYgKCFyZWFsX29wZW4pCgkJcmVhbF9vcGVuID0gZGxzeW0oUlRMRF9ORVhULCAib3BlbiIpOwoJaWYgKGZsYWdzICYgT19DUkVBVCkgewoJCXZhX3N0YXJ0KGFwLCBmbGFncyk7CgkJbW9kZSA9IHZhX2FyZyhhcCwgaW50KTsKCQl2YV9lbmQoYXApOwoJfQoJZmQgPSByZWFsX29wZW4ocGF0aCwgZmxhZ3MsIG1vZGUpOwoJaWYgKGludGVyZXN0aW5nKHBhdGgpKQoJCWZwcmludGYoc3RkZXJyLCAiW29wZW5dICVzIC0+ICVkJXMlc1xuIiwgcGF0aCwgZmQsCgkJCWZkIDwgMCA/ICIgIiA6ICIiLCBmZCA8IDAgPyBzdHJlcnJvcihlcnJubykgOiAiIik7CglyZXR1cm4gZmQ7Cn0KCmludCBvcGVuYXQoaW50IGRpcmZkLCBjb25zdCBjaGFyICpwYXRoLCBpbnQgZmxhZ3MsIC4uLikKewoJbW9kZV90IG1vZGUgPSAwOwoJdmFfbGlzdCBhcDsKCWludCBmZDsKCglpZiAoIXJlYWxfb3BlbmF0KQoJCXJlYWxfb3BlbmF0ID0gZGxzeW0oUlRMRF9ORVhULCAib3BlbmF0Iik7CglpZiAoZmxhZ3MgJiBPX0NSRUFUKSB7CgkJdmFfc3RhcnQoYXAsIGZsYWdzKTsKCQltb2RlID0gdmFfYXJnKGFwLCBpbnQpOwoJCXZhX2VuZChhcCk7Cgl9CglmZCA9IHJlYWxfb3BlbmF0KGRpcmZkLCBwYXRoLCBmbGFncywgbW9kZSk7CglpZiAoaW50ZXJlc3RpbmcocGF0aCkpCgkJZnByaW50ZihzdGRlcnIsICJbb3BlbmF0XSAlcyAtPiAlZCVzJXNcbiIsIHBhdGgsIGZkLAoJCQlmZCA8IDAgPyAiICIgOiAiIiwgZmQgPCAwID8gc3RyZXJyb3IoZXJybm8pIDogIiIpOwoJcmV0dXJuIGZkOwp9Cgp2b2lkICptbWFwKHZvaWQgKmFkZHIsIHNpemVfdCBsZW4sIGludCBwcm90LCBpbnQgZmxhZ3MsIGludCBmZCwgb2ZmX3Qgb2ZmKQp7Cgl2b2lkICpwOwoKCWlmICghcmVhbF9tbWFwKQoJCXJlYWxfbW1hcCA9IGRsc3ltKFJUTERfTkVYVCwgIm1tYXAiKTsKCXAgPSByZWFsX21tYXAoYWRkciwgbGVuLCBwcm90LCBmbGFncywgZmQsIG9mZik7CglpZiAoZmQgPj0gMCkgewoJCWNoYXIgYnVmWzI1Nl07CgkJY29uc3QgY2hhciAqdCA9IGZkX3RhcmdldChmZCwgYnVmLCBzaXplb2YoYnVmKSk7CgoJCWlmIChzdHJzdHIodCwgImR4ZyIpKQoJCQlmcHJpbnRmKHN0ZGVyciwKCQkJCSJbbW1hcF0gZmQ9JWQoJXMpIGxlbj0lenUgcHJvdD0weCV4IG9mZj0lbGxkIC0+ICVwJXNcbiIsCgkJCQlmZCwgdCwgbGVuLCBwcm90LCAobG9uZyBsb25nKW9mZiwgcCwKCQkJCXAgPT0gTUFQX0ZBSUxFRCA/ICIgRkFJTCIgOiAiIik7Cgl9CglyZXR1cm4gcDsKfQoKaW50IGlvY3RsKGludCBmZCwgdW5zaWduZWQgbG9uZyByZXEsIC4uLikKewoJdmFfbGlzdCBhcDsKCXZvaWQgKmFyZzsKCWludCByZXQsIHNhdmVkOwoJdW5zaWduZWQgbnIgPSBfSU9DX05SKHJlcSk7CgoJdmFfc3RhcnQoYXAsIHJlcSk7CglhcmcgPSB2YV9hcmcoYXAsIHZvaWQgKik7Cgl2YV9lbmQoYXApOwoKCWlmICghcmVhbF9pb2N0bCkKCQlyZWFsX2lvY3RsID0gZGxzeW0oUlRMRF9ORVhULCAiaW9jdGwiKTsKCglpZiAoX0lPQ19UWVBFKHJlcSkgPT0gMHg0NyAmJiBuciA9PSAweDBkICYmIGFyZykgewoJCXN0cnVjdCBkeGdfZXNjYXBlICplID0gYXJnOwoJCXVuc2lnbmVkIGNoYXIgKnNuYXAgPSBOVUxMOwoJCXVpbnQzMl90IHN6ID0gZS0+c2l6ZTsKCgkJaWYgKGUtPmRhdGEgJiYgc3opIHsKCQkJc25hcCA9IG1hbGxvYyhzeik7CgkJCWlmIChzbmFwKQoJCQkJbWVtY3B5KHNuYXAsICh2b2lkICopKHVpbnRwdHJfdCllLT5kYXRhLCBzeik7CgkJfQoJCXJldCA9IHJlYWxfaW9jdGwoZmQsIHJlcSwgYXJnKTsKCQlzYXZlZCA9IGVycm5vOwoJCWZwcmludGYoc3RkZXJyLCAiW2VzY2FwZV0gdHlwZT0lZCBzaXplPSV1IGZsYWdzPTB4JXggcmV0PSVkIiwKCQkJZS0+dHlwZSwgc3osIGUtPmZsYWdzLCByZXQpOwoJCWlmIChzbmFwKSB7CgkJCXVuc2lnbmVkIGNoYXIgKm5vdyA9ICh1bnNpZ25lZCBjaGFyICopKHVpbnRwdHJfdCllLT5kYXRhOwoJCQl1bnNpZ25lZCBjaGFuZ2VkID0gMCwgc2hvd24gPSAwLCBpOwoKCQkJZm9yIChpID0gMDsgaSA8IHN6OyBpKyspCgkJCQlpZiAoc25hcFtpXSAhPSBub3dbaV0pCgkJCQkJY2hhbmdlZCsrOwoJCQlmcHJpbnRmKHN0ZGVyciwgIiBjaGFuZ2VkPSV1IiwgY2hhbmdlZCk7CgkJCWZvciAoaSA9IDA7IGkgPCBzeiAmJiBzaG93biA8IDEyOyBpKyspIHsKCQkJCWlmIChzbmFwW2ldICE9IG5vd1tpXSkgewoJCQkJCWZwcmludGYoc3RkZXJyLCAiIFsldTolMDJ4PiUwMnhdIiwgaSwgc25hcFtpXSwgbm93W2ldKTsKCQkJCQlzaG93bisrOwoJCQkJfQoJCQl9CgkJCWZyZWUoc25hcCk7CgkJfQoJCWZwcmludGYoc3RkZXJyLCAiXG4iKTsKCQllcnJubyA9IHNhdmVkOwoJCXJldHVybiByZXQ7Cgl9CgoJcmV0ID0gcmVhbF9pb2N0bChmZCwgcmVxLCBhcmcpOwoJc2F2ZWQgPSBlcnJubzsKCWlmIChfSU9DX1RZUEUocmVxKSA9PSAweDQ3KQoJCWZwcmludGYoc3RkZXJyLCAiW2R4Z10gbnI9MHglMDJ4IHJldD0lZCVzJXNcbiIsIG5yLCByZXQsCgkJCXJldCA8IDAgPyAiIGVycm5vPSIgOiAiIiwKCQkJcmV0IDwgMCA/IHN0cmVycm9yKHNhdmVkKSA6ICIiKTsKCWVycm5vID0gc2F2ZWQ7CglyZXR1cm4gcmV0Owp9CgovKiAtLS0tIGNyYXNoIGxvY2F0aW9uIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gKi8KCnN0YXRpYyB2b2lkIG9uX3NpZ25hbChpbnQgc2lnKQp7Cgl2b2lkICpidFs0MF07CglpbnQgbjsKCgkodm9pZClzaWc7Cgl3cml0ZSgyLCAiXG49PT0gY3Jhc2g6IGJhY2t0cmFjZSAodG9wIGZyYW1lID0gcmV0dXJuIGFkZHJlc3MpID09PVxuIiwgNTYpOwoJbiA9IGJhY2t0cmFjZShidCwgNDApOwoJYmFja3RyYWNlX3N5bWJvbHNfZmQoYnQsIG4sIDIpOwoJX2V4aXQoMTM5KTsKfQoKX19hdHRyaWJ1dGVfXygoY29uc3RydWN0b3IpKSBzdGF0aWMgdm9pZCBpbnN0YWxsX2hhbmRsZXJzKHZvaWQpCnsKCXN0cnVjdCBzaWdhY3Rpb24gc2E7CgoJbWVtc2V0KCZzYSwgMCwgc2l6ZW9mKHNhKSk7CglzYS5zYV9oYW5kbGVyID0gb25fc2lnbmFsOwoJc2Euc2FfZmxhZ3MgPSBTQV9OT0RFRkVSOwoJc2lnYWN0aW9uKFNJR1NFR1YsICZzYSwgTlVMTCk7CglzaWdhY3Rpb24oU0lHQlVTLCAmc2EsIE5VTEwpOwoJc2lnYWN0aW9uKFNJR0FCUlQsICZzYSwgTlVMTCk7Cn0K'
GPUPV_ASSET_ABI_GATES_B64='IyEvdXNyL2Jpbi9lbnYgYmFzaAojIGxpYi9hYmlfZ2F0ZXMuc2ggLSBvZmZsaW5lIGdhdGVzIGZvciBhIGR4Z2tybmwua28sIGJlZm9yZSBpdCBpcyBsb2FkZWQuCiMKIyAgIGJhc2ggbGliL2FiaV9nYXRlcy5zaCA8ZHhna3JubC5rbz4gW290aGVyIGQzZGttdGhrLmhdCiMKIyBHYXRlIDIgaXMgdGhlIG9uZSB0aGF0IG1hdHRlcnM6IHRoZSBtb2R1bGUgbXVzdCByZWFkIGhkZXYtPmNoYW5uZWwgYXQgdGhlCiMgUlVOTklORyBLRVJORUwncyBvZmZzZXQuIEEgbW9kdWxlIGJ1aWx0IGFnYWluc3QgdGhlIFdTTCBicmFuY2gncyBoeXBlcnYuaAojIHJlYWRzIGEgbmVpZ2hib3VyaW5nIGZpZWxkLCBOVUxMLWRlcmVmcyBpbnNpZGUgcHJvYmUgd2hpbGUgaG9sZGluZwojIGRldmljZV9tdXRleCwgYW5kIHRoZW4gbm8gbGF0ZXIgcHJvYmUgY2FuIHJ1biB3aGlsZSB2ZXJtYWdpYyBzdGlsbCBtYXRjaGVzLgojIFRoZSBleHBlY3RlZCBvZmZzZXQgaXMgZGVyaXZlZCBmcm9tIHRoZSBydW5uaW5nIGtlcm5lbCBlYWNoIHRpbWUsIG5ldmVyCiMgbWVtb3Jpc2VkLCBiZWNhdXNlIGEga2VybmVsIGJ1bXAgY2hhbmdlcyBpdC4Kc2V0IC11CktPPSR7MTotfQpPVEhFUj0kezI6LX0KWyAtbiAiJEtPIiBdICYmIFsgLWYgIiRLTyIgXSB8fCB7IGVjaG8gInVzYWdlOiBhYmlfZ2F0ZXMuc2ggPGR4Z2tybmwua28+IFtvdGhlci1kM2RrbXRoay5oXSIgPiYyOyBleGl0IDI7IH0KSz0kKHVuYW1lIC1yKQpQUk9HPSQoYmFzZW5hbWUgLS0gIiQwIikKZmFpbD0wCm5vdGUoKSB7IHByaW50ZiAnJS0xNHMgJXNcbicgIiQxIiAiJDIiOyB9CmJhZCgpICB7IHByaW50ZiAnJS0xNHMgRkFJTCAlc1xuJyAiJDEiICIkMiI7IGZhaWw9MTsgfQoKIyAtLS0gMS4gdmVybWFnaWMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmt2PSQoc3RyaW5ncyAiJEtPIiB8IGdyZXAgLW0xICdedmVybWFnaWM9JyB8IHNlZCAncy9edmVybWFnaWM9Ly8nKQpjYXNlICIka3YiIGluCgkiJEsgIiopIG5vdGUgdmVybWFnaWMgIiRrdiIgOzsKCSIiKSAgICAgYmFkICB2ZXJtYWdpYyAibm8gdmVybWFnaWMgZm91bmQgKG5vdCBhIGtlcm5lbCBtb2R1bGU/KSIgOzsKCSopICAgICAgYmFkICB2ZXJtYWdpYyAiWyRrdl0gIT0gWyRLXSIgOzsKZXNhYwoKIyAtLS0gMi4gaGRldi0+Y2hhbm5lbCBvZmZzZXQgdnMgdGhlIHJ1bm5pbmcga2VybmVsIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCkI9JChta3RlbXAgLWQgIiR7VE1QRElSOi0vdG1wfS9ncHVwdi1vZmYuWFhYWFhYIikKewoJcHJpbnRmICcjaW5jbHVkZSA8bGludXgvbW9kdWxlLmg+XG4jaW5jbHVkZSA8bGludXgvaHlwZXJ2Lmg+XG4nCglwcmludGYgJ3Vuc2lnbmVkIGxvbmcgb2ZmX2NoYW5uZWwodm9pZCkgeyByZXR1cm4gKHVuc2lnbmVkIGxvbmcpb2Zmc2V0b2Yoc3RydWN0IGh2X2RldmljZSwgY2hhbm5lbCk7IH1cbicKfSA+ICIkQi9vZmYuYyIKZWNobyAnb2JqLW0gKz0gb2ZmLm8nID4gIiRCL01ha2VmaWxlIgp3YW50PSIiCmlmIG1ha2UgLUMgIi9saWIvbW9kdWxlcy8kSy9idWlsZCIgTT0iJEIiID4iJEIvbWFrZS5sb2ciIDI+JjEgfHwgWyAtZiAiJEIvb2ZmLm8iIF07IHRoZW4KCSMgdGhlIGNvbXBpbGUgbGVnaXRpbWF0ZWx5IGZhaWxzIGF0IG1vZHBvc3Q7IG9mZi5vIGlzIHByb2R1Y2VkIGZpcnN0Cgl3YW50PSQob2JqZHVtcCAtZCAiJEIvb2ZmLm8iIDI+L2Rldi9udWxsIFwKCQl8IHNlZCAtbiAnLzxvZmZfY2hhbm5lbD46LywvcmV0XHxqbXAvcCcgXAoJCXwgZ3JlcCAtb0UgJ1wkMHhbMC05YS1mXSssJWVheCcgfCBoZWFkIC0xIHwgZ3JlcCAtb0UgJzB4WzAtOWEtZl0rJykKZmkKcm0gLXJmICIkQiIKZ290PSQob2JqZHVtcCAtZCAiJEtPIiAyPi9kZXYvbnVsbCBcCgl8IHNlZCAtbiAnLzxkeGdfcHJvYmVfdm1idXM+Oi8sL14kL3AnIFwKCXwgZ3JlcCAtbTEgLW9FICdtb3YgKzB4WzAtOWEtZl0rXCglcmJ4XCksJXJheCcgfCBncmVwIC1vRSAnMHhbMC05YS1mXSsnKQppZiBbIC1uICIkd2FudCIgXSAmJiBbIC1uICIkZ290IiBdOyB0aGVuCglpZiBbICIkd2FudCIgPSAiJGdvdCIgXTsgdGhlbgoJCW5vdGUgY2hhbm5lbC1vZmYgIiRnb3QgKGtlcm5lbCBoZWFkZXIgYWdyZWVzKSIKCWVsc2UKCQliYWQgY2hhbm5lbC1vZmYgIm1vZHVsZSAkZ290IHZzIGtlcm5lbCAkd2FudCAtIGJ1aWx0IGFnYWluc3QgYSBmb3JlaWduIGh5cGVydi5oIgoJZmkKZWxpZiBbIC1uICIkZ290IiBdOyB0aGVuCglub3RlIGNoYW5uZWwtb2ZmICIkZ290IChrZXJuZWwgaGVhZGVyIHVuYXZhaWxhYmxlOyB2ZXJpZnkgYnkgaGFuZCkiCmVsc2UKCWJhZCBjaGFubmVsLW9mZiAiY2Fubm90IGxvY2F0ZSB0aGUgaGRldi0+Y2hhbm5lbCBsb2FkIGluIGR4Z19wcm9iZV92bWJ1cyIKZmkKCiMgLS0tIDMuIEdQVS1QViBjaGFubmVsIEdVSUQgYWxpYXNlcyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQptb2RpbmZvX291dD0kKG1vZGluZm8gIiRLTyIgMj4vZGV2L251bGwgfHwgdHJ1ZSkKWyAtbiAiJG1vZGluZm9fb3V0IiBdIHx8IG1vZGluZm9fb3V0PSQocmVhZGVsZiAtcCAubW9kaW5mbyAiJEtPIiAyPi9kZXYvbnVsbCB8fCBzdHJpbmdzICIkS08iKQppZiBwcmludGYgJyVzJyAiJG1vZGluZm9fb3V0IiB8IGdyZXAgLXEgJ3ZtYnVzOjE4MmQzODZlMzYzMzRiNGZhY2M0MmI3NzAzZDRkZjRhJyAmJgogICBwcmludGYgJyVzJyAiJG1vZGluZm9fb3V0IiB8IGdyZXAgLXEgJ3ZtYnVzOmMwY2JlOWRkNjA1MDM2NDQ5NDQ4ZWExMjU0YTVkMTc3JzsgdGhlbgoJbm90ZSBndWlkLWFsaWFzZXMgImJvdGggZHhnIGNoYW5uZWwgR1VJRHMgcHJlc2VudCIKZWxzZQoJYmFkIGd1aWQtYWxpYXNlcyAiYSBHUFUtUFYgY2hhbm5lbCBHVUlEIGFsaWFzIGlzIG1pc3NpbmcgKGh5cGVydl9ncHVwLmggbm90IGluY2x1ZGVkPykiCmZpCgojIC0tLSA0LiBVQVBJIEFCSSB2cyB0aGUgaGVhZGVyIGFscmVhZHkgaW4gdXNlIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KaWYgWyAtbiAiJE9USEVSIiBdICYmIFsgLWYgIiRPVEhFUiIgXTsgdGhlbgoJcHJvYmU9JChmaW5kIC91c3Ivc3JjIC1tYXhkZXB0aCA2IC1wYXRoICcqdWFwaS9taXNjL2QzZGttdGhrLmgnIDI+L2Rldi9udWxsIHwgaGVhZCAtMSkKCWlmIFsgLW4gIiRwcm9iZSIgXTsgdGhlbgoJCXQ9JChta3RlbXAgLWQgIiR7VE1QRElSOi0vdG1wfS9ncHVwdi1hYmkuWFhYWFhYIikKCQkjIExldCB0aGUgc3lzdGVtJ3MgPGxpbnV4L3R5cGVzLmg+IHByb3ZpZGUgX191OC4uL19fdTY0OiBkZWZpbmluZyB0aGVtCgkJIyBieSBoYW5kIGNvbGxpZGVzIHdpdGggZ2xpYmMncyBhc20vdHlwZXMuaCBhbmQgdGhlIGhlYWRlciB0aGVuIGZhaWxzIHRvCgkJIyBwYXJzZSwgd2hpY2ggdXNlZCB0byBiZSByZXBvcnRlZCBhcyBhbiBBQkkgbWlzbWF0Y2guCgkJY2F0ID4gIiR0L2EuYyIgPDwnRU9GJwojaW5jbHVkZSA8c3RkaW8uaD4KI2luY2x1ZGUgPHN0ZGludC5oPgojaW5jbHVkZSA8bGludXgvdHlwZXMuaD4KI2lmbmRlZiBfX3VzZXIKI2RlZmluZSBfX3VzZXIKI2VuZGlmCiNpbmNsdWRlIFVBUEkKaW50IG1haW4odm9pZCkgewoJcHJpbnRmKCIlenUgJXp1ICV6dVxuIiwKCQlzaXplb2Yoc3RydWN0IGQzZGRkaV9zeW5jaHJvbml6YXRpb25vYmplY3RpbmZvMiksCgkJc2l6ZW9mKHN0cnVjdCBkM2RrbXRfY3JlYXRlc3luY2hyb25pemF0aW9ub2JqZWN0MiksCgkJc2l6ZW9mKHN0cnVjdCBkM2RrbXRfY3JlYXRlYWxsb2NhdGlvbikpOwoJcmV0dXJuIDA7Cn0KRU9GCgkJYT0kKGdjYyAtRFVBUEk9IlwiJHByb2JlXCIiIC1vICIkdC9hIiAiJHQvYS5jIiAyPi9kZXYvbnVsbCAmJiAiJHQvYSIpCgkJYj0kKGdjYyAtRFVBUEk9IlwiJE9USEVSXCIiIC1vICIkdC9iIiAiJHQvYS5jIiAyPi9kZXYvbnVsbCAmJiAiJHQvYiIpCgkJcm0gLXJmICIkdCIKCQlpZiBbIC16ICIkYSIgXSB8fCBbIC16ICIkYiIgXTsgdGhlbgoJCQkjIGEgaGVhZGVyIHRoYXQgd2lsbCBub3QgcGFyc2Ugc3RhbmRhbG9uZSB0ZWxscyB1cyBub3RoaW5nIGFib3V0IHRoZQoJCQkjIGxheW91dDsgc2F5IHNvIGluc3RlYWQgb2YgcmVwb3J0aW5nIGEgZmFsc2UgQUJJIG1pc21hdGNoCgkJCW5vdGUgdWFwaS1hYmkgImluY29uY2x1c2l2ZSAoYSBoZWFkZXIgZmFpbGVkIHRvIHBhcnNlIHN0YW5kYWxvbmU6IGluLXVzZSBbJHthOi1mYWlsfV0gbmV3IFske2I6LWZhaWx9XSkgLSBjb21wYXJlIGJ5IGhhbmQiCgkJZWxpZiBbICIkYSIgPSAiJGIiIF07IHRoZW4KCQkJbm90ZSB1YXBpLWFiaSAiaWRlbnRpY2FsICgkYSkiCgkJZWxzZQoJCQliYWQgdWFwaS1hYmkgImRpZmZlcnM6IGluLXVzZSBbJGFdIHZzIG5ldyBbJGJdIC0gYW4gaW5zdGFsbGVkIGxpYmN1ZGEgd291bGQgbWlzcmVhZCBpb2N0bCBhcmdzIgoJCWZpCgllbHNlCgkJbm90ZSB1YXBpLWFiaSAic2tpcHBlZCAobm8gZGVwbG95ZWQgZDNka210aGsuaCB0byBjb21wYXJlKSIKCWZpCmVsc2UKCW5vdGUgdWFwaS1hYmkgInNraXBwZWQgKHBhc3MgYSBzZWNvbmQgZDNka210aGsuaCB0byBjb21wYXJlKSIKZmkKCmlmIFsgIiRmYWlsIiAtZXEgMCBdOyB0aGVuCgllY2hvICJBTEwgR0FURVMgUEFTUyAtIHN0aWxsIG5vdCBwcm9vZjogbG9hZCBpdCwgdGhlbiBydW4gdGhlIGd1ZXN0IHNjcmlwdCdzICd2ZXJpZnknIgplbHNlCgllY2hvICJHQVRFUyBGQUlMRUQgLSBkbyBub3QgaW5zbW9kIHRoaXMgbW9kdWxlIgpmaQpleGl0ICIkZmFpbCIK'

# ====================== lib/deps.sh ======================
# lib/deps.sh - the guest-side build toolchain.
#
# A stock fnOS install does not ship a C compiler: `make` exists (kbuild needs it)
# but `gcc` does not, so `make -C /lib/modules/.../build M=...` dies with
#   /bin/sh: 1: gcc: not found
#   make[3]: *** [scripts/Makefile.build:287: dxgmodule.o] Error 127
# and the build log's only clue is Error 127. Check for the whole set up front and
# install it in one apt call, rather than discovering them one failed build later.
#
# Packages needed on a Debian/fnOS guest to build an out-of-tree kernel module:
#   gcc        the compiler the kernel was built with (Debian 12 = gcc-12)
#   make       kbuild
#   xz-utils   to read/write dxgkrnl.ko.xz
#   bc         kernel version arithmetic in kbuild
#   bison flex the .c/.h parsers kbuild generates
#   libelf-dev libssl-dev zlib1g-dev   objtool / module signing / compression
#   dwarves    pahole, only needed when module BTF is generated
#   kmod       depmod/modprobe/insmod
#   dkms       optional, only for --dkms

DEPS_PKGS="gcc make xz-utils bc bison flex libelf-dev libssl-dev zlib1g-dev dwarves kmod"

# command -> package, for the ones whose binary name differs
_deps_bin_pkg() {
	case "$1" in
		gcc) echo gcc ;;
		make) echo make ;;
		xz) echo xz-utils ;;
		bc) echo bc ;;
		bison) echo bison ;;
		flex) echo flex ;;
		depmod|modprobe|insmod) echo kmod ;;
		pahole) echo dwarves ;;
		*) echo "$1" ;;
	esac
}

# What is missing, one binary per line. Header files are checked separately.
_deps_missing_bins() {
	local b
	for b in gcc make xz bc bison flex depmod; do
		have "$b" || echo "$b"
	done
}

_deps_missing_headers() {
	[ -f /usr/include/libelf.h ] || echo libelf-dev
	[ -f /usr/include/openssl/ssl.h ] || echo libssl-dev
	[ -f /usr/include/zlib.h ] || echo zlib1g-dev
}

cmd_deps() {
	local do_install=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--install|-y) do_install=1; shift ;;
			*) shift ;;
		esac
	done

	say "build toolchain"
	note "kernel headers  $([ -d "/lib/modules/$(kver)/build" ] && echo "present (/lib/modules/$(kver)/build)" || echo "MISSING - install linux-headers-$(kver)")"

	local missing="" pkgs="" b p
	while IFS= read -r b; do
		[ -n "$b" ] || continue
		missing="$missing $b"
	done < <(_deps_missing_bins)
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		pkgs="$pkgs $p"
	done < <(_deps_missing_headers)

	if [ -z "$missing" ] && [ -z "$pkgs" ]; then
		mark_ok "gcc make xz bc bison flex depmod + libelf/libssl/zlib headers"
		have dkms && note "dkms present (only needed for module build --dkms)"
		note "gcc: $(gcc --version 2>/dev/null | head -1)"
		return 0
	fi

	[ -n "$missing" ] && mark_fail "missing binaries:$missing" "- these are what break the build with Error 127"
	[ -n "$pkgs" ] && mark_fail "missing headers:$pkgs" "- objtool / compression / module signing"

	if [ "$do_install" -eq 0 ]; then
		note ""
		note "install with:  sudo $PROG deps --install"
		return 1
	fi

	need_root deps --install
	have apt-get || die "no apt-get; install manually:$pkgs $(_deps_bin_pkg_list "$missing")"

	# Map binaries to packages, dedupe, and keep the fixed list order.
	for b in $missing; do
		pkgs="$pkgs $(_deps_bin_pkg "$b")"
	done
	pkgs=$(printf '%s\n' $pkgs | awk '!seen[$0]++' | tr '\n' ' ')

	sub "apt-get install $pkgs"
	DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed (continuing with the cached index)"
	if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs; then
		mark_ok "installed:$pkgs"
	else
		mark_fail "apt-get install failed" "- install manually:$pkgs"
		return 1
	fi

	# the very command that failed before must now work
	if gcc --version >/dev/null 2>&1; then
		note "gcc: $(gcc --version | head -1)"
		return 0
	fi
	die "gcc still not runnable after installing $pkgs"
}

_deps_bin_pkg_list() {
	local b out=""
	for b in $1; do out="$out $(_deps_bin_pkg "$b")"; done
	printf '%s' "$out"
}

# Interactive-free variant for callers (module build, setup): install when root,
# otherwise fail with the exact command to run.
deps_ensure() {
	local missing pkgs
	missing=$(_deps_missing_bins | tr '\n' ' ')
	pkgs=$(_deps_missing_headers | tr '\n' ' ')
	[ -z "$missing" ] && [ -z "$pkgs" ] && return 0

	if is_root; then
		cmd_deps --install
		return $?
	fi
	{
		printf 'ERROR build toolchain incomplete:'
		[ -n "$missing" ] && printf ' binaries:%s' "$missing"
		[ -n "$pkgs" ] && printf ' headers:%s' "$pkgs"
		printf '\n'
		printf '      install with:  sudo %s deps --install\n' "$PROG"
	} >&2
	return 1
}

# ====================== lib/triage.sh ======================
# lib/triage.sh - root-free guest triage. Decides which side is broken before
# anything is rebuilt, copied or re-assigned.

cmd_triage() {
	local dxg_dir smi_out smi_rc cls d st drv n

	say "1. kernel and OS"
	note "kernel      $(kver)"
	note "arch        $(uname -m)"
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		note "os          $(. /etc/os-release; printf '%s %s' "${NAME:-?}" "${VERSION:-}")"
	fi
	note "hyperv      $( [ -d /sys/bus/vmbus ] && echo "VMBus bus present" || echo "NOT a Hyper-V guest")"
	note "booted      $(uptime -p 2>/dev/null || echo '?')"

	say "2. kernel module and device node"
	if lsmod 2>/dev/null | grep -q '^dxgkrnl'; then
		mark_ok "dxgkrnl loaded ($(lsmod | awk '$1=="dxgkrnl"{print $2}') bytes)"
	else
		mark_fail "dxgkrnl not loaded" "- see: $PROG doctor / docs/troubleshooting.md"
	fi
	if [ -e /dev/dxg ]; then
		local major minor
		major=$(stat -c '%t' /dev/dxg 2>/dev/null); minor=$(stat -c '%T' /dev/dxg 2>/dev/null)
		mark_ok "/dev/dxg present ($(stat -c '%A' /dev/dxg 2>/dev/null) major/minor 0x$major/0x$minor)"
	else
		mark_fail "/dev/dxg absent" "- module up but no adapter, or module never loaded"
	fi
	if [ -d /sys/module/dxgkrnl ]; then
		note "srcversion  $(cat /sys/module/dxgkrnl/srcversion 2>/dev/null || echo '?')"
	fi

	say "3. VMBus GPU-PV channels (decisive host-vs-guest test)"
	local found=0
	for d in /sys/bus/vmbus/devices/*/; do
		[ -d "$d" ] || continue
		cls=$(cat "$d/class_id" 2>/dev/null || true)
		case "$cls" in
			*6e382d18*) st=$(cat "$d/state" 2>/dev/null); drv=$(drv_name "$d/driver")
				note "vGPU    $(basename "$d") state=$st driver=$drv"; found=$((found+1)) ;;
			*dde9cbc0*) st=$(cat "$d/state" 2>/dev/null); drv=$(drv_name "$d/driver")
				note "global  $(basename "$d") state=$st driver=$drv"; found=$((found+1)) ;;
		esac
	done
	if [ "$found" -ge 2 ]; then
		mark_ok "both dxg channels offered ($found)"
	elif [ "$found" -eq 1 ]; then
		mark_fail "only one dxg channel offered" "- host assigned nothing usable; check the host side"
	else
		mark_fail "no dxg VMBus channels" "- host-side problem: partition not assigned (see host/gpupv-host.ps1)"
	fi

	say "4. synthetic PCI 3D controller (VPCI hosts only)"
	local pci
	pci=$(lspci -nn 2>/dev/null | grep -i '1414:' | head -1)
	if [ -z "$pci" ]; then
		note "no 1414: device - normal on hosts that drive GPU-PV over VMBus channels"
	else
		note "$pci"
		local bdf=${pci%% *}
		if [ -r "/sys/bus/pci/devices/$bdf/resource" ]; then
			local nonzero
			nonzero=$(awk '$1!="0x0000000000000000" && $2!="0x0000000000000000"' "/sys/bus/pci/devices/$bdf/resource" | wc -l)
			note "BAR lines with real bases: $nonzero / $(wc -l < "/sys/bus/pci/devices/$bdf/resource")"
			if [ "$nonzero" -eq 0 ]; then
				warn "all-zero BARs: only a fault if a dxgkrnl probe is ALSO hung in D state"
			fi
		fi
	fi

	say "5. userland driver store (the #1 cause of 'NVML works, CUDA segfaults')"
	dxg_dir=$(ds_pick) || dxg_dir=""
	if [ -z "$dxg_dir" ]; then
		mark_fail "no $WSL_DRIVERS/$NVSTORE_GLOB" "- dxgkrnl deployed? userland payload never installed"
	else
		note "path        $dxg_dir"
		if v=$(ds_verdict "$dxg_dir"); then mark_ok "driverstore $v"; else mark_fail "driverstore $v"; fi
		nvstore_keyfiles "$dxg_dir" | sed 's/^/  /'
	fi
	if [ -d "$WSL_LIB" ]; then
		local cl
		cl=$(stat -c%s "$WSL_LIB/libcuda.so.1.1" 2>/dev/null || echo 0)
		note "$WSL_LIB/libcuda.so.1.1  $cl bytes ($( [ "$cl" -lt 1000000 ] && echo 'thin loader - expected' || echo 'looks like a payload copy') )"
	else
		warn "$WSL_LIB missing - no loaders at all"
	fi

	say "6. NVML (layer 2 of 4 - proves the monitoring path only)"
	if smi=$(nvidia_smi) && [ -n "$smi" ]; then
		smi_out=$("$smi" --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1)
		smi_rc=$?
		printf '%s\n' "$smi_out" | sed 's/^/  /'
		if [ "$smi_rc" -eq 0 ] && ! printf '%s' "$smi_out" | grep -qi 'failed\|blocked\|error'; then
			mark_ok "nvidia-smi answered"
		else
			mark_fail "nvidia-smi failed" "layer: $(classify_nvml "$smi_out")"
		fi
	else
		mark_fail "nvidia-smi not installed" "- the WSL userland libs normally provide it"
	fi

	say "7. load path (silent when it fails at boot)"
	local f
	for f in /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d; do [ -d "$f" ] && grep -rn 'dxgkrnl' "$f" 2>/dev/null; done | sed 's/^/  /'
	if ! { for f in /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d; do [ -d "$f" ] && grep -rqs 'dxgkrnl' "$f"; done; }; then
		note "no modprobe.d rule mentions dxgkrnl (good)"
	fi
	for f in /etc/systemd/system/load-dxg*.service /etc/systemd/system/gpupv*.service; do
		[ -e "$f" ] || continue
		local u en ac
		u=$(basename "$f")
		en=$(systemctl show -p UnitFileState --value "$u" 2>/dev/null)
		ac=$(systemctl show -p ActiveState   --value "$u" 2>/dev/null)
		note "unit $u: enabled=${en:-unknown} active=${ac:-unknown}"
	done
	if [ -r /var/log/load-dxg.log ]; then
		note "log /var/log/load-dxg.log ($(wc -l < /var/log/load-dxg.log) lines)"
	fi
	note "ld.so       $(tr '\n' ' ' < /etc/ld.so.conf.d/ld.wsl.conf 2>/dev/null || echo 'no ld.wsl.conf')"

	say "verdict"
	if [ "$GPUPV_FAILS" -eq 0 ]; then
		note "guest side looks intact. Run: $PROG verify   (NVML green is not success)"
	elif [ -n "$dxg_dir" ] && ! ds_verdict "$dxg_dir" >/dev/null; then
		note "DriverStore is trimmed -> install the host's complete nv_dispi folder:"
		note "  sudo $PROG driverstore install --src /path/to/nv_dispi.inf_amd64_<hash>"
	else
		note "see failed checks above; docs/troubleshooting.md maps each symptom to a layer"
	fi
	return "$GPUPV_FAILS"
}

# ====================== lib/verify.sh ======================
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

	say "gate 2/5: userland (loaders + payload)"
	# Both halves are required and they fail differently: no loaders means nothing
	# to call at all, a trimmed payload means nvidia-smi works and cuInit does not.
	local lc=0
	[ -e "$WSL_LIB/libcuda.so.1" ] && lc=$((lc + 1))
	[ -e "$WSL_LIB/libnvidia-ml.so.1" ] && lc=$((lc + 1))
	[ -e "$WSL_LIB/libdxcore.so" ] && lc=$((lc + 1))
	if [ "$lc" -eq 3 ]; then
		mark_ok "loaders present in $WSL_LIB"
	else
		mark_fail "loaders missing in $WSL_LIB ($lc/3)" "- deploy ExHyperV's lib/: sudo $PROG loaders install <lib dir>"
	fi

	local ds
	if ds=$(ds_pick); then
		local n ns
		n=$(count_entries "$ds"); ns=$(count_nonso "$ds")
		note "$ds: $n files, $ns non-.so"
		if [ "$n" -ge 150 ] && [ "$ns" -gt 0 ]; then
			mark_ok "driverstore complete"
		else
			mark_fail "driverstore trimmed" "expected ~150 files with metadata; see: $PROG driverstore install"
		fi
	else
		mark_fail "no DriverStore payload deployed" "$WSL_DRIVERS/$NVSTORE_GLOB"
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

# ====================== lib/doctor.sh ======================
# lib/doctor.sh - deep diagnosis for the "adapter opens, CUDA still dies" state.
#
# Order matters and this file enforces it:
#   1. driverstore shape (two ls|wc commands - explains most cuInit crashes)
#   2. offline module ABI gates on the RUNNING module
#   3. does a payload from /usr/lib/wsl/drivers get reached at all (LD_DEBUG)
#   4. hung probes / D-state tasks
# Nothing here mutates state.

cmd_doctor() {
	local src=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--src) src=$2; shift 2 ;;
			*) shift ;;
		esac
	done

	local ds mi
	ds=$(ds_pick || true)

	say "1. DriverStore shape (run this before any mechanism theory)"
	if [ -n "$ds" ]; then
		local n ns
		n=$(count_entries "$ds"); ns=$(count_nonso "$ds")
		note "path        $ds"
		if [ "$n" -lt 20 ] || [ "$ns" -eq 0 ]; then
			mark_fail "trimmed DriverStore" "$n files, $ns non-.so"
			note "this alone explains: NVML green + cuInit SIGSEGV at a constant offset."
			note "fix: sudo $PROG driverstore install /path/to/complete/nv_dispi.inf_amd64_<hash>"
		else
			mark_ok "DriverStore looks complete ($n files, $ns non-.so)"
		fi
		nvstore_keyfiles "$ds" | sed 's/^/  /'
	else
		mark_fail "no DriverStore directory" "$WSL_DRIVERS/$NVSTORE_GLOB"
	fi

	say "2. loader vs payload"
	local lc pc
	lc=$(stat -c%s "$WSL_LIB/libcuda.so.1.1" 2>/dev/null || echo 0)
	pc=$(stat -c%s "${ds:-/nonexistent}/libcuda.so.1.1" 2>/dev/null || echo 0)
	note "loader  $WSL_LIB/libcuda.so.1.1             $lc bytes"
	note "payload ${ds:-<no driverstore>}/libcuda.so.1.1  $pc bytes"
	if [ "$lc" -gt 5000000 ] && [ "$pc" -eq 0 ]; then
		warn "the loader directory holds a payload-sized libcuda but no payload directory - check ld.wsl.conf ordering"
	fi
	if [ -r "$WSL_LIB/libcuda.so.1.1" ] && strings "$WSL_LIB/libcuda.so.1.1" 2>/dev/null | grep -q dxcore_query_adapter_driverstore; then
		note "the loader asks DXCore for the payload path (dxcore_query_adapter_driverstore) - expected"
	fi
	sub "version stamped in the payload"
	local v
	v=$(strings "${ds:-/nonexistent}/libcuda.so.1.1" 2>/dev/null | grep -oE '5[0-9]{2}\.[0-9]{2}' | sort -u | tr '\n' ' ')
	note "${v:-unknown}  (version skew vs the host driver is normal, not a fault)"

	say "3. offline ABI gates on the running module"
	local ko="/lib/modules/$(kver)/updates/dkms/dxgkrnl.ko.xz"
	if [ -r "$ko" ]; then
		local tmp
		tmp=$(mktemp "${TMPDIR:-/tmp}/dxg.XXXXXX.ko")
		xz -dc "$ko" > "$tmp" 2>/dev/null
		note "module $ko"
		abi_gates_run "$tmp" "$(find_uapi_header || echo '')" \
			| sed 's/^/  /' || true
		rm -f "$tmp"
	elif [ -r "/lib/modules/$(kver)/updates/dkms/dxgkrnl.ko" ]; then
		note "uncompressed module found"
		abi_gates_run "/lib/modules/$(kver)/updates/dkms/dxgkrnl.ko" | sed 's/^/  /'
	else
		warn "no dxgkrnl.ko under /lib/modules/$(kver)/updates/dkms - where did it come from?"
	fi
	if [ -d /sys/module/dxgkrnl ]; then
		note "loaded srcversion $(cat /sys/module/dxgkrnl/srcversion 2>/dev/null || echo '?')"
	fi

	say "4. is a payload from $WSL_DRIVERS reached at all?"
	local smi
	smi=$(nvidia_smi)
	if [ -n "$smi" ] && have timeout; then
		local trace
		trace=$(timeout 30 env LD_DEBUG=files "$smi" --query-gpu=name --format=csv,noheader 2>&1 | grep -E 'calling init|trying file' | grep -c "$WSL_DRIVERS" || true)
		note "trace lines naming $WSL_DRIVERS: ${trace:-0}"
		if [ "${trace:-0}" -gt 0 ]; then
			mark_ok "a payload under $WSL_DRIVERS was dlopen'ed"
		else
			mark_fail "no payload under $WSL_DRIVERS reached" "- the fault is upstream of the payload (module/DXCore); swapping libs cannot fix it"
		fi
	fi

	say "5. hung probes / uninterruptible tasks"
	local d
	d=$(ps -eo pid,stat,cmd 2>/dev/null | awk '$2 ~ /D/ {print}' | head -10)
	if [ -n "$d" ]; then
		printf '%s\n' "$d" | sed 's/^/  /'
		warn "a D-state modprobe is unkillable - only a guest reboot clears it"
		note "a D-state modprobe plus all-zero PCI BARs = host gave no MMIO; a NULL-deref oops in dmesg = wrong hyperv.h at build time"
	else
		mark_ok "no uninterruptible tasks"
	fi
	local oops
	oops=$(dmesg 2>/dev/null | grep -E 'BUG: kernel NULL pointer|dxg_probe_vmbus\+' | tail -3 || true)
	[ -n "$oops" ] && { note "recent oops:"; printf '%s\n' "$oops" | sed 's/^/  /'; }

	say "6. modprobe policy and loaders"
	local hits
	hits=$(for f in /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d; do
		[ -d "$f" ] && grep -rn 'dxgkrnl' "$f" 2>/dev/null
	done)
	if [ -n "$hits" ]; then
		printf '%s\n' "$hits" | sed 's/^/  /'
		if printf '%s' "$hits" | grep -qE 'install +dxgkrnl +/bin/false|blacklist +dxgkrnl'; then
			mark_fail "modprobe policy blocks dxgkrnl" "- delete the file BY NAME from the list above (not a guessed filename)"
		fi
	else
		mark_ok "no blocking modprobe.d rule"
	fi
	local cfg
	cfg=$(ls -1 /usr/local/bin/load_dxg_driver.sh /usr/local/bin/*dxg*loader*.sh 2>/dev/null | sort -u)
	if [ -n "$cfg" ]; then
		for cfg in $cfg; do
			local kline
			kline=$(grep -m1 '^KERNEL=' "$cfg" 2>/dev/null || echo 'no KERNEL= line')
			note "loader $cfg: $kline"
			case "$kline" in
				*'$(uname -r)'*|'no KERNEL= line') : ;;
				*) mark_fail "loader hard-codes a kernel" "$cfg: $kline" ;;
			esac
		done
	fi
	if [ -e /etc/systemd/system/load-dxg-late.service ]; then
		note "unit     load-dxg-late.service ($(systemctl show -p UnitFileState --value load-dxg-late.service 2>/dev/null), WantedBy=$(grep -A2 '^\[Install\]' /etc/systemd/system/load-dxg-late.service | grep -o 'graphical.target\|multi-user.target' | head -1))"
	fi

	summary "doctor checks"
	if [ "$GPUPV_FAILS" -eq 0 ]; then
		note "no structural fault found - run: $PROG verify (and read docs/troubleshooting.md)"
	fi
	return "$GPUPV_FAILS"
}

# --- markdown evidence report -------------------------------------------
cmd_report() {
	local out="gpupv-report-$(date +%Y%m%d-%H%M%S).md"
	while [ $# -gt 0 ]; do
		case "$1" in
			--out) out=$2; shift 2 ;;
			*) shift ;;
		esac
	done
	local ds
	ds=$(ds_pick || true)
	{
		echo "# GPU-PV report - $(hostname) - $(date)"
		echo
		echo "## Summary"
		echo
		echo "| item | value |"
		echo "|---|---|"
		echo "| kernel | \`$(kver)\` |"
		echo "| dxgkrnl loaded | \`$(lsmod 2>/dev/null | awk '$1=="dxgkrnl"{print "yes ("$2" bytes)"}')\` |"
		echo "| /dev/dxg | \`$([ -e /dev/dxg ] && echo present || echo absent)\` |"
		echo "| driverstore | \`${ds:-none}\` ($( [ -n "$ds" ] && echo "$(count_entries "$ds") files, $(count_nonso "$ds") non-.so" || echo '-')) |"
		echo "| nvidia-smi | \`$(nvidia_smi || echo missing)\` |"
		echo
		echo "## VMBus channels"
		echo
		echo '```'
		for d in /sys/bus/vmbus/devices/*/; do
			[ -d "$d" ] || continue
			c=$(cat "$d/class_id" 2>/dev/null || true)
			case "$c" in
				*6e382d18*|*dde9cbc0*)
					echo "$(basename "$d") class=$c state=$(cat "$d/state" 2>/dev/null) driver=$(readlink "$d/driver" 2>/dev/null || echo none)"
					;;
			esac
		done
		echo '```'
		echo
		echo "## Functional gates"
		echo
		echo '```'
		( cmd_verify "$@" ) 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
		echo '```'
		echo
		echo "## DriverStore contents"
		echo
		echo '```'
		[ -n "$ds" ] && ls -1 "$ds" | head -200
		echo '```'
		echo
		echo "## Loader log (tail)"
		echo
		echo '```'
		tail -40 /var/log/load-dxg.log 2>/dev/null || echo "(no /var/log/load-dxg.log)"
		echo '```'
		echo
		echo "## dmesg (dxg lines)"
		echo
		echo '```'
		dmesg 2>/dev/null | grep -iE 'dxg|dxcore|nvidia' | tail -40 || echo "(dmesg not readable without root)"
		echo '```'
		echo
		echo "_generated by $PROG $GPUPV_VERSION - $(date -u +%Y-%m-%dT%H:%M:%SZ)_"
	} > "$out"
	note "wrote $out ($(wc -l < "$out") lines)"
	printf '%s\n' "$out"
}

# ====================== lib/module.sh ======================
# lib/module.sh - build dxgkrnl from the WSL kernel branch, for THIS kernel.
#
# Two rules that cost this project days:
#   1. Never compile dxgmodule.c against the WSL branch's include/linux/hyperv.h.
#      That swaps the kernel's struct hv_device for the branch's, probe reads
#      hdev->channel at the wrong offset, NULL-derefs holding device_mutex, and
#      modprobe parks in D with a matching vermagic - every "is this build OK"
#      check passes. Use the kernel's own header plus only the GPU-PV GUIDs.
#   2. Branch selection comes from uname -r, not from whichever script is at
#      hand. 6.6.y-era sources on a 6.13+ kernel fail in ways that look like
#      driver bugs.

MOD_BRANCHES_18="linux-msft-wsl-6.18.y"
MOD_BRANCHES_66="linux-msft-wsl-6.6.y"
MOD_KBASE="https://raw.githubusercontent.com"
MOD_KDIR="drivers/hv/dxgkrnl"
MOD_FILES="dxgadapter.c dxgkrnl.h dxgmodule.c dxgprocess.c dxgsyncfile.c dxgsyncfile.h dxgvmbus.c dxgvmbus.h hmgr.c hmgr.h ioctl.c misc.c misc.h Kconfig"

_mod_pick_branch() {
	local want=${1:-auto} k
	k=$(kver)
	case "$want" in
		auto)
			# kernel >= 6.13 -> 6.18.y branch; older -> 6.6.y branch
			case "$k" in
				6.1[3-9]*|6.[2-9][0-9]*|[7-9].*) echo "$MOD_BRANCHES_18" ;;
				*) echo "$MOD_BRANCHES_66" ;;
			esac
			;;
		wsl-6.18.y|6.18.y) echo "$MOD_BRANCHES_18" ;;
		wsl-6.6.y|6.6.y)  echo "$MOD_BRANCHES_66" ;;
		*) echo "$want" ;;
	esac
}

_mod_write_gpup_header() {
	local out=$1
	cat > "$out" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/* GPU-PV (partitioning) VMBus device-type GUIDs.
 *
 * The guest kernel's own <linux/hyperv.h> does not carry these, and replacing
 * that header with the WSL branch's copy changes struct hv_device - which
 * breaks the driver at probe time with a matching vermagic. So: keep the
 * kernel header, add only what is missing. Generated by gpupv.sh. */
#ifndef _LINUX_HYPERV_GPUP_H
#define _LINUX_HYPERV_GPUP_H

#ifndef HV_GPUP_DXGK_GLOBAL_GUID
#define HV_GPUP_DXGK_GLOBAL_GUID \
	.guid = GUID_INIT(0xdde9cbc0, 0x5060, 0x4436, 0x94, 0x48, \
			  0xea, 0x12, 0x54, 0xa5, 0xd1, 0x77)
#endif
#ifndef HV_GPUP_DXGK_VGPU_GUID
#define HV_GPUP_DXGK_VGPU_GUID \
	.guid = GUID_INIT(0x6e382d18, 0x3336, 0x4f4b, 0xac, 0xc4, \
			  0x2b, 0x77, 0x3, 0xd4, 0xdf, 0x4a)
#endif

#endif /* _LINUX_HYPERV_GPUP_H */
EOF
}

_mod_apply_port() {
	# Port 6.6.y-era sources onto a newer API surface. Idempotent.
	local d=$1 k=$2
	local major minor
	major=${k%%.*}
	minor=$(printf '%s' "${k#*.}" | cut -d. -f1)

	# eventfd_signal lost its second argument in 6.2+
	sed -i 's/eventfd_signal(\([^,]*\), *1)/eventfd_signal(\1)/g' "$d"/*.c 2>/dev/null || true

	# vzalloc/vfree/vmap/vunmap need an explicit include on newer kernels
	# (handled with -include linux/vmalloc.h in the generated Makefile)

	# __get_task_comm(s, len, task) -> get_task_comm(buf, tsk) in 6.10+
	if [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 10 ]; }; then
		sed -i 's/__get_task_comm(s, WIN_MAX_PATH, current)/get_task_comm(s, current)/' "$d"/dxgvmbus.c 2>/dev/null || true
	fi

	# dma_fence_ops.fence_value_str / .timeline_value_str were removed in 6.13;
	# keeping the initialisers is a hard compile error, and the callbacks become
	# dead code once the ops struct no longer has the slots.
	if [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 13 ]; }; then
		if [ -f "$d/dxgsyncfile.c" ]; then
			# drop the two initialiser lines outright (a commented-out member
			# leaves a dangling identifier and still fails to compile), then
			# mark the now-unreferenced callbacks unused so -Werror stays quiet
			sed -i -E '/^[[:space:]]*\.(fence_value_str|timeline_value_str)[[:space:]]*=/d' "$d/dxgsyncfile.c"
			sed -i -E 's/^static void (dxgdmafence_(value_str|timeline_value_str))[(]/static void __attribute__((unused)) \1(/' "$d/dxgsyncfile.c"
		fi
	fi
}

cmd_module_build() {
	local branch=auto out="" dkms=0 jobs
	while [ $# -gt 0 ]; do
		case "$1" in
			--branch) branch=$2; shift 2 ;;
			--out)    out=$2; shift 2 ;;
			--dkms)   dkms=1; shift ;;
			*) shift ;;
		esac
	done
	have make || die "make not found"
	have curl || die "curl not found"
	# A stock fnOS has make but no gcc: fail here with the package list instead
	# of inside kbuild as "/bin/sh: 1: gcc: not found / Error 127".
	deps_ensure || exit 1
	local k
	k=$(kver)
	[ -d "/lib/modules/$k/build" ] || die "no kernel build tree at /lib/modules/$k/build (install linux-headers-$k)"

	branch=$(_mod_pick_branch "$branch")
	out=${out:-$CACHE_DIR/dxgkrnl-$k}
	[ -d "$out" ] && [ -f "$out/dxgkrnl.ko" ] && { rm -rf "$out"; }

	say "module build"
	note "kernel    $k"
	note "branch    $branch"
	note "tree      $out"

	rm -rf "$out"
	mkdir -p "$out/include/libdxg/dxg" "$out/include/uapi/misc" "$out/include/linux"

	local base="$MOD_KBASE/microsoft/WSL2-Linux-Kernel/$branch"
	local f fail=0
	for f in $MOD_FILES; do
		fetch "$base/$MOD_KDIR/$f" "$out/$f" || { warn "FAIL $f"; fail=1; }
	done
	fetch "$base/include/uapi/misc/d3dkmthk.h" "$out/include/uapi/misc/d3dkmthk.h" || { warn "FAIL uapi/d3dkmthk.h"; fail=1; }
	for f in d3dkmdt.h d3dkmthk.h d3dukmdt.h; do
		fetch "https://raw.githubusercontent.com/microsoft/libdxg/master/include/dxg/$f" "$out/include/libdxg/dxg/$f" || { warn "FAIL libdxg $f"; fail=1; }
	done
	[ "$fail" -eq 0 ] || die "source fetch failed (network?)"
	mark_ok "sources fetched"

	_mod_write_gpup_header "$out/include/linux/hyperv_gpup.h"
	# the branch ships either a kernel-header include or a renamed copy; normalise
	if [ -f "$out/dxgmodule.c" ]; then
		sed -i 's#<linux/hyperv_dxgkrnl.h>#<linux/hyperv.h>#' "$out/dxgmodule.c"
		if grep -q '#include <linux/hyperv.h>' "$out/dxgmodule.c"; then
			sed -i 's@#include <linux/hyperv.h>@#include <linux/hyperv.h>\n#include <linux/hyperv_gpup.h>@' "$out/dxgmodule.c"
		fi
	fi
	rm -f "$out/include/linux/hyperv_dxgkrnl.h"

	_mod_apply_port "$out" "$k"

	local vmh=""
	case "$branch" in
		*6.6.y*) vmh='-include linux/vmalloc.h' ;;
	esac
	cat > "$out/Makefile" <<EOF
obj-m += dxgkrnl.o
dxgkrnl-y := dxgmodule.o hmgr.o misc.o dxgadapter.o ioctl.o dxgvmbus.o dxgprocess.o dxgsyncfile.o
ccflags-y += -I\$(src)/include -I\$(src)/include/libdxg -I\$(src)/include/uapi \\
  -DMAIN_KERNEL -DCONFIG_DXGKRNL=m \\
  ${vmh} -include linux/types.h \\
  -include \$(src)/include/uapi/misc/d3dkmthk.h \\
  -include linux/hyperv_gpup.h \\
  -Wno-empty-body
EOF
	jobs=$(nproc 2>/dev/null || echo 2)
	sub "compiling (make -j$jobs)"
	local log="$out/build.log"
	# Never read a build verdict through a pipe.
	if make -C "/lib/modules/$k/build" M="$out" -j"$jobs" > "$log" 2>&1; then
		mark_ok "compiled"
	else
		mark_fail "compile failed" "see $log"
		grep -E 'error|Error' "$log" | head -15 | sed 's/^/  /'
		# The two failures that are not a code problem: a missing compiler and a
		# missing tool. Name the fix instead of leaving Error 127 bare.
		if grep -qE 'gcc: not found|cc1: not found|Error 127' "$log"; then
			note ""
			note "the compiler is missing, not the source:  sudo $PROG deps --install"
		elif grep -qE 'objtool|resolve_btfids|make.*: .*No such file' "$log"; then
			note ""
			note "kbuild tool missing (objtool / resolve_btfids) - install the kernel toolchain:"
			note "  sudo $PROG deps --install"
		fi
		return 1
	fi
	grep -E 'unreachable instruction|Skipping BTF' "$log" >/dev/null 2>&1 && \
		note "(objtool unreachable-instruction / skipped BTF notices are expected and harmless)"

	local ko="$out/dxgkrnl.ko"
	[ -f "$ko" ] || die "no dxgkrnl.ko produced"
	note "ko        $ko ($(stat -c%s "$ko") bytes)"
	note "vermagic  $(strings "$ko" | grep -m1 '^vermagic=')"

	sub "offline ABI gates"
	if abi_gates_run "$ko" "$out/include/uapi/misc/d3dkmthk.h"; then
		mark_ok "ABI gates passed"
	else
		mark_fail "ABI gates" "- do not insmod this .ko"
		return 1
	fi

	if [ "$dkms" -eq 1 ]; then
		_mod_dkms_install "$out" "$k"
	fi
	note ""
	note "install:  sudo $PROG module install $ko"
	note "or test:  sudo $PROG module install $ko --no-backup   (see --help)"
	return 0
}

_mod_dkms_install() {
	local src=$1 k=$2 ver
	have dkms || { warn "dkms not installed; skipping DKMS registration"; return 0; }
	ver="gpupv-$(date +%Y%m%d%H%M)"
	cat > "$src/dkms.conf" <<EOF
PACKAGE_NAME="dxgkrnl"
PACKAGE_VERSION="$ver"
BUILT_MODULE_NAME[0]="dxgkrnl"
DEST_MODULE_LOCATION[0]="/kernel/drivers/hv/dxgkrnl/"
AUTOINSTALL="yes"
MAKE[0]="make -j\$(nproc) KERNELRELEASE=\${kernelver} -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build"
EOF
	sub "dkms add/build/install ($ver)"
	dkms add     -m dxgkrnl -v "$ver" >/dev/null 2>&1 || warn "dkms add failed"
	dkms build   -m dxgkrnl -v "$ver" -k "$k" >/dev/null 2>&1 || { warn "dkms build failed; tail /var/lib/dkms/dxgkrnl/$ver/build/make.log"; return 1; }
	dkms install -m dxgkrnl -v "$ver" -k "$k" --force >/dev/null 2>&1 || { warn "dkms install failed"; return 1; }
	mark_ok "dkms installed dxgkrnl/$ver for $k (survives kernel bumps only after a rebuild)"
}

cmd_module_verify() {
	local ko=${1:-} tmp=""
	[ -n "$ko" ] && [ -f "$ko" ] || die "usage: $PROG module verify <dxgkrnl.ko|ko.xz>"
	case "$ko" in
		*.xz)
			# the gates read .modinfo and disassemble, so a compressed module has
			# to be decompressed first - otherwise they fail for the wrong reason
			have xz || die "xz not found (needed to read $ko)"
			tmp=$(mktemp "${TMPDIR:-/tmp}/gpupv-verify.XXXXXX.ko")
			xz -dc "$ko" > "$tmp" || die "cannot decompress $ko"
			abi_gates_run "$tmp"; local rc=$?
			rm -f "$tmp"; return $rc ;;
		*) abi_gates_run "$ko" ;;
	esac
}

MOD_BACKUP_ROOT="${MOD_BACKUP_ROOT:-/var/lib/gpupv/module-backup}"

cmd_module_install() {
	local ko=${1:-} nobackup=0 live=0
	[ $# -gt 0 ] && shift
	while [ $# -gt 0 ]; do
		case "$1" in
			--no-backup) nobackup=1; shift ;;
			--live) live=1; shift ;;
			*) shift ;;
		esac
	done
	[ -n "$ko" ] && [ -f "$ko" ] || die "usage: sudo $PROG module install <dxgkrnl.ko>"
	need_root module install KO
	local k
	k=$(kver)
	local vm
	vm=$(strings "$ko" | grep -m1 '^vermagic=' | sed 's/^vermagic=//')
	case "$vm" in
		"$k"*) : ;;
		*) die "vermagic [$vm] does not match running kernel [$k] - refusing to load" ;;
	esac

	say "module install"
	note "ko        $ko"
	note "vermagic  $vm"
	local xz="${ko}.xz"
	xz -T0 -c "$ko" > "$xz" || die "xz failed"

	local stamp dst
	stamp=$(date +%Y%m%d-%H%M%S)
	dst="/lib/modules/$k/updates/dkms/dxgkrnl.ko.xz"
	if [ -e "$dst" ] && [ "$nobackup" -eq 0 ]; then
		mkdir -p "$MOD_BACKUP_ROOT/$stamp"
		cp -a "$dst" "$MOD_BACKUP_ROOT/$stamp/dxgkrnl.ko.xz"
		note "backup    $MOD_BACKUP_ROOT/$stamp/dxgkrnl.ko.xz"
	fi

	if lsmod | grep -q '^dxgkrnl'; then
		sub "unloading current module"
		if ! { modprobe -r dxgkrnl 2>/dev/null || rmmod dxgkrnl 2>/dev/null; }; then
			die "cannot unload dxgkrnl (a hung probe parks forever - reboot the guest)"
		fi
		mark_ok "unloaded"
	fi

	mkdir -p "$(dirname "$dst")"
	install -m 644 "$xz" "$dst"
	depmod -a "$k"
	mark_ok "installed $dst"

	sub "loading"
	modprobe dxgkrnl || { warn "modprobe failed"; dmesg | tail -20 | sed 's/^/  /'; return 1; }
	sleep 1
	lsmod | grep '^dxgkrnl' | sed 's/^/  /'
	[ -e /dev/dxg ] && mark_ok "/dev/dxg created" || mark_fail "/dev/dxg missing" "- see: dmesg | tail -50; $PROG doctor"

	[ "$live" -eq 1 ] && return 0
	sub "first functional gate"
	timeout 60 python3 -c 'import ctypes; print("  cuInit", ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1").cuInit(0))' 2>&1
	note "run: $PROG verify"
}

cmd_module_restore() {
	need_root module restore
	local k
	k=$(kver)
	if [ "${1:-}" = "--list" ]; then
		ls -1 "$MOD_BACKUP_ROOT" 2>/dev/null || note "no backups"
		return 0
	fi
	local last
	last=$(ls -1 "$MOD_BACKUP_ROOT" 2>/dev/null | sort | tail -1)
	[ -n "$last" ] || die "no backup under $MOD_BACKUP_ROOT"
	say "module restore"
	note "restoring $MOD_BACKUP_ROOT/$last/dxgkrnl.ko.xz"
	modprobe -r dxgkrnl 2>/dev/null || true
	install -m 644 "$MOD_BACKUP_ROOT/$last/dxgkrnl.ko.xz" "/lib/modules/$k/updates/dkms/dxgkrnl.ko.xz" || die "restore failed"
	depmod -a "$k"
	modprobe dxgkrnl 2>/dev/null || warn "modprobe failed after restore"
	note "done"
}

cmd_module() {
	local sub=${1:-build}
	[ $# -gt 0 ] && shift
	case "$sub" in
		build)   cmd_module_build "$@" ;;
		verify)  cmd_module_verify "$@" ;;
		install) cmd_module_install "$@" ;;
		restore) cmd_module_restore "$@" ;;
		*) die "unknown: module $sub (build|verify|install|restore)" ;;
	esac
}

# ====================== lib/driverstore.sh ======================
# lib/driverstore.sh - the host's nv_dispi DriverStore in the guest.
#
# Why this file exists: the deployed guest copy is frequently a hand-picked
# `.so` subset (18 files, zero metadata) while the host's folder holds ~153
# files. With the metadata missing, libcuda cannot populate its adapter object
# and cuInit segfaults at a constant offset while NVML still prints a table.
# No amount of library swapping fixes that - only the complete directory does.

DS_BACKUP="${DS_BACKUP:-/var/lib/gpupv/driverstore-backup}"

_ds_target() {
	if [ -n "${1:-}" ]; then
		[ -d "$1" ] || die "not a directory: $1"
		printf '%s\n' "$1"
		return 0
	fi
	ds_pick && return 0
	# Nothing deployed yet: a fresh guest has no $WSL_DRIVERS at all, so this is
	# the normal state before the first install - not an error.
	return 1
}

# The folder name DXCore asks for is the HOST's nv_dispi.inf_amd64_<hash> leaf.
# On a fresh guest there is nothing to read it from, so take it from the incoming
# directory (or --name), and refuse to invent one: a wrong name is invisible
# until cuInit fails.
_ds_target_for_install() {
	local explicit=${1:-} src=${2:-} name=${3:-}

	if [ -n "$explicit" ]; then
		[ -d "$explicit" ] || die "not a directory: $explicit"
		printf '%s\n' "$explicit"
		return 0
	fi
	if ds_pick 2>/dev/null; then return 0; fi

	if [ -z "$name" ] && [ -n "$src" ]; then
		case "$(basename "$src")" in
			$NVSTORE_GLOB) name=$(basename "$src") ;;
		esac
	fi
	[ -n "$name" ] || die "no DriverStore folder deployed yet, and the incoming path does not name one.
       Pass the folder itself (…/$NVSTORE_GLOB) or --name nv_dispi.inf_amd64_<hash>."
	case "$name" in
		$NVSTORE_GLOB) : ;;
		*) die "--name [$name] does not look like $NVSTORE_GLOB" ;;
	esac
	printf '%s/%s\n' "$WSL_DRIVERS" "$name"
}

# compare the deployed copy against an incoming one: same build, or a
# different driver version? The two answers mean completely different things.
cmd_ds_compare() {
	local incoming=${1:-}
	[ -n "$incoming" ] || die "usage: $PROG driverstore compare <incoming dir> [--driverstore DIR]"
	shift || true
	local target=""
	target=$(_ds_target "") || target=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--driverstore) target=$(_ds_target "$2"); shift 2 ;;
			*) shift ;;
		esac
	done
	[ -d "$incoming" ] || die "not a directory: $incoming"

	say "driverstore compare"
	if [ -z "$target" ]; then
		# Fresh guest: nothing is deployed, so the comparison is trivially "all of
		# it is new". Say that instead of failing an ls on a missing directory.
		note "deployed  none (nothing under $WSL_DRIVERS)"
		note "incoming  $incoming ($(count_entries "$incoming") files)"
		say "verdict"
		note "no deployment yet - this is a first install, not a repair:"
		note "  sudo $PROG driverstore install $incoming"
		return 0
	fi
	note "deployed  $target ($(count_entries "$target") files)"
	note "incoming  $incoming ($(count_entries "$incoming") files)"

	local f a b differing=0 onlyin=0 onlyout=0
	for f in $(ls -1 "$target" 2>/dev/null); do
		if [ ! -e "$incoming/$f" ]; then
			onlyout=$((onlyout + 1)); continue
		fi
		a=$(sha256sum "$incoming/$f" 2>/dev/null | cut -c1-16)
		b=$(sha256sum "$target/$f" 2>/dev/null | cut -c1-16)
		if [ "$a" != "$b" ]; then
			printf '  %sDIFFERENT BUILD%s %s incoming=%s deployed=%s\n' "$C_RED" "$C_OFF" "$f" "$a" "$b"
			differing=$((differing + 1))
		fi
	done
	for f in $(ls -1 "$incoming" 2>/dev/null); do
		[ -e "$target/$f" ] || onlyin=$((onlyin + 1))
	done

	note ""
	note "identical-overlap -> differing=$differing"
	note "incoming-only=$onlyin  deployed-only=$onlyout"
	say "verdict"
	if [ "$differing" -gt 0 ]; then
		note "different driver BUILD: replace the whole directory, do not merge."
		note "  sudo $PROG driverstore install $incoming --replace"
	elif [ "$onlyin" -gt 0 ] && [ "$onlyout" -eq 0 ]; then
		note "same build, DEPLOYED copy is the trimmed one: overlay is safe (this is the fix)."
		note "  sudo $PROG driverstore install $incoming"
	elif [ "$onlyin" -gt 0 ]; then
		note "same build, incoming adds $onlyin files (deployed has $onlyout the incoming lacks):"
		note "overlay adds the missing ones and keeps the rest - normal for a payload copied"
		note "from a slightly different source directory."
		note "  sudo $PROG driverstore install $incoming"
	elif [ "$onlyout" -gt 0 ]; then
		note "INCOMING IS A SUBSET of the deployed copy ($onlyout files missing)."
		note "installing it would trim a complete deployment - refusing to recommend it."
		note "you need the host's FULL nv_dispi.inf_amd64_<hash> folder (~150 files)."
	else
		note "no difference; look elsewhere (module / host side)."
	fi
	return 0
}

cmd_ds_status() {
	local target
	if ! target=$(_ds_target "${1:-}"); then
		say "driverstore status"
		mark_fail "no DriverStore deployed" "nothing under $WSL_DRIVERS"
		note "this is normal before the first install:"
		note "  sudo $PROG driverstore install /tmp/nvstore"
		return "$GPUPV_FAILS"
	fi
	say "driverstore status"
	note "path   $target"
	note "count  $(count_entries "$target") files, $(count_nonso "$target") non-.so"
	if v=$(ds_verdict "$target"); then mark_ok "$v"; else mark_fail "$v"; fi
	sub "key files"
	nvstore_keyfiles "$target"
	sub "backup"
	if [ -d "$DS_BACKUP" ]; then
		note "$DS_BACKUP ($(count_entries "$DS_BACKUP") files, $(du -sh "$DS_BACKUP" 2>/dev/null | cut -f1))"
	else
		note "none at $DS_BACKUP"
	fi
	sub "loader vs payload (sizes are the tell)"
	note "$WSL_LIB/libcuda.so.1.1        $(stat -c%s "$WSL_LIB/libcuda.so.1.1" 2>/dev/null || echo -) bytes  (loader ~171KB)"
	note "$target/libcuda.so.1.1  $(stat -c%s "$target/libcuda.so.1.1" 2>/dev/null || echo -) bytes  (payload ~25MB)"
	return "$GPUPV_FAILS"
}

cmd_ds_install() {
	local src=${1:-}
	[ -n "$src" ] || die "usage: sudo $PROG driverstore install <incoming dir|…/$NVSTORE_GLOB> [--replace] [--name DIRNAME] [--driverstore DIR]"
	shift || true
	local replace=0 target="" force=0 name=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--replace) replace=1; shift ;;
			--driverstore) target=$2; shift 2 ;;
			--name) name=$2; shift 2 ;;
			--force) force=1; shift ;;
			*) shift ;;
		esac
	done
	need_root driverstore install DIR
	[ -d "$src" ] || die "not a directory: $src"

	local nsrc
	nsrc=$(count_entries "$src")
	[ "$nsrc" -gt 0 ] || die "incoming directory is empty"

	# Resolve the destination BEFORE anything is created: on a fresh guest the
	# folder does not exist yet, and its name has to come from the host's leaf.
	target=$(_ds_target_for_install "$target" "$src" "$name")

	local target_existed=1
	[ -d "$target" ] || target_existed=0

	say "driverstore install"
	note "incoming  $src ($nsrc files, $(du -sh "$src" 2>/dev/null | cut -f1))"
	if [ "$target_existed" -eq 1 ]; then
		note "target    $target ($(count_entries "$target") files)"
	else
		note "target    $target (does not exist yet - first install)"
	fi

	# Refuse the mistake that looks like a fix: installing a trimmed set.
	if [ "$nsrc" -lt 100 ] && [ "$force" -eq 0 ]; then
		die "incoming set has only $nsrc files - a complete nv_dispi folder has ~150. Refusing (pass --force to override)."
	fi

	mkdir -p "$target" || die "cannot create $target"

	# Backup once, never overwrite a good backup with a broken state - but an
	# existing EMPTY directory is not a backup (a failed or aborted first run
	# leaves one behind, and "reusing" it makes rollback restore nothing).
	if [ "$target_existed" -eq 0 ]; then
		note "backup    n/a (nothing deployed to back up)"
	elif [ ! -d "$DS_BACKUP" ] || [ -z "$(ls -A "$DS_BACKUP" 2>/dev/null)" ]; then
		mkdir -p "$(dirname "$DS_BACKUP")"
		# cp -a INTO an existing directory nests it, so clear it first
		rm -rf "$DS_BACKUP"
		cp -a "$target" "$DS_BACKUP" || die "backup failed - nothing changed"
		note "backup    $DS_BACKUP ($(count_entries "$DS_BACKUP") files)"
	else
		note "backup    reusing $DS_BACKUP ($(count_entries "$DS_BACKUP") files)"
	fi

	if [ "$replace" -eq 1 ]; then
		note "mode      REPLACE (different driver build)"
		rm -rf "$target" && cp -a "$src" "$target" || die "replace failed - restore: $PROG driverstore rollback"
	else
		note "mode      OVERLAY (add/replace, delete nothing the guest already has)"
		cp -a "$src/." "$target/" || die "copy failed - restore: $PROG driverstore rollback"
	fi
	chmod -R a+r "$target" 2>/dev/null || true
	# the <hash> folder itself must be traversable, not just its files
	chmod a+rx "$WSL_DRIVERS" "$target" 2>/dev/null || true

	note "after     $(count_entries "$target") files, $(count_nonso "$target") non-.so"
	nvstore_keyfiles "$target" | sed 's/^/  /'

	# The loaders live in $WSL_LIB and only find the payload through ld.so; both
	# directories have to be on the search path or the payload is never reached.
	# Report a write failure instead of claiming the line was added.
	if [ ! -e /etc/ld.so.conf.d/ld.wsl.conf ]; then
		if mkdir -p /etc/ld.so.conf.d 2>/dev/null &&
		   printf '%s\n%s\n' "$WSL_LIB" "$WSL_DRIVERS" > /etc/ld.so.conf.d/ld.wsl.conf 2>/dev/null; then
			note "wrote /etc/ld.so.conf.d/ld.wsl.conf"
		else
			warn "cannot write /etc/ld.so.conf.d/ld.wsl.conf (needs root)"
			note "  echo -e '$WSL_LIB\\n$WSL_DRIVERS' | sudo tee /etc/ld.so.conf.d/ld.wsl.conf && sudo ldconfig"
		fi
	else
		local d added=0
		for d in "$WSL_LIB" "$WSL_DRIVERS"; do
			grep -qx "$d" /etc/ld.so.conf.d/ld.wsl.conf 2>/dev/null && continue
			# the redirect must be silenced in a subshell: `cmd >> f 2>/dev/null`
			# still prints the shell's own "Permission denied" for the redirect
			if ( printf '%s\n' "$d" >> /etc/ld.so.conf.d/ld.wsl.conf ) 2>/dev/null; then
				note "added $d to /etc/ld.so.conf.d/ld.wsl.conf"
				added=1
			else
				warn "cannot append $d to /etc/ld.so.conf.d/ld.wsl.conf (needs root)"
			fi
		done
		[ "$added" -eq 1 ] && have ldconfig && ldconfig 2>/dev/null || true
	fi
	have ldconfig && ldconfig 2>/dev/null || true

	say "real consumer test (never nvidia-smi)"
	if [ ! -e "$WSL_LIB/libcuda.so.1" ]; then
		mark_fail "cannot test cuInit: $WSL_LIB/libcuda.so.1 missing" \
			"- the loaders are not deployed (they come from ExHyperV's lib/), the payload alone cannot run"
		note "the DriverStore copy above is still correct; install the loaders, then re-run: $PROG verify"
		return "$GPUPV_FAILS"
	fi
	local rc
	timeout 60 python3 -c 'import ctypes,sys; sys.exit(0 if ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1").cuInit(0)==0 else 1)'
	rc=$?
	if [ "$rc" -eq 0 ]; then
		mark_ok "cuInit 0"
		note "now run: $PROG verify"
	else
		mark_fail "cuInit" "rc=$rc (139 = SIGSEGV)"
		note "payload is in place but CUDA still fails. Roll back: sudo $PROG driverstore rollback"
		note "then: $PROG doctor   (module ABI + LD_DEBUG trace, in that order)"
	fi
	return "$GPUPV_FAILS"
}

cmd_ds_rollback() {
	need_root driverstore rollback
	local target=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--driverstore) target=$2; shift 2 ;;
			*) shift ;;
		esac
	done
	target=$(_ds_target "$target")
	[ -d "$DS_BACKUP" ] || die "no backup at $DS_BACKUP"
	say "driverstore rollback"
	rm -rf "$target" && cp -a "$DS_BACKUP" "$target" || die "rollback copy failed"
	chmod -R a+r "$target"
	note "restored $target ($(count_entries "$target") files)"
	ldconfig 2>/dev/null || true
	timeout 60 python3 -c 'import ctypes; print("  cuInit", ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1").cuInit(0))'
}

cmd_driverstore() {
	local sub=${1:-status}
	[ $# -gt 0 ] && shift
	case "$sub" in
		status)              cmd_ds_status "$@" ;;
		compare|diff)        cmd_ds_compare "$@" ;;
		install)             cmd_ds_install "$@" ;;
		rollback|restore)    cmd_ds_rollback "$@" ;;
		*) die "unknown: driverstore $sub (status|compare|install|rollback)" ;;
	esac
}

# ====================== lib/loaders.sh ======================
# lib/loaders.sh - deploy ExHyperV's `lib/` folder: the thin loaders in
# /usr/lib/wsl/lib that turn the DriverStore payload into something applications
# can call.
#
# Two directories, two jobs (both are required; neither alone is enough):
#   /usr/lib/wsl/lib          loaders      libcuda.so.1.1 ~171 KB, libnvidia-ml.so.1 ~267 KB,
#                                          libdxcore.so, libd3d12*.so, nvidia-smi
#   /usr/lib/wsl/drivers/<f>  payload      libcuda.so.1.1 ~25 MB + every data file
#
# The loaders ask DXCore for the payload's driver-store path and dlopen it from
# there, so the driver directory must also be on ld.so's search path. Deploying
# them by hand is where most stalled installs stop: the payload copy looks right,
# `nvidia-smi` says "couldn't communicate with the NVIDIA driver", and the real
# cause is that no loader was ever installed.

LOADER_CONF=/etc/ld.so.conf.d/ld.wsl.conf

cmd_loaders_status() {
	say "loaders ($WSL_LIB)"
	if [ ! -d "$WSL_LIB" ]; then
		mark_fail "$WSL_LIB missing" "- nothing to load the payload with"
		note "deploy ExHyperV's lib/ folder:  sudo $PROG loaders install <path/to/lib>"
		return "$GPUPV_FAILS"
	fi
	local f n=0
	for f in libcuda.so.1 libnvidia-ml.so.1 libdxcore.so nvidia-smi; do
		if [ -e "$WSL_LIB/$f" ]; then
			printf '  present %-22s %s bytes\n' "$f" "$(stat -c%s "$WSL_LIB/$f" 2>/dev/null)"
			n=$((n + 1))
		else
			printf '  MISSING %s\n' "$f"
		fi
	done
	if [ "$n" -ge 3 ]; then mark_ok "loaders present ($n/4 key files)"; else
		mark_fail "loaders incomplete ($n/4 key files)" "- copy the whole lib/ folder, not selected files"
	fi
	sub "ld.so search path"
	if [ -r "$LOADER_CONF" ]; then
		sed 's/^/  /' "$LOADER_CONF"
		grep -qx "$WSL_LIB" "$LOADER_CONF" || mark_fail "$WSL_LIB not on the ld.so path"
		grep -qx "$WSL_DRIVERS" "$LOADER_CONF" || mark_fail "$WSL_DRIVERS not on the ld.so path"
	else
		mark_fail "$LOADER_CONF missing" "- payload and loaders are both unreachable without it"
	fi
	return "$GPUPV_FAILS"
}

cmd_loaders_install() {
	local src=${1:-}
	[ -n "$src" ] || die "usage: sudo $PROG loaders install <path/to/ExHyperV/lib> [--driverstore DIR]"
	shift || true
	local dstdrv=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--driverstore) dstdrv=$2; shift 2 ;;
			*) shift ;;
		esac
	done
	need_root loaders install LIBDIR
	[ -d "$src" ] || die "not a directory: $src"
	local n
	n=$(count_entries "$src")
	[ "$n" -gt 0 ] || die "$src is empty"

	say "loaders install"
	note "source   $src ($n files)"
	note "target   $WSL_LIB"

	# Back up an existing set rather than overwriting it silently: a loader set
	# that matches the payload is worth keeping if this one is older.
	if [ -d "$WSL_LIB" ] && [ "$(count_entries "$WSL_LIB")" -gt 0 ]; then
		local bk="${LOADER_BACKUP:-/var/lib/gpupv/loaders-backup}"
		if [ ! -d "$bk" ]; then
			mkdir -p "$(dirname "$bk")"
			cp -a "$WSL_LIB" "$bk" || die "backup failed - nothing changed"
			note "backup   $bk ($(count_entries "$bk") files)"
		else
			note "backup   reusing $bk"
		fi
	fi

	mkdir -p "$WSL_LIB"
	cp -a "$src/." "$WSL_LIB/" || die "copy failed"
	chmod -R a+r "$WSL_LIB" 2>/dev/null || true

	# The tooling (and ExHyperV's own script) expects these two links to exist.
	[ -e "$WSL_LIB/libd3d12core.so" ] && ln -sf "$WSL_LIB/libd3d12core.so" "$WSL_LIB/libD3D12Core.so" 2>/dev/null || true
	if [ -e "$WSL_LIB/libcuda.so.1" ]; then
		mkdir -p /usr/lib/x86_64-linux-gnu
		ln -sf "$WSL_LIB/libcuda.so.1" /usr/lib/x86_64-linux-gnu/libcuda.so.1 2>/dev/null || true
		ln -sf "$WSL_LIB/libcuda.so.1" /usr/lib/x86_64-linux-gnu/libcuda.so 2>/dev/null || true
	fi
	if [ -e "$WSL_LIB/nvidia-smi" ]; then
		install -m 755 "$WSL_LIB/nvidia-smi" /usr/bin/nvidia-smi 2>/dev/null || \
			cp "$WSL_LIB/nvidia-smi" /usr/bin/nvidia-smi
		chmod 755 /usr/bin/nvidia-smi
		note "nvidia-smi -> /usr/bin/nvidia-smi"
	fi
	mark_ok "copied $n files"

	# Both directories on the search path: the loaders live in one, the payload
	# the loaders dlopen lives in the other.
	sub "ld.so search path"
	mkdir -p /etc/ld.so.conf.d
	if [ ! -e "$LOADER_CONF" ]; then
		printf '%s\n%s\n' "$WSL_LIB" "$WSL_DRIVERS" > "$LOADER_CONF"
		note "wrote $LOADER_CONF"
	else
		grep -qx "$WSL_LIB" "$LOADER_CONF" || { printf '%s\n' "$WSL_LIB" >> "$LOADER_CONF"; note "added $WSL_LIB"; }
		grep -qx "$WSL_DRIVERS" "$LOADER_CONF" || { printf '%s\n' "$WSL_DRIVERS" >> "$LOADER_CONF"; note "added $WSL_DRIVERS"; }
	fi
	have ldconfig && ldconfig 2>/dev/null || true

	cmd_loaders_status >/dev/null 2>&1 || true
	say "next"
	note "the payload still has to be present for cuInit to work:"
	note "  sudo $PROG driverstore status"
	note "  $PROG verify"
	return 0
}

cmd_loaders_rollback() {
	need_root loaders rollback
	local bk="${LOADER_BACKUP:-/var/lib/gpupv/loaders-backup}"
	[ -d "$bk" ] || die "no backup at $bk"
	say "loaders rollback"
	rm -rf "$WSL_LIB" && cp -a "$bk" "$WSL_LIB" || die "restore failed"
	chmod -R a+r "$WSL_LIB" 2>/dev/null || true
	have ldconfig && ldconfig 2>/dev/null || true
	note "restored $WSL_LIB ($(count_entries "$WSL_LIB") files)"
}

cmd_loaders() {
	local sub=${1:-status}
	[ $# -gt 0 ] && shift
	case "$sub" in
		status)            cmd_loaders_status "$@" ;;
		install|add)       cmd_loaders_install "$@" ;;
		rollback|restore)  cmd_loaders_rollback "$@" ;;
		*) die "unknown: loaders $sub (status|install|rollback)" ;;
	esac
}

# ====================== lib/service.sh ======================
# lib/service.sh - boot loader + self-test units.
#
# Two failure modes this exists to prevent:
#   * the loader script hard-codes a kernel string (KERNEL="6.12.18-trim") while
#     the box runs something else, so every depmod targets a kernel nobody boots;
#   * the self-test unit is wanted by multi-user.target while the loader runs
#     after graphical.target, so the test either runs before the GPU exists or
#     is dropped by the ordering cycle.

SVC_LOADER=/usr/local/bin/load_dxg_driver.sh
SVC_SELFTEST=/usr/local/bin/gpupv-selftest.sh
SVC_LOG=/var/log/load-dxg.log
SVC_ENV_DIR=/etc/gpupv

cmd_service_install() {
	need_root service install
	local selftest=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--selftest) selftest=1; shift ;;
			*) shift ;;
		esac
	done
	say "service install"

	mkdir -p "$SVC_ENV_DIR"
	cat > "$SVC_ENV_DIR/loader.conf" <<EOF
# generated by gpupv.sh - values read by load_dxg_driver.sh
GPUPV_LOG=$SVC_LOG
EOF

	cat > "$SVC_LOADER" <<'EOS'
#!/bin/bash
# load dxgkrnl at late boot. No hard-coded kernel: the module is built for
# whatever kernel is running, so the loader must ask for the same one.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=${GPUPV_LOG:-/var/log/load-dxg.log}
KERNEL="$(uname -r)"

echo "==== $(date) ====" >> "$LOG"

# a leftover policy file under ANY name blocks the module permanently;
# the deploy scripts only remove one hard-coded filename.
for f in /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d; do
	[ -d "$f" ] || continue
	grep -rlE '^(blacklist[[:space:]]+dxgkrnl|install[[:space:]]+dxgkrnl[[:space:]]+/bin/false)' "$f" 2>/dev/null |
		while IFS= read -r bad; do
			echo "removing modprobe block: $bad" >> "$LOG"
			mv -f "$bad" "$bad.disabled-$(date +%s)" 2>/dev/null
		done
done

if [ -x /usr/sbin/depmod ]; then /usr/sbin/depmod -a "$KERNEL" >> "$LOG" 2>&1 || true
elif [ -x /sbin/depmod ]; then /sbin/depmod -a "$KERNEL" >> "$LOG" 2>&1 || true; fi

if lsmod | grep -q '^dxgkrnl'; then
	echo "dxgkrnl already loaded" >> "$LOG"
else
	if [ -x /usr/sbin/modprobe ]; then /usr/sbin/modprobe -v dxgkrnl >> "$LOG" 2>&1 || true
	elif [ -x /sbin/modprobe ]; then /sbin/modprobe -v dxgkrnl >> "$LOG" 2>&1 || true; fi
fi

[ -e /dev/dxg ] && chmod 666 /dev/dxg 2>/dev/null

lsmod | grep dxgkrnl >> "$LOG" 2>&1 || echo "dxgkrnl NOT loaded" >> "$LOG"
ls -l /dev/dxg >> "$LOG" 2>&1 || true
EOF
	chmod 755 "$SVC_LOADER"
	mark_ok "wrote $SVC_LOADER (KERNEL=\$(uname -r))"

	cat > /etc/systemd/system/load-dxg-late.service <<'EOS'
[Unit]
Description=Late load dxgkrnl (GPU-PV)
After=graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=GPUPV_LOG=/var/log/load-dxg.log
ExecStart=/usr/local/bin/load_dxg_driver.sh
TimeoutStartSec=120

[Install]
WantedBy=graphical.target
EOS
	systemctl daemon-reload
	systemctl enable load-dxg-late.service >/dev/null 2>&1
	mark_ok "load-dxg-late.service enabled (WantedBy=graphical.target)"

	if [ "$selftest" -eq 1 ]; then
		cat > "$SVC_SELFTEST" <<'EOS'
#!/bin/bash
# Post-boot GPU-PV self test. Runs after the loader, records one line per gate
# so a silent regression is visible without logging in and running things.
KERNEL="$(uname -r)"
LOG=${GPUPV_LOG:-/var/log/load-dxg.log}
echo "==== gpupv-selftest $(date) ===="
echo "kernel: $KERNEL"
lsmod | grep dxgkrnl || echo "dxgkrnl NOT loaded"
ls -l /dev/dxg 2>&1
DS=$(ls -d /usr/lib/wsl/drivers/nv_dispi.inf_amd64_* 2>/dev/null | head -1)
echo "driverstore: ${DS:-none} $(ls -1 "$DS" 2>/dev/null | wc -l) files / $(ls -1 "$DS" 2>/dev/null | grep -vc '\.so') non-so"
timeout 30 python3 -c 'import ctypes; print("cuInit", ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1").cuInit(0))' 2>&1
EOS
		chmod 755 "$SVC_SELFTEST"

		cat > /etc/systemd/system/gpupv-selftest.service <<'EOS'
[Unit]
Description=GPU-PV self test
After=graphical.target load-dxg-late.service
Wants=load-dxg-late.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpupv-selftest.sh
StandardOutput=append:/var/log/load-dxg.log
StandardError=append:/var/log/load-dxg.log
TimeoutStartSec=120

[Install]
WantedBy=graphical.target
EOS
		systemctl daemon-reload
		systemctl enable gpupv-selftest.service >/dev/null 2>&1
		mark_ok "gpupv-selftest.service enabled (After=graphical.target load-dxg-late.service)"
	fi

	say "running the loader once now"
	GPUPV_LOG="$SVC_LOG" bash "$SVC_LOADER"
	tail -5 "$SVC_LOG" 2>/dev/null | sed 's/^/  /'
	note ""
	note "reboot, then check:  tail -20 $SVC_LOG"
}

cmd_service_status() {
	say "service status"
	local u en ac
	for u in load-dxg-late.service gpupv-selftest.service; do
		if [ -e "/etc/systemd/system/$u" ]; then
			en=$(systemctl show -p UnitFileState --value "$u" 2>/dev/null)
			ac=$(systemctl show -p ActiveState   --value "$u" 2>/dev/null)
			note "$u: enabled=${en:-unknown} active=${ac:-unknown}"
		else
			note "$u: not installed"
		fi
	done
	if [ -e "$SVC_LOADER" ]; then
		local k
		k=$(grep -m1 '^KERNEL=' "$SVC_LOADER" 2>/dev/null)
		note "loader $SVC_LOADER: ${k:-no KERNEL= line}"
		case "$k" in
			*'$(uname -r)'*|"") : ;;
			*) warn "hard-coded kernel in the loader - run: sudo $PROG service install" ;;
		esac
	fi
	[ -r "$SVC_LOG" ] && { sub "log tail"; tail -15 "$SVC_LOG" | sed 's/^/  /'; }
}

cmd_service_uninstall() {
	need_root service install
	say "service uninstall"
	local u
	for u in gpupv-selftest.service load-dxg-late.service; do
		systemctl disable --now "$u" >/dev/null 2>&1 || true
		rm -f "/etc/systemd/system/$u"
	done
	rm -f "$SVC_SELFTEST"
	systemctl daemon-reload
	mark_ok "units removed (module and driverstore untouched)"
	note "$SVC_LOADER left in place - remove it by hand if you no longer want it"
}

cmd_service() {
	local sub=${1:-status}
	[ $# -gt 0 ] && shift
	case "$sub" in
		install)   cmd_service_install "$@" ;;
		status)    cmd_service_status "$@" ;;
		uninstall) cmd_service_uninstall "$@" ;;
		*) die "unknown: service $sub (install|status|uninstall)" ;;
	esac
}

# ====================== lib/serve.sh ======================
# lib/serve.sh - move the host's DriverStore into the guest when SSH/SMB is not
# an option: a throwaway HTTP PUT receiver.
#
# The Windows script normally uses SSH (scp/tar over ssh). This exists for the
# case where OpenSSH is not enabled on either side but the LAN reaches the guest,
# and for anyone doing it by hand.

cmd_receive() {
	local dir=${1:-/tmp/nvstore}
	local port=${2:-8899}
	mkdir -p "$dir" || die "cannot create $dir"
	local py
	py=$(mktemp -d "${TMPDIR:-/tmp}/gpupv-recv.XXXXXX")/http_put_server.py
	asset_write http_put_server.py "$py" || die "cannot materialise http_put_server.py"

	local ip
	ip=$(lan_ip)
	say "HTTP PUT receiver"
	note "listen 0.0.0.0:$port"
	note "write  $dir"
	[ -n "$ip" ] && note "url    http://$ip:$port/"
	note ""
	note "from the Windows host (Administrator PowerShell):"
	if [ -n "$ip" ]; then
		note "  curl.exe -s --max-time 5 http://$ip:$port/            # expect: alive"
		note "  .\\gpupv-windows.ps1 -Action Push -GuestUrl http://$ip:$port/"
	fi
	note ""
	note "each file answers 'ok <name> <bytes>'; a GET / lists what landed."
	note "Ctrl-C when the batch is in, then: $PROG driverstore compare $dir"
	note ""
	exec python3 "$py" "$dir" "$port"
}

# ====================== dispatch ======================
usage() {
	cat <<EOF
gpupv-fnos.sh $GPUPV_VERSION - Hyper-V GPU-PV tool for the Linux guest

usage: sudo ./gpupv-fnos.sh <command> [options]

  deps [--install]           check the build toolchain (gcc, xz, bc, bison, flex,
                             libelf/libssl/zlib headers); --install apt-get's what is missing
  triage                     root-free triage: module / device / VMBus / libs / NVML
  verify [--quick]           functional gates (quick = skip the codec matrix)
  probe                      build + run the /dev/dxg probe (kernel path only)
  doctor                     deep diagnosis: ABI gates, payload trace, hung probes
  report [--out FILE]        write a markdown evidence file
  setup [DRIVERSTORE_DIR]    the whole guest side: deps + module + driverstore + service + gates

  module build [--branch auto|wsl-6.18.y|wsl-6.6.y] [--out DIR] [--dkms]
  module verify <ko|ko.xz>
  module install <ko> [--no-backup]
  module restore [--list]

  driverstore status [DIR]
  driverstore compare DIR [--driverstore DIR]
  driverstore install DIR [--replace] [--name DIRNAME] [--driverstore DIR]
  driverstore rollback [--driverstore DIR]

  loaders status             /usr/lib/wsl/lib: the thin loaders + nvidia-smi + ld.so path
  loaders install LIBDIR     deploy ExHyperV's lib/ folder (the other half of the stack)
  loaders rollback

  receive [DIR] [PORT]       HTTP PUT receiver for the host's DriverStore (default
                             /tmp/nvstore 8899) - for hosts without an SSH path

  service install [--selftest]
  service status
  service uninstall

  help | version

notes:
  * DRIVERSTORE_DIR should be the host's nv_dispi.inf_amd64_<hash> folder itself.
    On a fresh guest nothing is deployed yet, so the folder name comes from that
    path; pass --name if you unpacked it into a generically named directory.
  * a stock fnOS has no gcc. 'setup' and 'module build' install the toolchain
    automatically when run as root; 'deps' shows what is missing without root.

environment:
  WSL_LIB, WSL_DRIVERS, FFMPEG, GPUPV_CACHE, GPUPV_DRIVERSTORE, NO_COLOR

host side (Windows, Administrator PowerShell):
  gpupv-windows.ps1 -Action Check|FixMmio|AddPartition|Install|Verify
  gpupv-windows.ps1 -Action Push|ShowDriverStore|ShowPowerShell
EOF
}

# One-shot guest setup: toolchain -> module -> DriverStore -> boot service -> gates.
# Every step is skippable by state, so re-running it is safe.
cmd_setup() {
	local src="" libdir="" leafname=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--driverstore) src=$2; shift 2 ;;
			--loaders)     libdir=$2; shift 2 ;;
			--name)        leafname=$2; shift 2 ;;
			*) src=$1; shift ;;
		esac
	done
	need_root
	say "setup: guest side"
	note "kernel  $GPUPV_KERNEL_RUNNING"

	# 1. toolchain first: without gcc the module step dies as Error 127, and that
	#    reads like a broken source tree.
	sub "build toolchain"
	if deps_ensure; then
		mark_ok "toolchain ready"
	else
		die "cannot continue without a compiler - install the toolchain, then re-run setup"
	fi

	# 2. loaders (ExHyperV's lib/) - the payload alone cannot be loaded
	if [ -n "$libdir" ]; then
		sub "loaders from $libdir"
		cmd_loaders_install "$libdir" || warn "loaders install reported a problem"
	elif [ ! -e "$WSL_LIB/libcuda.so.1" ]; then
		warn "no loaders at $WSL_LIB - cuInit cannot work without them"
		note "  sudo $PROG loaders install <ExHyperV>/lib"
	fi

	# 3. the module
	local need_mod=0
	if lsmod 2>/dev/null | grep -q '^dxgkrnl' && [ -e /dev/dxg ]; then
		mark_ok "dxgkrnl already loaded with /dev/dxg"
	else
		need_mod=1
	fi
	if [ -z "$src" ] && [ -n "${GPUPV_DRIVERSTORE:-}" ]; then src=$GPUPV_DRIVERSTORE; fi
	if [ "$need_mod" -eq 1 ]; then
		sub "building dxgkrnl for $(kver)"
		cmd_module_build || die "module build failed - see the compile log above"
		local ko="$CACHE_DIR/dxgkrnl-$(kver)/dxgkrnl.ko"
		sub "installing $ko"
		cmd_module_install "$ko" --live || die "module install failed - see dmesg"
	else
		note "skipping the module step (already loaded)"
	fi

	# 4. the DriverStore payload
	if [ -n "$src" ]; then
		sub "installing DriverStore from $src"
		if [ -n "$leafname" ]; then
			cmd_ds_install "$src" --name "$leafname" || warn "driverstore install reported a problem (see above)"
		else
			cmd_ds_install "$src" || warn "driverstore install reported a problem (see above)"
		fi
	else
		local ds
		ds=$(ds_pick || true)
		if [ -n "$ds" ] && ds_verdict "$ds" >/dev/null; then
			mark_ok "DriverStore already complete at $ds"
		else
			warn "DriverStore is missing or trimmed - the guest will show NVML without CUDA"
			note "re-run with the folder:   sudo $PROG setup <dir>/$NVSTORE_GLOB"
			note "or:                       sudo $PROG driverstore install <dir> --name nv_dispi.inf_amd64_<hash>"
		fi
	fi

	# 5. boot persistence
	sub "boot service"
	cmd_service_install --selftest || warn "service install failed"

	# 6. the real gates
	say "final gates"
	cmd_verify
}

main() {
	[ $# -gt 0 ] || { usage; exit 2; }
	local cmd=$1
	shift
	case "$cmd" in
		deps|dep)           cmd_deps "$@" ;;
		triage)             cmd_triage "$@" ;;
		verify)             cmd_verify "$@" ;;
		probe)              cmd_probe "$@" ;;
		doctor)             cmd_doctor "$@" ;;
		report)             cmd_report "$@" ;;
		setup)              cmd_setup "$@" ;;
		module)             cmd_module "$@" ;;
		driverstore|ds)     cmd_driverstore "$@" ;;
		loaders|wl)         cmd_loaders "$@" ;;
		service)            cmd_service "$@" ;;
		receive|serve)      cmd_receive "$@" ;;
		version|--version|-V) echo "gpupv-fnos.sh $GPUPV_VERSION" ;;
		help|--help|-h)     usage ;;
		*) usage; exit 2 ;;
	esac
}

main "$@"
