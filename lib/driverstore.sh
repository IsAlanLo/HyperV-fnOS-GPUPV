#!/usr/bin/env bash
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
	else
		ds_pick || die "no unique $WSL_DRIVERS/$NVSTORE_GLOB (pass --driverstore DIR)"
	fi
}

# compare the deployed copy against an incoming one: same build, or a
# different driver version? The two answers mean completely different things.
cmd_ds_compare() {
	local incoming=${1:-}
	[ -n "$incoming" ] || die "usage: $PROG driverstore compare <incoming dir> [--driverstore DIR]"
	shift || true
	local target
	target=$(_ds_target "") || exit 1
	while [ $# -gt 0 ]; do
		case "$1" in
			--driverstore) target=$(_ds_target "$2"); shift 2 ;;
			*) shift ;;
		esac
	done
	[ -d "$incoming" ] || die "not a directory: $incoming"

	say "driverstore compare"
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
	target=$(_ds_target "${1:-}")
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
	[ -n "$src" ] || die "usage: sudo $PROG driverstore install <incoming dir> [--replace] [--driverstore DIR]"
	shift || true
	local replace=0 target="" force=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--replace) replace=1; shift ;;
			--driverstore) target=$2; shift 2 ;;
			--force) force=1; shift ;;
			*) shift ;;
		esac
	done
	need_root driverstore install DIR
	[ -d "$src" ] || die "not a directory: $src"
	target=$(_ds_target "$target")

	local nsrc
	nsrc=$(count_entries "$src")
	[ "$nsrc" -gt 0 ] || die "incoming directory is empty"

	say "driverstore install"
	note "incoming  $src ($nsrc files, $(du -sh "$src" 2>/dev/null | cut -f1))"
	note "target    $target ($(count_entries "$target") files)"

	# Refuse the mistake that looks like a fix: installing a trimmed set.
	if [ "$nsrc" -lt 100 ] && [ "$force" -eq 0 ]; then
		die "incoming set has only $nsrc files - a complete nv_dispi folder has ~150. Refusing (pass --force to override)."
	fi

	# Backup once, never overwrite a good backup with a broken state - but an
	# existing EMPTY directory is not a backup (a failed or aborted first run
	# leaves one behind, and "reusing" it makes rollback restore nothing).
	if [ ! -d "$DS_BACKUP" ] || [ -z "$(ls -A "$DS_BACKUP" 2>/dev/null)" ]; then
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
	chmod -R a+r "$target"

	note "after     $(count_entries "$target") files, $(count_nonso "$target") non-.so"
	nvstore_keyfiles "$target" | sed 's/^/  /'
	[ -e /etc/ld.so.conf.d/ld.wsl.conf ] || {
		printf '%s\n%s\n' "$WSL_LIB" "$WSL_DRIVERS" > /etc/ld.so.conf.d/ld.wsl.conf
		note "wrote /etc/ld.so.conf.d/ld.wsl.conf"
	}
	ldconfig 2>/dev/null || true

	say "real consumer test (never nvidia-smi)"
	local rc
	timeout 60 python3 -c 'import ctypes,sys; sys.exit(0 if ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1").cuInit(0)==0 else 1)'
	rc=$?
	if [ "$rc" -eq 0 ]; then
		mark_ok "cuInit 0"
		note "now run: $PROG verify"
	else
		mark_fail "cuInit" "rc=$rc (139 = SIGSEGV)"
		note "not fixed by this payload. Roll back: sudo $PROG driverstore rollback"
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
