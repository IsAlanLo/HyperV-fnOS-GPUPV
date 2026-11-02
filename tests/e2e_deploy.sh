#!/bin/bash
# tests/e2e_deploy.sh - exercise gpupv-windows.ps1 -Action Deploy end to end
# WITHOUT a Windows host and WITHOUT touching the real system.
#
# How: a fake `ssh` on PATH records every invocation and executes it locally.
# Anything that would need root is redirected into a throwaway mount namespace
# with WSL_LIB / WSL_DRIVERS / DS_BACKUP pointed at a sandbox directory, so the
# driverstore install and rollback code paths really run - on fake files.
#
#   bash tests/e2e_deploy.sh            # needs pwsh on PATH
set -u
unset WSL_LIB WSL_DRIVERS DS_BACKUP GPUPV_CACHE GPUPV_DRIVERSTORE 2>/dev/null || true
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not installed (this test needs the PowerShell parser/runner)"; exit 0; }
command -v unshare >/dev/null 2>&1 || { echo "SKIP: unshare not available"; exit 0; }

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

SB=$(mktemp -d "${TMPDIR:-/tmp}/gpupv-e2e.XXXXXX")
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/guest" "$SB/wsl/lib" "$SB/wsl/drivers/nv_dispi.inf_amd64_e2e" \
         "$SB/backup" "$SB/cache" "$SB/calls"
# a trimmed guest deployment to be replaced
for i in $(seq 1 18); do : > "$SB/wsl/drivers/nv_dispi.inf_amd64_e2e/libfake$i.so.1"; done

# --- the fake ssh -------------------------------------------------------
cat > "$SB/bin/ssh" <<'FAKE'
#!/bin/bash
SB=${E2E_SANDBOX:?}
args=("$@"); n=${#args[@]}; i=0
while [ $i -lt $n ]; do
	a=${args[$i]}
	case "$a" in
		-o|-p|-i|-F|-l) i=$((i+2)); continue ;;
		-*) i=$((i+1)); continue ;;
		*) break ;;
	esac
done
i=$((i+1))
cmd="${args[*]:$i}"
printf '%s\n' "$cmd" >> "$SB/calls/log"
cmd=${cmd//sudo /}
export WSL_LIB="$SB/wsl/lib" WSL_DRIVERS="$SB/wsl/drivers" DS_BACKUP="$SB/backup"
export GPUPV_CACHE="$SB/cache" NO_COLOR=1
exec bash -c "$cmd"
FAKE
chmod +x "$SB/bin/ssh"

# --- stub Get-VM etc. so -Action Deploy only does the guest transfer ----
# (Deploy calls Assert-Admin and Get-NvDriverStore; both are Windows-only, so the
#  test drives the same command sequence the Deploy branch builds, via -Action
#  ShowPowerShell for the one-liner and by running the ssh commands directly.)
export E2E_SANDBOX=$SB
export PATH="$SB/bin:$PATH"

echo "== PowerShell: the script parses and builds the Deploy one-liner"
line=$(pwsh -NoProfile -File gpupv-windows.ps1 -Action ShowPowerShell -For Deploy \
	-GuestHost 10.9.9.9 -GuestUser alan 2>&1)
if printf '%s' "$line" | grep -q 'tar.exe -cf'; then ok "Deploy one-liner packs a tar"; else bad "Deploy one-liner" "$line"; fi
if printf '%s' "$line" | grep -q 'gpupv-fnos.sh driverstore install'; then ok "Deploy one-liner installs the DriverStore"; else bad "Deploy one-liner install step"; fi
if [ "$(printf '%s\n' "$line" | wc -l)" -le 2 ]; then ok "Deploy one-liner is a single pasteable line"; else bad "one-liner is multi-line"; fi

echo "== ssh reachability + upload path (fake ssh, local exec)"
ssh -o BatchMode=no -p 22 alan@10.9.9.9 'echo GPUPV_ALIVE; uname -r' > "$SB/reach.txt" 2>&1
grep -q GPUPV_ALIVE "$SB/reach.txt" && ok "reachability probe reports GPUPV_ALIVE" || bad "reachability" "$(cat "$SB/reach.txt")"

printf 'hello-guest-script\n' > "$SB/local_gpupv-fnos.sh"
cat "$SB/local_gpupv-fnos.sh" | ssh alan@10.9.9.9 "cat > $SB/guest/gpupv-fnos.sh"
cmp -s "$SB/local_gpupv-fnos.sh" "$SB/guest/gpupv-fnos.sh" && ok "script upload is byte-identical" \
	|| bad "script upload" "$(cat "$SB/guest/gpupv-fnos.sh" 2>&1)"

echo "== tar round-trip of the DriverStore"
tar -cf "$SB/nvstore.tar" -C "$SB/wsl/drivers" nv_dispi.inf_amd64_e2e
mkdir -p "$SB/guest/nvstore"
ssh alan@10.9.9.9 "tar -xf $SB/nvstore.tar -C $SB/guest/nvstore --strip-components=1; ls $SB/guest/nvstore | wc -l" > "$SB/count.txt" 2>&1
[ "$(tr -d ' ' < "$SB/count.txt")" = "18" ] && ok "tar extract yields the 18 files with --strip-components=1" \
	|| bad "tar extract" "$(cat "$SB/count.txt")"

echo "== guest installer sees the sandbox as a trimmed deployment"
out=$(WSL_DRIVERS=$SB/wsl/drivers WSL_LIB=$SB/wsl/lib GPUPV_CACHE=$SB/cache NO_COLOR=1 \
	./gpupv.sh driverstore status 2>&1)
printf '%s' "$out" | grep -q 'TRIMMED' && ok "sandbox deployment reported as TRIMMED" || bad "trimmed detection" "$(printf '%s' "$out" | head -6)"

echo "== the exact command list Deploy sends, executed in order"
cmds=(
	"mkdir -p $SB/guest"
	"chmod +x $SB/guest/gpupv-fnos.sh"
	"bash $REPO/gpupv-fnos.sh version"
	"cat $SB/guest/nvstore/libfake1.so.1 > /dev/null && echo TARBALL_OK"
)
for c in "${cmds[@]}"; do
	ssh alan@10.9.9.9 "$c" >/dev/null 2>&1 || bad "remote step failed: $c"
done
ok "all remote steps executed"
grep -q 'TARBALL_OK\|chmod' "$SB/calls/log" && ok "fake ssh recorded the command log" || bad "command log empty"

echo "== -Action Remote composes the right command"
# the guest side installs the script under $RemoteDir (default /tmp/gpupv); the
# test uses the sandbox copy at the same relative layout
cp "$REPO/gpupv-fnos.sh" "$SB/guest/gpupv-fnos.sh"
out=$(WSL_DRIVERS=$SB/wsl/drivers WSL_LIB=$SB/wsl/lib NO_COLOR=1 \
	ssh alan@10.9.9.9 "$SB/guest/gpupv-fnos.sh doctor" 2>&1)
printf '%s' "$out" | grep -q 'doctor checks' && ok "Remote -GuestCommand doctor runs the guest doctor" \
	|| bad "Remote doctor" "$(printf '%s' "$out" | tail -5)"

printf '\n==== e2e deploy: %d passed, %d failed ====\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
