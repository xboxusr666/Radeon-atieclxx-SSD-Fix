# Radeon-atieclxx-SSD-Fix – Core: shared functions for GUI, guard task, status check, and uninstaller.
# Dot-sourced via . ; loading this file makes no changes to the system.
$ErrorActionPreference = 'Continue'

$script:Version        = '2.1'
$script:TargetFile     = Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe'
$script:ServiceName    = 'AMD External Events Utility'
$script:Name           = 'Radeon-atieclxx-SSD-Fix'
$script:TaskName       = $script:Name
$script:InstallDir     = Join-Path $env:ProgramFiles $script:Name
$script:OldName        = 'AMD-SSD-Fix'   # former name; task and folder with this name are removed during setup
$script:OldInstallDir  = Join-Path $env:ProgramFiles $script:OldName
$script:LogFile        = Join-Path $script:InstallDir 'log.txt'
$script:StateFile      = Join-Path $script:InstallDir 'state.json'
$script:FindingFile    = Join-Path $script:InstallDir 'finding.json'
$script:SystemSid      = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$script:TraceName      = 'RadeonSsdFixTrace'
# Above this write rate (bytes/s), atieclxx.exe is considered affected. The bug writes ~660 KB/s or more;
# a single copy at service startup (~0.66 MB) averages ~85 KB/s over an 8-second window and stays well below this.
$script:WriteThreshold = 150KB

# ------------------------------------------------------------------ Fundamentals
function Test-IsAdmin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-AmdProcesses { @(Get-Process atieclxx -ErrorAction SilentlyContinue) }
function Get-AmdProcess { Get-AmdProcesses | Select-Object -First 1 }
function Get-AmdService {
  # Search first by service name, then display name, and finally by the executable atiesrxx.exe.
  $d = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
  if (-not $d) { $d = Get-Service -DisplayName $script:ServiceName -ErrorAction SilentlyContinue }
  if (-not $d) {
    $w = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match 'atiesrxx\.exe' } | Select-Object -First 1
    if ($w) { $d = Get-Service -Name $w.Name -ErrorAction SilentlyContinue }
  }
  return ($d | Select-Object -First 1)
}
function Get-ServiceText($Service) {
  if (-not $Service) { return 'not present' }
  $st = switch ([string]$Service.Status) { 'Running' { 'running' } 'Stopped' { 'stopped' } 'StartPending' { 'starting' } 'StopPending' { 'stopping' } default { [string]$Service.Status } }
  $ty = switch ([string]$Service.StartType) { 'Automatic' { 'automatic' } 'Manual' { 'manual' } 'Disabled' { 'disabled' } default { [string]$Service.StartType } }
  return ($st + ', ' + $ty)
}
function Write-Log([string]$Text) {
  try {
    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
    Add-Content -LiteralPath $script:LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Text) -Encoding UTF8
  } catch {}
}
function Send-Notification([string]$Text) {
  $m = Join-Path $env:SystemRoot 'System32\msg.exe'   # not included in Windows Home
  if (Test-Path -LiteralPath $m) { try { & $m '*' '/TIME:3600' ($Text + ' Details: ' + $script:LogFile) } catch {} }
}
function Wait-Measurement([double]$Seconds, [string]$Phase) {
  # Waits and reports progress to the GUI (if active).
  if ($script:Progress) { $script:Progress.Phase = $Phase; $script:Progress.End = (Get-Date).AddSeconds($Seconds) }
  Start-Sleep -Milliseconds ([int]($Seconds * 1000))
}
function Set-Phase([string]$Phase) {
  if ($script:Progress) { $script:Progress.Phase = $Phase; $script:Progress.End = [datetime]::MinValue }
}

# ------------------------------------------------------------------ Windows Functions (P/Invoke)
function Initialize-Native {
  if ('AmdFix.Native' -as [type]) { return }
  Add-Type -Namespace AmdFix -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern uint QueryDosDeviceW(string device, System.Text.StringBuilder target, int max);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool DeviceIoControl(Microsoft.Win32.SafeHandles.SafeFileHandle handle, uint code, IntPtr inBuffer, uint inSize, byte[] outBuffer, uint outSize, out uint returned, IntPtr overlapped);
public static long FileUsn(string path) {
  // FSCTL_READ_FILE_USN_DATA: last update sequence number (USN) of the file in the NTFS change journal.
  using (Microsoft.Win32.SafeHandles.SafeFileHandle h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
    if (h.IsInvalid) return -1;
    byte[] buffer = new byte[1024];
    uint n;
    if (!DeviceIoControl(h, 0x000900EB, IntPtr.Zero, 0, buffer, (uint)buffer.Length, out n, IntPtr.Zero) || n < 48) return -1;
    int version = BitConverter.ToUInt16(buffer, 4);
    return BitConverter.ToInt64(buffer, version >= 3 ? 40 : 24);
  }
}
'@
}
function Get-FileUsn([string]$Path) {
  # Update sequence number in the NTFS change journal; increments on every write (0/-1 = unavailable).
  # Timestamps cannot be used for this: CopyFile preserves LastWriteTime and even the NTFS change time from the source.
  try { Initialize-Native; return [AmdFix.Native]::FileUsn($Path) } catch { return -1 }
}
function Get-DriveMap {
  # \Device\HarddiskVolumeN -> C:
  $map = @{}
  try {
    Initialize-Native
    foreach ($drv in [System.IO.DriveInfo]::GetDrives()) {
      $name = $drv.Name.TrimEnd('\')
      $sb = New-Object System.Text.StringBuilder 1024
      if ([AmdFix.Native]::QueryDosDeviceW($name, $sb, 1024) -gt 0) { $map[$sb.ToString()] = $name }
    }
  } catch {}
  return $map
}

# ------------------------------------------------------------------ Measurement
function Measure-WriteRate {
  # Bytes per second written by all atieclxx.exe processes combined (-1 = cannot be measured).
  param([int]$Seconds = 8)
  $start = @(Get-CimInstance Win32_Process -Filter "Name='atieclxx.exe'" -ErrorAction SilentlyContinue)
  if (-not $start.Count) { return -1 }
  $before = @{}
  foreach ($p in $start) { $before[[int]$p.ProcessId] = [double]$p.WriteTransferCount }
  Wait-Measurement $Seconds 'Measuring write rate'
  $sum = 0.0; $found = 0
  foreach ($q in @(Get-CimInstance Win32_Process -Filter "Name='atieclxx.exe'" -ErrorAction SilentlyContinue)) {
    $id = [int]$q.ProcessId
    if ($before.ContainsKey($id)) { $sum += [double]$q.WriteTransferCount - $before[$id]; $found++ }
  }
  if ($found -eq 0) { return -1 }
  return ($sum / $Seconds)
}
function Test-SelfCopy {
  # Is the known copy continuously being overwritten right now? Detected via the file's USN.
  # Without a change journal (rare), this returns $false; the ETW trace then decides.
  if (-not (Test-Path -LiteralPath $script:TargetFile)) { return $false }
  $u0 = Get-FileUsn $script:TargetFile
  if ($u0 -le 0) { return $false }
  Wait-Measurement 3 'Checking for self-copy'
  $u1 = Get-FileUsn $script:TargetFile
  return ($u1 -gt 0 -and $u1 -ne $u0)
}
function Get-TraceTargets {
  # Uses Event Tracing for Windows (ETW) to determine where atieclxx.exe is writing. Requires admin rights.
  param([int]$Seconds = 4)
  if (-not (Test-IsAdmin)) { return @() }
  $ids = @(Get-AmdProcesses | ForEach-Object { $_.Id })
  if (-not $ids.Count) { return @() }
  $etl = Join-Path $env:TEMP ('amdfix-' + [guid]::NewGuid().ToString('N') + '.etl')
  try {
    & logman stop $script:TraceName -ets *> $null
    # Small buffers and a 64 MB maximum file size so an interrupted trace cannot grow unbounded.
    & logman start $script:TraceName -p Microsoft-Windows-Kernel-File 0x1FB0 0xFF -o $etl -ets -bs 256 -nb 16 64 -max 64 *> $null
    if ($LASTEXITCODE -ne 0) { return @() }
    Wait-Measurement $Seconds 'Determining write target'
    & logman stop $script:TraceName -ets *> $null
    Set-Phase 'Evaluating trace'
    $filter = ($ids | ForEach-Object { '@ProcessID=' + $_ }) -join ' or '
    $ev = @(Get-WinEvent -Path $etl -Oldest -FilterXPath ('*[System[Execution[' + $filter + ']]]') -ErrorAction Stop)
    $fo = @{}; $hits = @{}; $open = @{}
    foreach ($e in $ev) {
      $h = @{}; foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $h[$d.Name] = $d.'#text' }
      $n = $h['FileName']; if (-not $n) { $n = $h['FilePath'] }
      if ($e.Id -eq 12 -and $h['FileObject']) { $fo[$h['FileObject']] = $n }
      if (-not $n -and $h['FileObject'] -and $fo.ContainsKey($h['FileObject'])) { $n = $fo[$h['FileObject']] }
      if ($e.Id -eq 16 -or $e.Id -eq 30) {        # 16 = Write, 30 = CreateNewFile
        if ($n) { $hits[$n] = 1 + [int]$hits[$n] }
        elseif ($h['FileKey']) { $open[$h['FileKey']] = 1 + [int]$open[$h['FileKey']] }
      }
    }
    if ($open.Count) {
      # Files opened before the trace started: look up names via NameCreate events (ID 10).
      foreach ($e in @(Get-WinEvent -Path $etl -Oldest -FilterXPath '*[System[(EventID=10)]]' -ErrorAction SilentlyContinue)) {
        $h = @{}; foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $h[$d.Name] = $d.'#text' }
        $k = $h['FileKey']
        if ($k -and $open.ContainsKey($k) -and $h['FileName']) { $hits[$h['FileName']] = [int]$hits[$h['FileName']] + $open[$k]; $open.Remove($k) }
      }
    }
    $map = Get-DriveMap
    $list = New-Object System.Collections.ArrayList
    foreach ($kv in ($hits.GetEnumerator() | Sort-Object Value -Descending)) {
      $p = [string]$kv.Key
      if ($p -match 'DriverStore') { continue }
      foreach ($g in $map.GetEnumerator()) { if ($p.StartsWith($g.Key + '\', [StringComparison]::OrdinalIgnoreCase)) { $p = $g.Value + $p.Substring($g.Key.Length); break } }
      [void]$list.Add($p)
    }
    return @($list | Select-Object -First 5)
  } catch { return @() }
  finally {
    & logman stop $script:TraceName -ets *> $null
    Remove-Item -LiteralPath $etl -Force -ErrorAction SilentlyContinue
  }
}

# ------------------------------------------------------------------ Targeted Protection (File Permissions)
function Test-Protection {
  if (-not (Test-Path -LiteralPath $script:TargetFile)) { return $false }
  try { $acl = Get-Acl -LiteralPath $script:TargetFile } catch { return $false }
  foreach ($r in $acl.Access) {
    if ($r.AccessControlType -ne 'Deny' -or $r.IsInherited) { continue }
    try { if ($r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $script:SystemSid) { return $true } } catch {}
  }
  return $false
}
function Set-Protection {
  # Denies only the SYSTEM account permission to overwrite or delete this single file.
  for ($i = 0; $i -lt 6 -and -not (Test-Path -LiteralPath $script:TargetFile); $i++) { Start-Sleep -Milliseconds 300 }
  if (-not (Test-Path -LiteralPath $script:TargetFile)) { return $false }
  & icacls $script:TargetFile /deny '*S-1-5-18:(WD,AD,WEA,WA,DE)' *> $null
  return (Test-Protection)
}
function Remove-Protection {
  if (Test-Path -LiteralPath $script:TargetFile) { & icacls $script:TargetFile /remove:d '*S-1-5-18' *> $null }
  return (-not (Test-Protection))
}

# ------------------------------------------------------------------ Service
function Disable-Service {
  # Returns: OK, StillRunning (reboot required), Error, or NoService
  $d = Get-AmdService
  if (-not $d) { return 'NoService' }
  try { Set-Service -Name $d.Name -StartupType Disabled -ErrorAction Stop } catch { return 'Error' }
  try { Stop-Service -Name $d.Name -Force -ErrorAction SilentlyContinue } catch {}
  for ($i = 0; $i -lt 20 -and (Get-AmdProcess); $i++) { Start-Sleep -Milliseconds 250 }
  if (Get-AmdProcess) { Get-AmdProcesses | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 700 }
  if (Get-AmdProcess) { return 'StillRunning' }
  return 'OK'
}
function Enable-Service {
  $d = Get-AmdService
  if (-not $d) { return $false }
  try { Set-Service -Name $d.Name -StartupType Automatic -ErrorAction Stop } catch { return $false }
  try { Start-Service -Name $d.Name -ErrorAction Stop } catch {}
  for ($i = 0; $i -lt 20 -and -not (Get-AmdProcess); $i++) { Start-Sleep -Milliseconds 250 }
  return $true
}

# ------------------------------------------------------------------ SSD, Timeframe, Finding
function Get-SsdInfo {
  $res = [ordered]@{ Model = ''; Capacity = 0; Wear = $null; PowerOnHours = $null }
  try {
    $pd = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
    $res.Model = [string]$pd.FriendlyName; $res.Capacity = [double]$pd.Size
    try {
      $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
      if ($rc.Wear -gt 0) { $res.Wear = [double]$rc.Wear }                       # many SSDs only report 0 here
      if ($rc.PowerOnHours -gt 0) { $res.PowerOnHours = [double]$rc.PowerOnHours }
    } catch {}
  } catch {}
  [pscustomobject]$res
}
function Get-GpuFirstInstall {
  # Earliest initial installation date of an AMD graphics device (the bug cannot have occurred prior to this).
  $dates = @()
  try {
    foreach ($d in @(Get-PnpDevice -Class Display -ErrorAction Stop | Where-Object { $_.FriendlyName -match 'Radeon|AMD' })) {
      $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_FirstInstallDate -ErrorAction SilentlyContinue
      if ($p -and $p.Data) { $dates += [datetime]$p.Data }
    }
  } catch {}
  if ($dates.Count) { return ($dates | Sort-Object | Select-Object -First 1) }
  return $null
}
function Save-ProtectionFinding {
  # Records when writing was stopped by a fix and what the write rate was beforehand.
  param([string]$Type, [double]$RateBefore, [switch]$AllowAssumption)
  if (Test-Path -LiteralPath $script:FindingFile) { return }
  $r = $RateBefore
  if ($r -lt $script:WriteThreshold) {
    if (-not $AllowAssumption) { return }
    $r = 0
    if (Test-Path -LiteralPath $script:TargetFile) { try { $r = [double](Get-Item -LiteralPath $script:TargetFile -Force).Length } catch {} }
  }
  try {
    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
    [pscustomobject]@{ Type = $Type; Since = (Get-Date -Format s); RateBefore = [math]::Round($r) } | ConvertTo-Json | Set-Content -LiteralPath $script:FindingFile -Encoding UTF8
  } catch {}
}
function Get-ProtectionFinding {
  if (-not (Test-Path -LiteralPath $script:FindingFile)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $script:FindingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($raw -and $raw.PSObject.Properties['Seit'] -and -not $raw.PSObject.Properties['Since']) {
      return [pscustomobject]@{ Type = $raw.Art; Since = $raw.Seit; RateBefore = $raw.RateVorher }
    }
    return $raw
  } catch { return $null }
}
function Get-DamageEstimate {
  # Estimate: write rate x operating hours since the AMD graphics card was installed.
  param([string]$Status, [double]$Rate, $Ssd, $Finding)
  $single = $null
  if (Test-Path -LiteralPath $script:TargetFile) { try { $single = [double](Get-Item -LiteralPath $script:TargetFile -Force).Length } catch {} }
  $active = $Status -in 'AffectedSelfCopy', 'AffectedOther', 'ProtectionIneffective'
  if ($active) { $r = $Rate; $end = Get-Date; $basis = 'Measurement' }
  elseif ($Finding -and $Finding.Since) { $r = [double]$Finding.RateBefore; $end = [datetime]$Finding.Since; $basis = 'Finding' }
  elseif ($Status -eq 'Protected' -and $single) { $r = $single; $end = Get-Date; $basis = 'Assumption' }
  else { return $null }
  if ($r -le 0) { return $null }
  $start = Get-GpuFirstInstall
  $osInstall = $null
  try { $osInstall = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).InstallDate } catch {}
  if (-not $start) { $start = $osInstall }
  if (-not $start -or $end -le $start) { return $null }
  $days = ($end - $start).TotalDays
  $poh = if ($Ssd -and $Ssd.PowerOnHours) { [double]$Ssd.PowerOnHours } else { $null }
  # Operating hours per day: taken from the SSD if plausible (feature updates reset the OS install date),
  # otherwise 8 hours as a neutral assumption.
  $hpd = 8.0; $source = 'Assumption'
  if ($poh -and $osInstall) {
    $age = ((Get-Date) - $osInstall).TotalDays
    if ($age -ge 30) { $x = $poh / $age; if ($x -ge 1 -and $x -le 16) { $hpd = $x; $source = 'SSD' } }
  }
  $hours = $days * $hpd
  if ($poh) { $hours = [math]::Min($hours, $poh) }
  $bytes = $r * $hours * 3600
  $tbw = $null
  if ($Ssd -and $Ssd.Capacity -gt 0) { $tbw = [math]::Round($Ssd.Capacity / 1e12, 1) * 600 }   # typical warranty ~600 TBW per TB
  [pscustomobject]@{
    Basis = $basis; Active = $active; Rate = $r; Since = $start; End = $end; Days = [int][math]::Round($days)
    HoursPerDay = [math]::Round($hpd, 1); HoursSource = $source
    Bytes = $bytes; GbPerDay = $r * $hpd * 3600 / 1e9
    TbwTB = $tbw; PercentTbw = $(if ($tbw) { $bytes / 1e12 / $tbw * 100 } else { $null })
    Wear = $(if ($Ssd) { $Ssd.Wear } else { $null })
  }
}

# ------------------------------------------------------------------ Analysis
function Get-Analysis {
  param([int]$MeasureSeconds = 8)
  Set-Phase 'Reading system state'
  $service   = Get-AmdService
  $proc      = Get-AmdProcess
  $protected = Test-Protection
  $task      = [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
  $finding   = Get-ProtectionFinding
  $ssd       = Get-SsdInfo
  $rate      = -1
  if ($proc) { $rate = Measure-WriteRate -Seconds $MeasureSeconds }
  $variant = ''; $targets = @(); $affected = $false
  if (-not $service) { $status = 'NoService' }
  elseif (-not $proc) { $status = $(if ([string]$service.StartType -eq 'Disabled') { 'ServiceDisabled' } else { 'ServiceStopped' }) }
  elseif ($rate -lt 0) { $status = 'MeasurementFailed' }
  elseif ($rate -ge $script:WriteThreshold) {
    $affected = $true
    $self = Test-SelfCopy
    if (-not $self) {
      $targets = @(Get-TraceTargets -Seconds 4)
      $self = [bool]($targets | Where-Object { $_ -match 'systemprofile\\AppData\\Local\\AMD\\atieclxx\.exe' })
    }
    if ($self) { $variant = 'SelfCopy'; $targets = @($script:TargetFile); $status = $(if ($protected) { 'ProtectionIneffective' } else { 'AffectedSelfCopy' }) }
    else { $variant = 'Other'; $status = 'AffectedOther' }
  }
  elseif ($protected) { $status = 'Protected'; $variant = 'SelfCopy' }
  else { $status = 'NotAffected' }
  Set-Phase 'Estimating SSD wear'
  $damage = Get-DamageEstimate -Status $status -Rate $rate -Ssd $ssd -Finding $finding
  [pscustomobject]@{
    Status = $status; Affected = $affected; Variant = $variant; Targets = $targets
    Rate = $rate; Process = [bool]$proc; Service = $service; Protected = $protected; Task = $task; Finding = $finding
    Ssd = $ssd; Damage = $damage; Time = (Get-Date)
  }
}

# ------------------------------------------------------------------ Automatic Guard (Task Scheduler)
function Remove-OldVersion {
  # Clean up previous version under the former name "AMD-SSD-Fix" (and legacy German files); findings and logs are migrated.
  if (Get-ScheduledTask -TaskName $script:OldName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $script:OldName -Confirm:$false -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $script:OldInstallDir) {
    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
    foreach ($pair in @(@('befund.json', 'finding.json'), @('protokoll.txt', 'log.txt'), @('finding.json', 'finding.json'), @('log.txt', 'log.txt'))) {
      $q = Join-Path $script:OldInstallDir $pair[0]
      $z = Join-Path $script:InstallDir $pair[1]
      if ((Test-Path -LiteralPath $q) -and -not (Test-Path -LiteralPath $z)) { Copy-Item -LiteralPath $q -Destination $z -Force }
    }
    Remove-Item -LiteralPath $script:OldInstallDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $script:InstallDir) {
    foreach ($pair in @(@('befund.json', 'finding.json'), @('protokoll.txt', 'log.txt'))) {
      $q = Join-Path $script:InstallDir $pair[0]
      $z = Join-Path $script:InstallDir $pair[1]
      if (Test-Path -LiteralPath $q) {
        if (-not (Test-Path -LiteralPath $z)) { Copy-Item -LiteralPath $q -Destination $z -Force }
        Remove-Item -LiteralPath $q -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
function Install-Task {
  # Copies the scripts to Program Files\Radeon-atieclxx-SSD-Fix (only admins can modify files there) and sets up the scheduled task.
  param([string]$Source)
  Remove-OldVersion
  $scriptTarget = Join-Path $script:InstallDir 'Script'
  New-Item -ItemType Directory -Force -Path $scriptTarget | Out-Null
  if ($Source -and (Test-Path -LiteralPath $Source)) {
    $sourceFull = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
    if (-not [string]::Equals($sourceFull, $scriptTarget.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
      foreach ($f in 'Core.ps1', 'guard.ps1', 'Gui.ps1', 'check.ps1', 'remove.ps1') {
        $src = Join-Path $sourceFull $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $scriptTarget $f) -Force }
      }
      $pkg = Split-Path -Parent $sourceFull
      foreach ($f in 'START.cmd', 'REMOVE.cmd', 'CHECK.cmd', 'README.txt', 'LICENSE.txt') {
        $src = Join-Path $pkg $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $script:InstallDir $f) -Force }
      }
    }
    foreach ($old in 'Skript', 'Script\installieren.ps1', 'INSTALLIEREN.cmd', 'installation.txt', 'ENTFERNEN.cmd', 'PRUEFEN.cmd', 'LIESMICH.txt', 'zustand.json') {
      $p = Join-Path $script:InstallDir $old
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Remove download Zone.Identifier markers so the scripts also run under stricter execution policies.
    Get-ChildItem -LiteralPath $script:InstallDir -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
  }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $scriptTarget 'guard.ps1') + '"'
  $action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
  $tStart = New-ScheduledTaskTrigger -AtStartup
  $tStart.Delay = 'PT3M'
  $tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30) -RepetitionInterval (New-TimeSpan -Minutes 30)
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
  $sysName = $script:SystemSid.Translate([System.Security.Principal.NTAccount]).Value   # localized name of SYSTEM
  $pr = New-ScheduledTaskPrincipal -UserId $sysName -LogonType ServiceAccount -RunLevel Highest
  $desc = 'Unofficial workaround: prevents atieclxx.exe (AMD External Events Utility) from copying itself every second and wearing out the SSD. Automatically checks after driver updates whether AMD has fixed the bug. To remove: ' + (Join-Path $script:InstallDir 'REMOVE.cmd')
  Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger @($tStart, $tRepeat) -Settings $set -Principal $pr -Description $desc -Force | Out-Null
  try {
    # Read permission for logged-in users so CHECK.cmd can display the task status without admin rights.
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $reg = $svc.GetFolder('\').GetTask($script:TaskName)
    $sd = $reg.GetSecurityDescriptor(4)
    if ($sd -notmatch '\(A;;FR;;;AU\)') { $reg.SetSecurityDescriptor($sd + '(A;;FR;;;AU)', 0) }
  } catch {}
  return [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
}
function Remove-Task {
  Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
  return (-not (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue))
}
function Remove-Everything {
  # Reverts all changes: scheduled task, file protection, service disabling, and saved findings (including from previous versions).
  Remove-OldVersion
  Remove-Task | Out-Null
  Remove-Protection | Out-Null
  $d = Get-AmdService
  if ($d -and [string]$d.StartType -eq 'Disabled') { Enable-Service | Out-Null }
  foreach ($f in $script:FindingFile, $script:StateFile) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
