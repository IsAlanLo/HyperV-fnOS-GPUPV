#!/usr/bin/env bash
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
