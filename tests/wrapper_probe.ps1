# Verify the wrapper string Invoke-GuestSshLive builds, and that bash runs it,
# records the exit code and tees the log.
param([string]$Remote = 'echo hi; false')
$RemoteLog = '/tmp/gpupv-wrap-test.log'
$wrapped = "{ rm -f $RemoteLog; { $Remote ; echo ""__GPUPV_RC=`$?"" ; } 2>&1 | tee -a $RemoteLog ; }"
Write-Output '--- wrapped:'
Write-Output $wrapped
Set-Content -Path /tmp/gpupv-wrap-test.sh -Value $wrapped -Encoding UTF8
