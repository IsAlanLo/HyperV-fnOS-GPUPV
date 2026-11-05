#!/usr/bin/env bash
# lib/loaders.sh - deploy the thin loaders in /usr/lib/wsl/lib that turn the
# DriverStore payload into something applications can call.
#
# The source directory is C:\Windows\System32\lxss\lib on the host: it ships with
# Windows itself and is refreshed by the NVIDIA driver. No third-party package is
# required - ExHyperV's lib/ folder is just a copy of that directory.
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
		note "copy the host's C:\\Windows\\System32\\lxss\\lib into the guest:"
		note "  sudo $PROG loaders install <path/to/lxss/lib>"
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
	[ -n "$src" ] || die "usage: sudo $PROG loaders install <path/to/lxss/lib> [--driverstore DIR]"
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

	# Two links the tooling expects: the mixed-case D3D12 name, and libcuda in the
	# multiarch directory so a plain `-lcuda` finds the loader.
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
