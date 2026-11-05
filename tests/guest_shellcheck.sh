#!/usr/bin/env bash
# tests/guest_shellcheck.sh - catch the class of bug that broke `deps` on a real VM:
#
#   /tmp/gpupv/gpupv-fnos.sh: line 341: b: unbound variable
#
# Cause: `local b` declares a variable but leaves it UNSET, and `have "$b"` reads
# it. `set -u` (which the guest tool uses) treats that as fatal, so the function
# aborted mid-loop - and because the abort happened after some output, `deps`
# still printed "toolchain ready". The failure looked like success, which is the
# worst possible shape for a diagnostic tool.
#
# Two layers here:
#   1. run every read-only command for real and require no "unbound variable";
#   2. statically require that a variable is assigned before it is read.
#
#   bash tests/guest_shellcheck.sh
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

unset WSL_LIB WSL_DRIVERS DS_BACKUP GPUPV_CACHE GPUPV_DRIVERSTORE 2>/dev/null || true

echo "== no 'unbound variable' from any read-only command"
for cmd in "deps" "triage" "verify --quick" "doctor"; do
	out=$(./gpupv-fnos.sh $cmd 2>&1)
	if printf '%s' "$out" | grep -q 'unbound variable'; then
		bad "$cmd: unbound variable" "$(printf '%s' "$out" | grep 'unbound variable' | head -2)"
	else
		ok "$cmd runs without an unbound variable"
	fi
done

echo "== a crash must not be reported as success"
# 'deps' specifically: an abort mid-loop once printed OK anyway.
out=$(./gpupv-fnos.sh deps 2>&1); rc=$?
if printf '%s' "$out" | grep -q 'unbound variable'; then
	bad "deps printed a result despite crashing" "$rc"
elif [ "$rc" -eq 0 ]; then
	printf '%s' "$out" | grep -q 'OK' && ok "deps exits 0 with an OK line" || bad "deps exit 0 without OK"
else
	printf '%s' "$out" | grep -q 'FAIL' && ok "deps exits non-zero with a FAIL line" || bad "deps failed silently"
fi

echo "== statically: a variable must be assigned before it is read"
# Every `local x` without a value, then any later read of "$x" in the same file,
# is a candidate. Assignment forms allowed: x=, local x= , for x in, read x,
# x() {, $(... ) captured into x.
viol=""
for f in gpupv.sh lib/*.sh; do
	while IFS= read -r hit; do
		[ -n "$hit" ] && viol="$viol$f:$hit"$'\n'
	done < <(awk '
		{
			# collect variables declared without a value
			if (match($0, /^[[:space:]]*local[[:space:]]+/)) {
				line = $0
				sub(/^[[:space:]]*local[[:space:]]+/, "", line)
				n = split(line, parts, /[[:space:]]+/)
				for (i = 1; i <= n; i++) {
					name = parts[i]
					if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && index(line, name "=") == 0)
						unset[name] = 1
				}
			}
			# any assignment to that name clears it
			for (name in unset) {
				if ($0 ~ ("(^|[[:space:]])" name "=") ||
				    $0 ~ ("for[[:space:]]+" name "[[:space:]]+in") ||
				    $0 ~ ("read[[:space:]]+(-[a-z]+[[:space:]]+)?" name) ||
				    $0 ~ ("(^|[[:space:]])" name "\\("))
					delete unset[name]
			}
			# a quoted read of a still-unset name is the bug
			for (name in unset) {
				if ($0 ~ ("\\$\"" name "\"") || $0 ~ ("\\$\\{" name "\\}") || $0 ~ ("\\$" name "([^A-Za-z0-9_]|$)"))
					printf "%d: reads unset local %s\n", FNR, name
			}
		}
	' "$f")
done
if [ -n "$viol" ]; then
	bad "reads of unset locals" "$(printf '%s' "$viol" | head -6)"
else
	ok "every local is assigned before it is read"
fi

echo "== the generated single file behaves the same"
bash tools/build-single.sh >/dev/null 2>&1
for cmd in "deps" "triage"; do
	out=$( (cd /tmp && cp "$REPO/gpupv-fnos.sh" ./.gpupv-solo && chmod +x ./.gpupv-solo && ./.gpupv-solo $cmd) 2>&1)
	if printf '%s' "$out" | grep -q 'unbound variable'; then
		bad "single-file $cmd: unbound variable" "$(printf '%s' "$out" | grep 'unbound' | head -1)"
	else
		ok "single-file $cmd runs without an unbound variable"
	fi
done
rm -f /tmp/.gpupv-solo

printf '\n==== guest shellcheck: %d passed, %d failed ====\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
