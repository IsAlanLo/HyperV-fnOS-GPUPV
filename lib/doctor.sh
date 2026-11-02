#!/usr/bin/env bash
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
