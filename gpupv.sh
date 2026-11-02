#!/usr/bin/env bash
# gpupv.sh - Hyper-V GPU-PV (GPU partitioning) tool for the Linux guest.
#
# The whole job, in the order it is usually needed:
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
#
# Host side lives in gpupv-windows.ps1 (Windows PowerShell).
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ -f "$SELF_DIR/lib/common.sh" ]; then
	# modular checkout: source the parts (the single-file build inlines them)
	# shellcheck source=lib/common.sh
	. "$SELF_DIR/lib/common.sh"
	for m in triage verify doctor module driverstore service serve; do
		# shellcheck disable=SC1090
		. "$SELF_DIR/lib/$m.sh"
	done
fi

usage() {
	cat <<EOF
gpupv-fnos.sh $GPUPV_VERSION - Hyper-V GPU-PV tool for the Linux guest

usage: sudo ./gpupv-fnos.sh <command> [options]

  triage                     root-free triage: module / device / VMBus / libs / NVML
  verify [--quick]           functional gates (quick = skip the codec matrix)
  probe                      build + run the /dev/dxg probe (kernel path only)
  doctor                     deep diagnosis: ABI gates, payload trace, hung probes
  report [--out FILE]        write a markdown evidence report
  setup                      do the whole guest side: module + driverstore + service

  module build [--branch auto|wsl-6.18.y|wsl-6.6.y] [--out DIR] [--dkms]
  module verify <ko>
  module install <ko> [--no-backup]
  module restore [--list]

  driverstore status [DIR]
  driverstore compare DIR [--driverstore DIR]
  driverstore install DIR [--replace] [--driverstore DIR]
  driverstore rollback [--driverstore DIR]

  receive [DIR] [PORT]       HTTP PUT receiver for the host's DriverStore (default
                             /tmp/nvstore 8899) - for hosts without an SSH path

  service install [--selftest]
  service status
  service uninstall

  help | version

environment:
  WSL_LIB, WSL_DRIVERS, FFMPEG, GPUPV_CACHE, GPUPV_DRIVERSTORE, NO_COLOR

host side (Windows, Administrator PowerShell):
  gpupv-windows.ps1 -Action Check|FixMmio|AddPartition|Install|Verify
  gpupv-windows.ps1 -Action Push|ShowDriverStore|ShowPowerShell
EOF
}

# One-shot guest setup: build+install the module if it is missing, install the
# DriverStore from a directory if one is given, then wire up the boot service and
# finish with the real gates. Every step is skippable by state, so re-running it
# is safe.
cmd_setup() {
	local src=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--driverstore) src=$2; shift 2 ;;
			*) src=$1; shift ;;
		esac
	done
	need_root
	say "setup: guest side"
	note "kernel $GPUPV_KERNEL_RUNNING"

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
		note "skipping the module step"
	fi
	if [ -n "$src" ]; then
		sub "installing DriverStore from $src"
		cmd_ds_install "$src" || warn "driverstore install reported a problem (see above)"
	else
		local ds
		ds=$(ds_pick || true)
		if [ -n "$ds" ] && ds_verdict "$ds" >/dev/null; then
			mark_ok "DriverStore already complete at $ds"
		else
			warn "DriverStore is missing or trimmed - the guest will show NVML without CUDA"
			note "on the host:  .\\gpupv-windows.ps1 -Action Push"
			note "then here:    sudo ./gpupv-fnos.sh driverstore install /tmp/nvstore"
		fi
	fi
	sub "boot service"
	cmd_service_install --selftest || warn "service install failed"
	say "final gates"
	cmd_verify
}

main() {
	[ $# -gt 0 ] || { usage; exit 2; }
	local cmd=$1
	shift
	case "$cmd" in
		triage)             cmd_triage "$@" ;;
		verify)             cmd_verify "$@" ;;
		probe)              cmd_probe "$@" ;;
		doctor)             cmd_doctor "$@" ;;
		report)             cmd_report "$@" ;;
		setup)              cmd_setup "$@" ;;
		module)             cmd_module "$@" ;;
		driverstore|ds)     cmd_driverstore "$@" ;;
		service)            cmd_service "$@" ;;
		receive|serve)      cmd_receive "$@" ;;
		version|--version|-V) echo "gpupv-fnos.sh $GPUPV_VERSION" ;;
		help|--help|-h)     usage ;;
		*) usage; exit 2 ;;
	esac
}

main "$@"
