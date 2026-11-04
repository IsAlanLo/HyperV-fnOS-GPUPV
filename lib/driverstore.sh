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
