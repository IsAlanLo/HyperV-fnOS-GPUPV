# Prove that `script -q -e -c "cmd" log` gives the child a tty, so a prompt
# written WITHOUT a trailing newline is visible immediately (the sudo-prompt bug),
# and that the transcript + exit status can be read back.
#
# Run: bash tests/pty_prompt_probe.sh
set -u
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

command -v script >/dev/null 2>&1 || { echo "SKIP: no 'script' (util-linux) installed"; exit 0; }

log=$(mktemp); rc=$(mktemp)
# a command that prints a prompt with NO newline, waits for input, then exits 7
probe='/bin/sh -c "printf \"[sudo] password for test: \"; read x; echo; echo got=\$x; exit 7"'

echo "== script -q -e -c gives the child a tty and preserves the exit status"
out=$(printf 'secret\n' | script -q -e -c "$probe" "$log" 2>&1); code=$?
[ "$code" = "7" ] && ok "child exit status preserved (-e): $code" || bad "exit status" "got $code"

echo "== the prompt is in the transcript even though it has no trailing newline"
grep -q 'password for test:' "$log" && ok "prompt recorded in the transcript" \
	|| bad "prompt missing from transcript" "$(cat -v "$log" 2>/dev/null | head -3)"

echo "== the child saw a tty (this is what makes the prompt flush)"
ttyprobe='/bin/sh -c "if [ -t 0 ] && [ -t 1 ]; then echo IS_TTY; else echo NO_TTY; fi"'
script -q -e -c "$ttyprobe" "$rc" >/dev/null 2>&1
grep -q IS_TTY "$rc" && ok "child runs on a pty under script" \
	|| bad "child had no tty under script" "$(cat "$rc")"

echo "== a pipe instead of script loses the prompt until input arrives (the old bug)"
# same command, but stdout redirected through a pipe: the prompt is buffered
pipecmd='/bin/sh -c "printf \"[sudo] password for test: \"; read x; echo done"'
first=$( (printf 'x\n' | $pipecmd) 2>&1 | head -c 40 )
printf '%s' "$first" | grep -q 'password for test' && \
	echo "  (note: this shell's stdio happened to flush; the bug shows under ssh -t + capture)" \
	|| echo "  (confirmed: piped output did not flush the prompt)"

rm -f "$log" "$rc"
printf '\n==== pty probe: %d passed, %d failed ====\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
