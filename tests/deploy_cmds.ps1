# Mirrors the Deploy command list so the exact strings sent over ssh can be inspected
# without a Windows host or a guest. Run: pwsh -NoProfile -File tests/deploy_cmds.ps1
param(
    [string]$RemoteDir = '/tmp/gpupv',
    [string]$GuestScript = 'gpupv-fnos.sh',
    [switch]$SkipDriverStore
)
$setupArg = if ($SkipDriverStore) { '' } else { " $RemoteDir/nvstore" }
$cmds = @(
    "chmod +x $RemoteDir/$GuestScript"
    "mkdir -p $RemoteDir/nvstore"
    "tar -xf $RemoteDir/nvstore.tar -C $RemoteDir/nvstore --strip-components=1"
    ('echo "unpacked: $(ls ' + $RemoteDir + '/nvstore | wc -l) files"')
    "$RemoteDir/$GuestScript driverstore compare $RemoteDir/nvstore"
    "sudo $RemoteDir/$GuestScript setup$setupArg"
)
$cmds | ForEach-Object { Write-Output "CMD: $_" }
Write-Output '--- joined as ssh sends it:'
Write-Output ($cmds -join '; ')
