#!/usr/bin/env bash
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

# A binary is present if it is on PATH OR at a standard root-only location: a
# non-root login shell on fnOS can have /usr/sbin and /sbin stripped from PATH, so
# `command -v depmod` reported "missing" for an installed kmod. Check the paths a
# root build will actually use.
_deps_have() {
	local p
	have "$1" && return 0
	for p in "/usr/sbin/$1" "/sbin/$1" "/usr/bin/$1" "/bin/$1" "/usr/local/bin/$1"; do
		[ -x "$p" ] && return 0
	done
	return 1
}

# What is missing, one binary per line. Header files are checked separately.
_deps_missing_bins() {
	local b
	for b in gcc make xz bc bison flex depmod; do
		_deps_have "$b" || echo "$b"
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

	# When this command is about to install them, a missing package is a TODO,
	# not a failed check: counting it as a gate failure made a successful run
	# report "gates: 15 checks, 4 failed" over packages it had just installed.
	if [ "$do_install" -eq 0 ]; then
		[ -n "$missing" ] && mark_fail "missing binaries:$missing" "- these are what break the build with Error 127"
		[ -n "$pkgs" ] && mark_fail "missing headers:$pkgs" "- objtool / compression / module signing"
		note ""
		note "install with:  sudo $PROG deps --install"
		return 1
	fi
	[ -n "$missing" ] && sub "missing binaries:$missing"
	[ -n "$pkgs" ] && sub "missing headers:$pkgs"

	need_root deps --install
	# Only apt is implemented. On another distribution the answer is not a failed
	# install but "here is the equivalent command", so the tool stays usable.
	if ! have apt-get; then
		mark_fail "no apt-get on this system" "- install the toolchain with your package manager"
		note "  Debian/Ubuntu: apt-get install -y $pkgs"
		note "  Fedora/RHEL:   dnf install -y $pkgs"
		note "  Arch:          pacman -S --needed $pkgs"
		note "then re-run:  $PROG deps"
		return 1
	fi

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
