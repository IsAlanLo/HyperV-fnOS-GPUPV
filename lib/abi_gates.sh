#!/usr/bin/env bash
# lib/abi_gates.sh - offline gates for a dxgkrnl.ko, before it is loaded.
#
#   bash lib/abi_gates.sh <dxgkrnl.ko> [other d3dkmthk.h]
#
# Gate 2 is the one that matters: the module must read hdev->channel at the
# RUNNING KERNEL's offset. A module built against the WSL branch's hyperv.h
# reads a neighbouring field, NULL-derefs inside probe while holding
# device_mutex, and then no later probe can run while vermagic still matches.
# The expected offset is derived from the running kernel each time, never
# memorised, because a kernel bump changes it.
set -u
KO=${1:-}
OTHER=${2:-}
[ -n "$KO" ] && [ -f "$KO" ] || { echo "usage: abi_gates.sh <dxgkrnl.ko> [other-d3dkmthk.h]" >&2; exit 2; }
K=$(uname -r)
PROG=$(basename -- "$0")
fail=0
note() { printf '%-14s %s\n' "$1" "$2"; }
bad()  { printf '%-14s FAIL %s\n' "$1" "$2"; fail=1; }

# --- 1. vermagic ---------------------------------------------------------
kv=$(strings "$KO" | grep -m1 '^vermagic=' | sed 's/^vermagic=//')
case "$kv" in
	"$K "*) note vermagic "$kv" ;;
	"")     bad  vermagic "no vermagic found (not a kernel module?)" ;;
	*)      bad  vermagic "[$kv] != [$K]" ;;
esac

# --- 2. hdev->channel offset vs the running kernel -----------------------
B=$(mktemp -d "${TMPDIR:-/tmp}/gpupv-off.XXXXXX")
{
	printf '#include <linux/module.h>\n#include <linux/hyperv.h>\n'
	printf 'unsigned long off_channel(void) { return (unsigned long)offsetof(struct hv_device, channel); }\n'
} > "$B/off.c"
echo 'obj-m += off.o' > "$B/Makefile"
want=""
if make -C "/lib/modules/$K/build" M="$B" >"$B/make.log" 2>&1 || [ -f "$B/off.o" ]; then
	# the compile legitimately fails at modpost; off.o is produced first
	want=$(objdump -d "$B/off.o" 2>/dev/null \
		| sed -n '/<off_channel>:/,/ret\|jmp/p' \
		| grep -oE '\$0x[0-9a-f]+,%eax' | head -1 | grep -oE '0x[0-9a-f]+')
fi
rm -rf "$B"
got=$(objdump -d "$KO" 2>/dev/null \
	| sed -n '/<dxg_probe_vmbus>:/,/^$/p' \
	| grep -m1 -oE 'mov +0x[0-9a-f]+\(%rbx\),%rax' | grep -oE '0x[0-9a-f]+')
if [ -n "$want" ] && [ -n "$got" ]; then
	if [ "$want" = "$got" ]; then
		note channel-off "$got (kernel header agrees)"
	else
		bad channel-off "module $got vs kernel $want - built against a foreign hyperv.h"
	fi
elif [ -n "$got" ]; then
	note channel-off "$got (kernel header unavailable; verify by hand)"
else
	bad channel-off "cannot locate the hdev->channel load in dxg_probe_vmbus"
fi

# --- 3. GPU-PV channel GUID aliases --------------------------------------
modinfo_out=$(modinfo "$KO" 2>/dev/null || true)
[ -n "$modinfo_out" ] || modinfo_out=$(readelf -p .modinfo "$KO" 2>/dev/null || strings "$KO")
if printf '%s' "$modinfo_out" | grep -q 'vmbus:182d386e36334b4facc42b7703d4df4a' &&
   printf '%s' "$modinfo_out" | grep -q 'vmbus:c0cbe9dd605036449448ea1254a5d177'; then
	note guid-aliases "both dxg channel GUIDs present"
else
	bad guid-aliases "a GPU-PV channel GUID alias is missing (hyperv_gpup.h not included?)"
fi

# --- 4. UAPI ABI vs the header already in use ----------------------------
if [ -n "$OTHER" ] && [ -f "$OTHER" ]; then
	probe=$(find /usr/src -maxdepth 6 -path '*uapi/misc/d3dkmthk.h' 2>/dev/null | head -1)
	if [ -n "$probe" ]; then
		t=$(mktemp -d "${TMPDIR:-/tmp}/gpupv-abi.XXXXXX")
		# Let the system's <linux/types.h> provide __u8../__u64: defining them
		# by hand collides with glibc's asm/types.h and the header then fails to
		# parse, which used to be reported as an ABI mismatch.
		cat > "$t/a.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
#include <linux/types.h>
#ifndef __user
#define __user
#endif
#include UAPI
int main(void) {
	printf("%zu %zu %zu\n",
		sizeof(struct d3dddi_synchronizationobjectinfo2),
		sizeof(struct d3dkmt_createsynchronizationobject2),
		sizeof(struct d3dkmt_createallocation));
	return 0;
}
EOF
		a=$(gcc -DUAPI="\"$probe\"" -o "$t/a" "$t/a.c" 2>/dev/null && "$t/a")
		b=$(gcc -DUAPI="\"$OTHER\"" -o "$t/b" "$t/a.c" 2>/dev/null && "$t/b")
		rm -rf "$t"
		if [ -z "$a" ] || [ -z "$b" ]; then
			# a header that will not parse standalone tells us nothing about the
			# layout; say so instead of reporting a false ABI mismatch
			note uapi-abi "inconclusive (a header failed to parse standalone: in-use [${a:-fail}] new [${b:-fail}]) - compare by hand"
		elif [ "$a" = "$b" ]; then
			note uapi-abi "identical ($a)"
		else
			bad uapi-abi "differs: in-use [$a] vs new [$b] - an installed libcuda would misread ioctl args"
		fi
	else
		note uapi-abi "skipped (no deployed d3dkmthk.h to compare)"
	fi
else
	note uapi-abi "skipped (pass a second d3dkmthk.h to compare)"
fi

if [ "$fail" -eq 0 ]; then
	echo "ALL GATES PASS - still not proof: load it, then run the guest script's 'verify'"
else
	echo "GATES FAILED - do not insmod this module"
fi
exit "$fail"
