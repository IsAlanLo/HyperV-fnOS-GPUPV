#!/usr/bin/env bash
# tests/smoke.sh - exercise everything that can be exercised without mutating the
# real system. Run as a normal user from the repo root:
#
#   bash tests/smoke.sh            # full
#   bash tests/smoke.sh --no-build # skip the two module builds (network + ~20s)
#
# Deliberately NOT tested here: `module install`, `service install` against the
# real /etc and /lib/modules, and `driverstore install` against the real
# /usr/lib/wsl. Those mutate the machine. The filesystem-mutating ones are
# exercised in a throwaway mount namespace instead (test_fake_root).
set -u
# This suite drives the REAL machine, so inherited overrides from an earlier
# experiment would silently redirect it at a sandbox (and make results look
# wrong). Clear them.
unset WSL_LIB WSL_DRIVERS DS_BACKUP GPUPV_CACHE GPUPV_DRIVERSTORE FFMPEG NO_COLOR 2>/dev/null || true
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
DO_BUILD=1
[ "${1:-}" = "--no-build" ] && DO_BUILD=0

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
headr(){ printf '\n== %s ==\n' "$1"; }

# --- 1. syntax -----------------------------------------------------------
headr "syntax"
for f in gpupv.sh gpupv-fnos.sh lib/*.sh tests/*.sh tools/*.sh; do
	if bash -n "$f" 2>/tmp/.smoke.err; then ok "bash -n $f"; else bad "bash -n $f" "$(cat /tmp/.smoke.err)"; fi
done
if command -v python3 >/dev/null; then
	python3 -m py_compile src/http_put_server.py 2>/tmp/.smoke.err && ok "py_compile http_put_server.py" || bad "py_compile http_put_server.py" "$(cat /tmp/.smoke.err)"
fi

# --- 2. entrypoint -------------------------------------------------------
headr "entrypoint"
v=$(./gpupv.sh version)
[ "$v" = "gpupv-fnos.sh 1.0.0" ] && ok "version prints $v" || bad "version" "got [$v]"
# the single-file build must behave identically and must not be stale
bash tools/build-single.sh > /tmp/.smoke.build 2>&1 && ok "tools/build-single.sh regenerates gpupv-fnos.sh" || bad "build-single" "$(cat /tmp/.smoke.build)"
cp gpupv-fnos.sh /tmp/.smoke-solo.sh && chmod +x /tmp/.smoke-solo.sh
solo=$(cd /tmp && ./.smoke-solo.sh version 2>&1)
[ "$solo" = "gpupv-fnos.sh 1.0.0" ] && ok "single file runs outside the repo" || bad "single-file version" "$solo"
a=$(./gpupv.sh help); b=$(/tmp/.smoke-solo.sh help)
[ "$a" = "$b" ] && ok "single-file help matches the modular tree" || bad "help differs between build and tree"
rm -f /tmp/.smoke-solo.sh
./gpupv.sh help | grep -q 'driverstore install' && ok "help lists driverstore install" || bad "help output"
./gpupv.sh 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "no arguments -> usage + exit 2" || bad "no arguments" "exit $rc"
./gpupv.sh nosuchcommand >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unknown command -> exit 2" || bad "unknown command" "exit $rc"

# --- 3. root refusal (must not silently no-op) ---------------------------
headr "root guards"
if [ "$(id -u)" -ne 0 ]; then
	out=$(./gpupv.sh driverstore install /tmp 2>&1); rc=$?
	[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'needs root' && ok "driverstore install refuses without root" || bad "driverstore install root guard" "rc=$rc out=$out"
	out=$(./gpupv.sh module install /nonexistent.ko 2>&1); rc=$?
	[ "$rc" -ne 0 ] && ok "module install rejects a missing .ko" || bad "module install missing ko"
	out=$(./gpupv.sh service install 2>&1); rc=$?
	[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'needs root' && ok "service install refuses without root" || bad "service install root guard" "rc=$rc"
else
	echo "  (skipped: running as root)"
fi

# --- 4. triage / verify / doctor / probe (informational + hard gates) ----
headr "diagnostic commands on this machine"
./gpupv.sh triage > /tmp/.smoke.triage 2>&1
grep -q 'verdict' /tmp/.smoke.triage && ok "triage runs to a verdict" || bad "triage" "$(tail -5 /tmp/.smoke.triage)"
./gpupv.sh verify --quick > /tmp/.smoke.verify 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "verify --quick: all gates pass"; else
	# a machine without GPU-PV must FAIL here, and say so
	grep -q 'Not functional' /tmp/.smoke.verify && ok "verify reports failure honestly on a non-working stack" \
		|| bad "verify" "$(tail -8 /tmp/.smoke.verify)"
fi
./gpupv.sh probe > /tmp/.smoke.probe 2>&1
grep -q 'enum_adapters ret=0' /tmp/.smoke.probe && ok "probe compiles and reaches the kernel path" \
	|| { grep -q 'no /dev/dxg\|did not compile' /tmp/.smoke.probe && ok "probe fails cleanly without a module" || bad "probe" "$(tail -5 /tmp/.smoke.probe)"; }
./gpupv.sh doctor > /tmp/.smoke.doctor 2>&1
grep -q 'doctor checks' /tmp/.smoke.doctor && ok "doctor runs to a summary" || bad "doctor" "$(tail -5 /tmp/.smoke.doctor)"

# --- 5. ABI gates on the RUNNING module ---------------------------------
headr "abi gates"
KO_XZ="/lib/modules/$(uname -r)/updates/dkms/dxgkrnl.ko.xz"
if [ -r "$KO_XZ" ]; then
	tmpko=$(mktemp "${TMPDIR:-/tmp}/smoke.XXXXXX.ko")
	xz -dc "$KO_XZ" > "$tmpko"
	if bash lib/abi_gates.sh "$tmpko" > /tmp/.smoke.abi 2>&1; then
		ok "loaded module passes the ABI gates"
	else
		bad "loaded module fails the ABI gates" "$(cat /tmp/.smoke.abi)"
	fi
	# a foreign-kernel .ko must be rejected
	printf 'garbage' > /tmp/.smoke.bad.ko
	bash lib/abi_gates.sh /tmp/.smoke.bad.ko >/tmp/.smoke.abi2 2>&1 && bad "garbage .ko accepted" || ok "garbage .ko rejected"
	rm -f "$tmpko" /tmp/.smoke.bad.ko
else
	echo "  (skipped: no $KO_XZ)"
fi

# --- 6. driverstore compare verdicts ------------------------------------
headr "driverstore compare"
DS=$(./gpupv.sh driverstore status 2>/dev/null | awk '/^  path/{print $2}')
if [ -n "$DS" ] && [ -d "$DS" ]; then
	# a subset of the deployed copy must be called out as a subset
	sub=$(mktemp -d "${TMPDIR:-/tmp}/smoke-sub.XXXXXX")
	ls -1 "$DS" | head -5 | while IFS= read -r f; do cp "$DS/$f" "$sub/"; done
	out=$(./gpupv.sh driverstore compare "$sub" 2>&1)
	printf '%s' "$out" | grep -q 'SUBSET' && ok "subset incoming set flagged as SUBSET" || bad "subset detection" "$out"
	# an identical copy must be called "no difference"
	same=$(mktemp -d "${TMPDIR:-/tmp}/smoke-same.XXXXXX")
	ls -1 "$DS" | while IFS= read -r f; do :; done
	cp -a "$DS/." "$same/" 2>/dev/null
	out=$(./gpupv.sh driverstore compare "$same" 2>&1)
	printf '%s' "$out" | grep -q 'no difference' && ok "identical copy -> 'no difference'" || bad "identical detection" "$(printf '%s' "$out" | tail -4)"
	rm -rf "$sub" "$same"
else
	echo "  (skipped: no DriverStore on this machine)"
fi

# --- 6b. a FRESH guest: nothing deployed yet ----------------------------
# This is the state a brand-new VM is in, and it used to abort at
# "no unique nv_dispi.inf_amd64_*" - before the first install had a chance.
headr "fresh guest (no DriverStore, no loaders)"
fresh=$(mktemp -d "${TMPDIR:-/tmp}/smoke-fresh.XXXXXX")
mkdir -p "$fresh/wsl/drivers" "$fresh/store/nv_dispi.inf_amd64_fresh"
for i in $(seq 1 160); do : > "$fresh/store/nv_dispi.inf_amd64_fresh/f$i.dat"; done
printf 'meta' > "$fresh/store/nv_dispi.inf_amd64_fresh/nvinfo.pb"
out=$(WSL_LIB=$fresh/wsl/lib WSL_DRIVERS=$fresh/wsl/drivers DS_BACKUP=$fresh/bk \
	GPUPV_CACHE=$fresh/cache NO_COLOR=1 ./gpupv.sh driverstore status 2>&1)
printf '%s' "$out" | grep -qi 'normal before the first install' && ok "status explains a fresh guest instead of erroring out" \
	|| bad "fresh status" "$(printf '%s' "$out" | head -5)"
out=$(WSL_LIB=$fresh/wsl/lib WSL_DRIVERS=$fresh/wsl/drivers GPUPV_CACHE=$fresh/cache NO_COLOR=1 \
	./gpupv.sh driverstore compare "$fresh/store/nv_dispi.inf_amd64_fresh" 2>&1)
printf '%s' "$out" | grep -q 'first install' && ok "compare treats a fresh guest as a first install" \
	|| bad "fresh compare" "$(printf '%s' "$out" | tail -4)"
# and the install must create the destination from the incoming folder NAME
if command -v unshare >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
	out=$(unshare -rm bash -c "WSL_LIB=$fresh/wsl/lib WSL_DRIVERS=$fresh/wsl/drivers DS_BACKUP=$fresh/bk GPUPV_CACHE=$fresh/cache NO_COLOR=1 \
		$(pwd)/gpupv.sh driverstore install $fresh/store/nv_dispi.inf_amd64_fresh" 2>&1)
	n=$(ls -1 "$fresh/wsl/drivers/nv_dispi.inf_amd64_fresh" 2>/dev/null | wc -l)
	[ "$n" = "161" ] && ok "install on a fresh guest creates \$WSL_DRIVERS/<leaf> ($n files)" \
		|| bad "fresh install" "$(printf '%s' "$out" | grep -E 'target|ERROR' | head -3)"
else
	echo "  (skipped install: unshare unavailable)"
fi
rm -rf "$fresh"

# --- 6c. the build toolchain check --------------------------------------
headr "deps"
out=$(NO_COLOR=1 ./gpupv.sh deps 2>&1); rc=$?
if command -v gcc >/dev/null 2>&1; then
	[ "$rc" -eq 0 ] && ok "deps reports the toolchain present" || bad "deps exit $rc" "$(printf '%s' "$out" | tail -4)"
else
	[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'deps --install' && ok "deps names the install command when gcc is missing" \
		|| bad "deps" "$(printf '%s' "$out" | tail -4)"
fi
out=$(NO_COLOR=1 ./gpupv.sh driverstore install /tmp 2>&1)
printf '%s' "$out" | grep -q 'deps\|root' && ok "root-guarded commands still name the fix" || bad "root guard message" "$out"

# --- 7. filesystem mutation in a throwaway namespace --------------------
# Exercises the backup / overlay / rollback logic and the trimmed-set refusal
# without touching the real /usr/lib/wsl.
headr "install + rollback in a private mount namespace"
if command -v unshare >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
	out=$(unshare -rm bash -s "$REPO" <<'INNER' 2>&1
set -u
REPO=$1
T=$(mktemp -d)
mkdir -p "$T/wsl/drivers/nv_dispi.inf_amd64_deadbeef" "$T/wsl/lib" "$T/incoming" "$T/backupdir"
# a trimmed deployment: 18 .so files, no metadata
i=0; while [ $i -lt 18 ]; do : > "$T/wsl/drivers/nv_dispi.inf_amd64_deadbeef/libfake$i.so.1"; i=$((i+1)); done
printf 'x' > "$T/wsl/lib/libcuda.so.1.1"
# a "complete" incoming set: 160 files including nvinfo.pb
i=0; while [ $i -lt 159 ]; do : > "$T/incoming/file$i.dat"; i=$((i+1)); done
printf 'metadata' > "$T/incoming/nvinfo.pb"
export WSL_LIB="$T/wsl/lib" WSL_DRIVERS="$T/wsl/drivers" DS_BACKUP="$T/backupdir" GPUPV_CACHE="$T/cache"
export NO_COLOR=1
cd "$REPO" || exit 1

echo "--- tiny set must be refused"
mkdir -p "$T/tiny"; : > "$T/tiny/only.so"
./gpupv.sh driverstore install "$T/tiny" 2>&1 | grep -q 'Refusing' && echo REFUSED_OK || echo REFUSED_BAD

echo "--- real install (cuInit is expected to fail here: fake payload)"
./gpupv.sh driverstore install "$T/incoming" 2>&1 | grep -E 'mode|after|cuInit' | head -5
n=$(ls -1 "$T/wsl/drivers/nv_dispi.inf_amd64_deadbeef" | wc -l)
[ "$n" -eq 178 ] && echo OVERLAY_OK || echo "OVERLAY_COUNT=$n"
[ -f "$T/backupdir/libfake0.so.1" ] && echo BACKUP_OK || echo BACKUP_BAD
echo "--- rollback restores the trimmed set"
./gpupv.sh driverstore rollback 2>&1 | tail -2
n2=$(ls -1 "$T/wsl/drivers/nv_dispi.inf_amd64_deadbeef" | wc -l)
[ "$n2" -eq 18 ] && echo ROLLBACK_OK || echo "ROLLBACK_COUNT=$n2"
INNER
)
	for k in REFUSED_OK OVERLAY_OK BACKUP_OK ROLLBACK_OK; do
		printf '%s' "$out" | grep -q "$k" && ok "$k" || bad "$k" "$(printf '%s' "$out" | tail -6)"
	done
else
	echo "  (skipped: unshare -rm unavailable)"
fi

# --- 8. module builds ---------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
	headr "module builds (network)"
	for br in wsl-6.18.y wsl-6.6.y; do
		out=$(./gpupv.sh module build --branch "$br" --out "/tmp/smoke-build-$br" 2>&1); rc=$?
		if [ "$rc" -eq 0 ]; then ok "build $br compiles and passes the gates"
		else bad "build $br" "$(printf '%s' "$out" | tail -6)"; fi
	done
else
	headr "module builds"
	echo "  (skipped: --no-build)"
fi

printf '\n==== smoke: %d passed, %d failed ====\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
