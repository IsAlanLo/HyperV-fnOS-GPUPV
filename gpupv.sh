#!/usr/bin/env bash
# gpupv.sh - Hyper-V GPU-PV (GPU partitioning) tool for the Linux guest.
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

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ -f "$SELF_DIR/lib/common.sh" ]; then
	# modular checkout: source the parts (the single-file build inlines them)
	# shellcheck source=lib/common.sh
	. "$SELF_DIR/lib/common.sh"
	for m in deps triage verify doctor module driverstore loaders service serve; do
		# shellcheck disable=SC1090
		. "$SELF_DIR/lib/$m.sh"
	done
fi

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
