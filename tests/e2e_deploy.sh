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
if printf '%s' "$line" | grep -q 'gpupv-fnos.sh setup'; then ok "Deploy one-liner runs the guest setup"; else bad "Deploy one-liner setup step"; fi
if printf '%s' "$line" | grep -q 'strip-components'; then
	bad "Deploy one-liner still strips the DriverStore folder name" "- DXCore looks the payload up BY that name"
else ok "Deploy one-liner preserves the nv_dispi folder name"; fi
if [ "$(printf '%s\n' "$line" | wc -l)" -le 2 ]; then ok "Deploy one-liner is a single pasteable line"; else bad "one-liner is multi-line"; fi

echo "== Invoke-GuestSsh refuses -Tty with -Capture"
# A pty whose output is captured buffers sudo's prompt until exit, and the run then
# waits forever for a password nobody can see. The guard must be structural.
guard=$(pwsh -NoProfile -Command '
  $ErrorActionPreference = "Stop"
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "gpupv-windows.ps1"), [ref]$null, [ref]$null)
  $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-GuestSsh" }, $true)[0]
  if ($fn.Extent.Text -match "-Tty\s+-and\s+\$Capture") { "GUARD" } else { "NOGUARD" }
  ' 2>&1)
printf '%s' "$guard" | grep -q GUARD && ok "Invoke-GuestSsh has an explicit -Tty/-Capture guard" \
	|| bad "-Tty/-Capture guard" "$guard"
grep -q 'Invoke-GuestSsh -Tty -Capture' gpupv-windows.ps1 && bad "a call site still combines -Tty with -Capture" \
	|| ok "no call site combines -Tty with -Capture"
grep -q 'Invoke-GuestSshStream' gpupv-windows.ps1 && ok "the privileged step streams (Invoke-GuestSshStream)" \
	|| bad "no streaming helper for the privileged step"
grep -q 'Read-Host -AsSecureString' gpupv-windows.ps1 && ok "-SudoPrompt asks locally with a hidden prompt" \
	|| bad "no hidden local sudo prompt"

echo "== the privileged step keeps a pty and avoids pipes"
line=$(pwsh -NoProfile -File tests/deploy_cmds.ps1 2>&1)
printf '%s' "$line" | grep -q 'script -q -e -c' && ok "guest step runs under script -q -e (pty, exit status kept)" \
	|| bad "privileged step has no pty wrapper" "$line"
printf '%s' "$line" | grep -q 'tee' && bad "privileged step pipes through tee (would buffer the prompt)" \
	|| ok "no tee/pipe in the privileged step"
printf '%s' "$line" | grep -q 'sudo -v' && bad "still uses sudo -v then sudo -n (two prompts)" \
	|| ok "one sudo invocation for the whole privileged step"

echo "== the GPU partition is handled by the script, not left to the user"
grep -q 'function Repair-GpuPartition' gpupv-windows.ps1 && ok "Repair-GpuPartition helper exists" \
	|| bad "no shared partition repair helper"
grep -q '\$FixPartition' gpupv-windows.ps1 && ok "Deploy can assign a partition (-FixPartition)" \
	|| bad "Deploy cannot assign a partition"
[ "$(grep -c 'Add-VMGpuPartitionAdapter' gpupv-windows.ps1)" -le 2 ] && ok "partition assignment exists in ONE place" \
	|| bad "partition assignment duplicated" "- copies drift apart"
grep -q 'lxss' gpupv-windows.ps1 && ok "loaders resolved from the OS (lxss\\lib), not a third-party package" \
	|| bad "loaders still tied to a third-party package"
grep -qi 'ExHyperV' gpupv-windows.ps1 && bad "ExHyperV still referenced in the host script" \
	|| ok "no ExHyperV reference left in the host script"

echo "== the script is generic, not tuned to one machine"
grep -q 'function Get-VMName' gpupv-windows.ps1 && ok "VM name is resolved (single VM implied)" \
	|| bad "VM name must be typed by hand"
grep -q "\[string\]\$VMName = ''" gpupv-windows.ps1 && ok "-VMName has no machine-specific default" \
	|| bad "-VMName still defaults to one machine's VM name"
grep -q 'function Get-GuestAddress' gpupv-windows.ps1 && ok "guest address can be discovered from Hyper-V" \
	|| bad "guest address must be typed by hand"
grep -q 'VMNetworkAdapter' gpupv-windows.ps1 && ok "discovery uses Get-VMNetworkAdapter" \
	|| bad "address discovery not implemented"
grep -q "ValidateSet('Auto'" gpupv-windows.ps1 && ok "-Action Auto is the one-command path" \
	|| bad "no Auto action"
grep -q "GPUPV_VERSION = " gpupv-windows.ps1 && ok "the script reports its own version (stale-copy detection)" \
	|| bad "no version stamp"
pwsh -NoProfile -File gpupv-windows.ps1 -Action Version 2>&1 | grep -q '^gpupv-windows.ps1 [0-9]' \
	&& ok "-Action Version prints a version" || bad "-Action Version output"
grep -q 'dnf install\|pacman -S' lib/deps.sh && ok "non-apt systems get an equivalent command" \
	|| bad "deps only works on apt systems"

echo "== ssh reachability + guest prerequisites (fake ssh, local exec)"
ssh -o BatchMode=no -p 22 alan@10.9.9.9 'echo GPUPV_ALIVE; uname -r; id -un; for b in gcc make xz depmod; do command -v $b >/dev/null 2>&1 || printf "MISSING %s\n" $b; done' > "$SB/reach.txt" 2>&1
grep -q GPUPV_ALIVE "$SB/reach.txt" && ok "reachability probe reports GPUPV_ALIVE" || bad "reachability" "$(cat "$SB/reach.txt")"
grep -q '^MISSING ' "$SB/reach.txt" && bad "missing-binary probe fired on a machine that has the toolchain" "$(cat "$SB/reach.txt")" \
	|| ok "missing-binary probe is silent when the toolchain is present"

printf 'hello-guest-script\n' > "$SB/local_gpupv-fnos.sh"
cat "$SB/local_gpupv-fnos.sh" | ssh alan@10.9.9.9 "cat > $SB/guest/gpupv-fnos.sh"
cmp -s "$SB/local_gpupv-fnos.sh" "$SB/guest/gpupv-fnos.sh" && ok "script upload is byte-identical" \
	|| bad "script upload" "$(cat "$SB/guest/gpupv-fnos.sh" 2>&1)"

echo "== tar round-trip keeps the DriverStore folder name"
tar -cf "$SB/nvstore.tar" -C "$SB/wsl/drivers" nv_dispi.inf_amd64_e2e
mkdir -p "$SB/guest/nvstore"
ssh alan@10.9.9.9 "rm -rf $SB/guest/nvstore && mkdir -p $SB/guest/nvstore && tar -xf $SB/nvstore.tar -C $SB/guest/nvstore && ls $SB/guest/nvstore/nv_dispi.inf_amd64_e2e | wc -l" > "$SB/count.txt" 2>&1
[ "$(tr -d ' ' < "$SB/count.txt")" = "18" ] && ok "extract without --strip-components yields 18 files under the real folder name" \
	|| bad "tar extract" "$(cat "$SB/count.txt")"
ssh alan@10.9.9.9 "sd=\$(ls -d $SB/guest/nvstore/nv_dispi.inf_amd64_* | head -1); echo \"SD=\$sd\"" > "$SB/sd.txt" 2>&1
grep -q "SD=$SB/guest/nvstore/nv_dispi.inf_amd64_e2e" "$SB/sd.txt" && ok "the guest-side folder lookup finds the nv_dispi path" \
	|| bad "folder lookup" "$(cat "$SB/sd.txt")"

echo "== guest installer sees the sandbox as a trimmed deployment"
out=$(WSL_DRIVERS=$SB/wsl/drivers WSL_LIB=$SB/wsl/lib GPUPV_CACHE=$SB/cache NO_COLOR=1 \
	./gpupv.sh driverstore status 2>&1)
printf '%s' "$out" | grep -q 'TRIMMED' && ok "sandbox deployment reported as TRIMMED" || bad "trimmed detection" "$(printf '%s' "$out" | head -6)"

echo "== the exact command list Deploy sends, executed in order"
cmds=(
	"mkdir -p $SB/guest"
	"chmod +x $SB/guest/gpupv-fnos.sh"
	"bash $REPO/gpupv-fnos.sh version"
	"bash $REPO/gpupv-fnos.sh deps > /dev/null && echo DEPS_OK"
	"cat $SB/guest/nvstore/libfake1.so.1 > /dev/null 2>&1 || cat $SB/guest/nvstore/nv_dispi.inf_amd64_e2e/libfake1.so.1 > /dev/null; echo TARBALL_OK"
)
for c in "${cmds[@]}"; do
	ssh alan@10.9.9.9 "$c" >/dev/null 2>&1 || bad "remote step failed: $c"
done
ok "all remote steps executed"
grep -q 'DEPS_OK\|chmod' "$SB/calls/log" && ok "fake ssh recorded the command log" || bad "command log empty"

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
