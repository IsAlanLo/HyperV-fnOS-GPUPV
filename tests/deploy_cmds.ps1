# Mirrors the Deploy command list so the exact strings sent over ssh can be
# inspected without a Windows host or a guest. Keep in step with the Deploy
# branch: tests/e2e_deploy.sh asserts on what this prints.
#
#   pwsh -NoProfile -File tests/deploy_cmds.ps1 [-SkipDriverStore]
param(
    [string]$RemoteDir = '/tmp/gpupv',
    [string]$GuestScript = 'gpupv-fnos.sh',
    [string]$DriverStoreLeaf = 'nv_dispi.inf_amd64_0000000000000000',
    [switch]$SkipDriverStore
)

# step 5: unpack, no tty, captured
$cmds = @(
    "chmod +x $RemoteDir/$GuestScript"
    "rm -rf $RemoteDir/nvstore && mkdir -p $RemoteDir/nvstore"
    "tar -xf $RemoteDir/nvstore.tar -C $RemoteDir/nvstore"
    "ls -d $RemoteDir/nvstore/nv_dispi.inf_amd64_* 2>/dev/null | head -1"
)

# step 6: the privileged run. A guest pty (`script -q -e`) keeps sudo's prompt
# visible; no host-side pipe and no guest-side pipe, or the prompt is buffered.
$storeArg = if ($SkipDriverStore) { '' } else { " $RemoteDir/nvstore/$DriverStoreLeaf" }
$inner = "sudo $RemoteDir/$GuestScript setup$storeArg"
$live = "rm -f /tmp/gpupv-run.log /tmp/gpupv-run.rc; " +
        "if command -v script >/dev/null 2>&1; then script -q -e -c `"$inner`" /tmp/gpupv-run.log; " +
        "else $inner ; fi; echo `$? > /tmp/gpupv-run.rc"

$cmds | ForEach-Object { Write-Output "CMD: $_" }
Write-Output '--- privileged step (pty, no pipe):'
Write-Output $live
Write-Output '--- joined as ssh sends it:'
Write-Output (($cmds + $live) -join '; ')
