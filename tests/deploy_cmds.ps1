# Mirrors the Deploy command list so the exact strings sent over ssh can be
# inspected without a Windows host or a guest. Run:
#   pwsh -NoProfile -File tests/deploy_cmds.ps1 [-SkipDriverStore]
param(
    [string]$RemoteDir = '/tmp/gpupv',
    [string]$GuestScript = 'gpupv-fnos.sh',
    [string]$DriverStoreLeaf = 'nv_dispi.inf_amd64_0000000000000000',
    [switch]$SkipDriverStore
)
$storeArg = if ($SkipDriverStore) { '' } else { " $RemoteDir/nvstore/$DriverStoreLeaf" }
$cmds = @(
    "chmod +x $RemoteDir/$GuestScript"
    "rm -rf $RemoteDir/nvstore && mkdir -p $RemoteDir/nvstore"
    "tar -xf $RemoteDir/nvstore.tar -C $RemoteDir/nvstore 2>/dev/null || true"
    ('if [ -d "' + $RemoteDir + '/nvstore/' + $DriverStoreLeaf + '" ]; then echo "unpacked: $(ls ' + $RemoteDir + '/nvstore/' + $DriverStoreLeaf + ' | wc -l) files into nvstore/' + $DriverStoreLeaf + '"; else echo "unpacked: $(ls ' + $RemoteDir + '/nvstore | wc -l) files (flat - the archive had no folder root)"; fi')
    "sudo -v"
    "sudo -n $RemoteDir/$GuestScript setup$storeArg"
)
$cmds | ForEach-Object { Write-Output "CMD: $_" }
Write-Output '--- joined as ssh sends it:'
Write-Output ($cmds -join '; ')
