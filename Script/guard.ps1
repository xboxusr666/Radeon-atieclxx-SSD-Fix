# Radeon-atieclxx-SSD-Fix – Guard. Runs as SYSTEM via the scheduled task "Radeon-atieclxx-SSD-Fix" (3 minutes after startup and every 30 minutes).
# Keeps the targeted protection up to date and checks after a driver change whether AMD has fixed the bug.
. (Join-Path $PSScriptRoot 'Core.ps1')

$proc = Get-AmdProcess
if (-not $proc) { return }   # Service is not running (e.g. disabled): nothing to do
$id = ''
try { $id = $proc.MainModule.FileVersionInfo.FileVersion + ' | ' + $proc.MainModule.FileName } catch { try { $id = [string]$proc.Path } catch {} }
$s = $null
if (Test-Path -LiteralPath $script:StateFile) { try { $s = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
function Save-State([string]$Result) {
  try {
    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
    [pscustomobject]@{ DriverId = $id; Result = $Result; Date = (Get-Date -Format s) } | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
  } catch {}
}
function KB([double]$Bytes) { '{0:N0} KB/s' -f ([math]::Max($Bytes, 0) / 1KB) }
$same = [bool]($s -and $s.DriverId -eq $id)

if (Test-Protection) {
  if ($same) { return }                                   # Normal case: protection is active, driver unchanged
  if (-not $s) { Save-State 'Bug'; Write-Log ('Guard initialized, protection active (driver ' + $id + ').'); return }
  # Driver changed: briefly remove protection and measure whether the bug still exists.
  Remove-Protection | Out-Null
  $b = Measure-WriteRate 8
  if ($b -lt 0) { Set-Protection | Out-Null; return }
  if ($b -lt $script:WriteThreshold) {
    Save-State 'Fixed'
    Write-Log ('New driver (' + $id + '): no continuous write load anymore (' + (KB $b) + '). AMD has fixed the bug; protection remains lifted.')
    return
  }
  $ok = Set-Protection
  Start-Sleep -Seconds 2
  $n = Measure-WriteRate 8
  if ($ok -and $n -ge 0 -and $n -lt $script:WriteThreshold) {
    Save-State 'Bug'
    Write-Log ('New driver (' + $id + '): bug persists (' + (KB $b) + '), protection re-applied, afterwards ' + (KB $n) + '.')
  } else {
    Save-State 'Other'
    Write-Log ('WARNING: New driver (' + $id + ') continues writing despite protection (' + (KB $n) + '). Please open Radeon-atieclxx-SSD-Fix and select "Disable service".')
    Send-Notification 'Radeon-atieclxx-SSD-Fix: The AMD driver continues writing to the SSD despite protection. Please open Radeon-atieclxx-SSD-Fix and select "Disable service".'
  }
  return
}

# Protection not set (e.g. after a driver update replaced the file): measure write rate.
$b = Measure-WriteRate 8
if ($b -lt 0) { return }
if ($b -lt $script:WriteThreshold) {
  if (-not ($same -and $s.Result -eq 'Fixed')) { Save-State 'Fixed'; Write-Log ('No continuous write load (' + (KB $b) + ', driver ' + $id + '), nothing to do.') }
  return
}
if ($same -and $s.Result -eq 'Other') { return }       # already reported for this driver
$ok = Set-Protection
$n = $b
if ($ok) { Start-Sleep -Seconds 2; $n = Measure-WriteRate 8 }
if ($ok -and $n -ge 0 -and $n -lt $script:WriteThreshold) {
  Save-ProtectionFinding -Type 'Protection' -RateBefore $b
  Save-State 'Bug'
  Write-Log ('Bug detected (' + (KB $b) + ', driver ' + $id + '), protection applied, afterwards ' + (KB $n) + '.')
} else {
  Save-State 'Other'
  Write-Log ('WARNING: atieclxx.exe is writing continuously (' + (KB $b) + '), targeted protection does not work here. Please open Radeon-atieclxx-SSD-Fix and select "Disable service".')
  Send-Notification 'Radeon-atieclxx-SSD-Fix: The AMD driver is writing continuously to the SSD and targeted protection does not work here. Please open Radeon-atieclxx-SSD-Fix and select "Disable service".'
}
