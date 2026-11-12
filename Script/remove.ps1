# Radeon-atieclxx-SSD-Fix – Remove (launched by REMOVE.cmd with administrator privileges).
# Reverts all changes and deletes the program folder.
. (Join-Path $PSScriptRoot 'Core.ps1')
if (-not (Test-IsAdmin)) { Write-Host 'Please start via REMOVE.cmd (administrator privileges required).' -ForegroundColor Red; return }
Write-Host ('Radeon-atieclxx-SSD-Fix ' + $script:Version + ' - Remove')
Write-Host ''
Remove-Everything
& logman stop $script:TraceName -ets *> $null
Write-Host ('Task:       ' + $(if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) { 'still present!' } else { 'removed' }))
Write-Host ('Protection: ' + $(if (Test-Protection) { 'still active!' } else { 'removed' }))
Write-Host ('Service:    ' + (Get-ServiceText (Get-AmdService)))
if (Test-Path -LiteralPath $script:InstallDir) {
  $fromInside = $PSScriptRoot.StartsWith($script:InstallDir + '\', [StringComparison]::OrdinalIgnoreCase)
  if ($fromInside) {
    # Running from inside the program folder: wait until this window closes before deleting.
    $waitPid = $PID
    try {
      $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
      $parent = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $self.ParentProcessId)
      if ($parent -and $parent.Name -eq 'cmd.exe') { $waitPid = [int]$parent.ProcessId }
    } catch {}
    $cmd = 'Wait-Process -Id ' + $waitPid + ' -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1; Remove-Item -LiteralPath ''' + $script:InstallDir + ''' -Recurse -Force -ErrorAction SilentlyContinue'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $enc) -WindowStyle Hidden -WorkingDirectory $env:SystemRoot
    Write-Host ('Folder:     will be deleted after closing this window (' + $script:InstallDir + ')')
  } else {
    Remove-Item -LiteralPath $script:InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ('Folder:     ' + $(if (Test-Path -LiteralPath $script:InstallDir) { 'could not be deleted' } else { 'deleted' }))
  }
}
Write-Host ''
Write-Host 'All changes reverted. On affected drivers, atieclxx.exe will now copy itself every second again.' -ForegroundColor Yellow
