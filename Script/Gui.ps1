# Radeon-atieclxx-SSD-Fix – GUI window with analysis, SSD wear estimate, and fix buttons.
# Started via START.cmd (with administrator privileges). Measurements run in the background while the window remains responsive.
# Test: $Global:AMDFIX_NOSHOW = $true; $Global:AMDFIX_TEST = $true; . .\Gui.ps1; $f = Build-Form
$script:ScriptDir = $PSScriptRoot
$script:CoreFile = Join-Path $PSScriptRoot 'Core.ps1'
. $script:CoreFile
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Ctrl = @{}
$script:Async = $null
$script:LastAnalysis = $null
$script:Closing = $false
$script:Timer = $null
$script:Mutex = $null
$script:TestMessages = New-Object System.Collections.ArrayList
$script:Sync = [hashtable]::Synchronized(@{ Phase = ''; End = [datetime]::MinValue })
$script:NL = [Environment]::NewLine
$script:Color = @{
  Red    = [System.Drawing.Color]::FromArgb(176, 0, 32)
  Green  = [System.Drawing.Color]::FromArgb(30, 120, 54)
  Orange = [System.Drawing.Color]::FromArgb(176, 96, 0)
  Gray   = [System.Drawing.Color]::FromArgb(90, 90, 90)
  Text   = [System.Drawing.Color]::FromArgb(32, 32, 32)
}

# Runs in a dedicated runspace: execute the requested action, then re-analyze.
$script:BackgroundScript = {
  param($core, $action, $source, $rateBefore, $sync)
  . $core
  $script:Progress = $sync
  $result = @{}
  switch ($action) {
    'Protection' {
      Set-Phase 'Applying targeted protection'
      $ok = Set-Protection
      $taskOk = $false
      if ($ok) {
        Save-ProtectionFinding -Type 'Protection' -RateBefore $rateBefore -AllowAssumption
        Set-Phase 'Setting up automatic guard'
        $taskOk = Install-Task -Source $source
        Write-Log 'Targeted protection applied via GUI.'
      }
      $result = @{ Ok = $ok; Task = $taskOk }
    }
    'Service' {
      Set-Phase 'Disabling service'
      $r = Disable-Service
      if ($r -eq 'OK' -or $r -eq 'StillRunning') {
        Save-ProtectionFinding -Type 'Service' -RateBefore $rateBefore
        Write-Log 'Service disabled via GUI.'
      }
      $result = @{ Result = $r }
    }
    'Revert' {
      Set-Phase 'Reverting all changes'
      Remove-Everything
      Write-Log 'All changes reverted via GUI.'
      $result = @{ Ok = $true }
    }
  }
  $analysis = Get-Analysis -MeasureSeconds 8
  [pscustomobject]@{ Action = $action; Result = $result; Analysis = $analysis }
}

# ------------------------------------------------------------------ Helper Functions
function Show-Message {
  param([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information', [string]$Title = 'Radeon-atieclxx-SSD-Fix')
  if ($Global:AMDFIX_TEST) { [void]$script:TestMessages.Add($Text); if ($Buttons -eq 'YesNo') { return 'Yes' }; return 'OK' }
  $f = $script:Ctrl.Form
  if ($f -and -not $f.IsDisposed -and $f.Visible) { return [string][System.Windows.Forms.MessageBox]::Show($f, $Text, $Title, $Buttons, $Icon) }
  return [string][System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}
function Format-Rate([double]$b) {
  if ($b -lt 0) { return 'not measurable' }
  if ($b -ge 1MB) { return ('{0:N2} MB/s' -f ($b / 1MB)) }
  return ('{0:N0} KB/s' -f ($b / 1KB))
}
function Format-Volume([double]$Bytes) {
  if ($Bytes -ge 1e11) { return ('{0:N1} TB' -f ($Bytes / 1e12)) }
  return ('{0:N0} GB' -f ($Bytes / 1e9))
}
function New-Label($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '') {
  $l = New-Object System.Windows.Forms.Label
  $l.Location = New-Object System.Drawing.Point($X, $Y)
  $l.Size = New-Object System.Drawing.Size($W, $H)
  $l.Text = $Text
  $Parent.Controls.Add($l)
  return $l
}
function New-Button($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text) {
  $k = New-Object System.Windows.Forms.Button
  $k.Location = New-Object System.Drawing.Point($X, $Y)
  $k.Size = New-Object System.Drawing.Size($W, $H)
  $k.Text = $Text
  $Parent.Controls.Add($k)
  return $k
}
function New-Group($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text) {
  $g = New-Object System.Windows.Forms.GroupBox
  $g.Location = New-Object System.Drawing.Point($X, $Y)
  $g.Size = New-Object System.Drawing.Size($W, $H)
  $g.Text = $Text
  $Parent.Controls.Add($g)
  return $g
}

# ------------------------------------------------------------------ Window
function Build-Form {
  $f = New-Object System.Windows.Forms.Form
  $f.SuspendLayout()
  $f.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
  $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
  $f.Text = 'Radeon-atieclxx-SSD-Fix ' + $script:Version
  $f.ClientSize = New-Object System.Drawing.Size(660, 620)
  $f.StartPosition = 'CenterScreen'
  $f.FormBorderStyle = 'FixedSingle'
  $f.MaximizeBox = $false
  $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
  $f.BackColor = [System.Drawing.Color]::White
  try { $f.Icon = [System.Drawing.SystemIcons]::Shield } catch {}
  $bold = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

  $header = New-Label $f 18 14 624 32 'Analyzing ...'
  $header.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
  $header.ForeColor = $script:Color.Gray
  $sub = New-Label $f 20 48 624 20 'Please wait a moment'
  $sub.ForeColor = $script:Color.Gray

  $g1 = New-Group $f 18 74 624 134 'What is the issue?'
  $finding = New-Label $g1 14 22 596 104
  $g2 = New-Group $f 18 214 624 160 'Estimated SSD wear so far'
  $damage = New-Label $g2 14 22 596 130
  $g3 = New-Group $f 18 380 624 168 'Select a fix'
  $btnProtect = New-Button $g3 16 26 250 40 'Targeted protection (recommended)'
  $l1 = New-Label $g3 276 26 334 42 'Stops only the self-copy. Service, FreeSync, and frame pacing continue running normally.'
  $btnService = New-Button $g3 16 74 250 38 'Disable service'
  $l2 = New-Label $g3 276 74 334 40 'Workaround from the article: works reliably, but may affect FreeSync and frame pacing.'
  $btnRevert = New-Button $g3 16 120 250 36 'Undo all changes'
  $l3 = New-Label $g3 276 120 334 40 'Reverts protection, automatic task, and service disabling.'
  foreach ($l in $l1, $l2, $l3) { $l.ForeColor = $script:Color.Gray }

  $btnCheck = New-Button $f 18 558 140 30 'Check again'
  $btnReBar = New-Button $f 166 558 180 30 'What is Resizable BAR?'
  $btnLog = New-Button $f 354 558 130 30 'Log'
  $btnHelp = New-Button $f 492 558 150 30 'Guide'
  $footer = New-Label $f 20 594 624 22
  $footer.ForeColor = $script:Color.Gray

  $script:Ctrl = @{ Form = $f; Header = $header; Sub = $sub; Finding = $finding; Damage = $damage; Bold = $bold; Normal = $f.Font
    BtnProtect = $btnProtect; BtnService = $btnService; BtnRevert = $btnRevert; BtnCheck = $btnCheck
    BtnReBar = $btnReBar; BtnLog = $btnLog; BtnHelp = $btnHelp; Footer = $footer }
  foreach ($k in 'BtnProtect', 'BtnService', 'BtnRevert', 'BtnCheck') { $script:Ctrl[$k].Enabled = $false }
  $btnLog.Enabled = Test-Path -LiteralPath $script:LogFile

  $btnCheck.Add_Click({ Click-Check })
  $btnProtect.Add_Click({ Click-Protect })
  $btnService.Add_Click({ Click-Service })
  $btnRevert.Add_Click({ Click-Revert })
  $btnReBar.Add_Click({ Click-ReBar })
  $btnLog.Add_Click({ Click-Log })
  $btnHelp.Add_Click({ Click-Help })
  $f.Add_FormClosing({ On-FormClosing $_ })

  $script:Timer = New-Object System.Windows.Forms.Timer
  $script:Timer.Interval = 200
  $script:Timer.Add_Tick({ Tick-Background })

  $f.ResumeLayout($false)
  return $f
}

function Update-Buttons($a) {
  $c = $script:Ctrl
  $disabled = [bool]($a.Service -and [string]$a.Service.StartType -eq 'Disabled')
  $c.BtnProtect.Enabled = ($a.Status -eq 'AffectedSelfCopy') -or ($a.Status -eq 'Protected' -and -not $a.Task)
  $c.BtnService.Enabled = [bool]$a.Service -and -not $disabled
  $c.BtnRevert.Enabled = [bool]($a.Protected -or $a.Task -or $disabled -or $a.Finding)
  $c.BtnCheck.Enabled = $true
  $c.BtnLog.Enabled = Test-Path -LiteralPath $script:LogFile
  $c.BtnProtect.Font = $(if ($c.BtnProtect.Enabled) { $c.Bold } else { $c.Normal })
  $c.BtnService.Font = $(if ($a.Status -in 'AffectedOther', 'ProtectionIneffective') { $c.Bold } else { $c.Normal })
}
function Set-Interactive([bool]$Enabled) {
  $c = $script:Ctrl
  if ($Enabled) {
    if ($script:LastAnalysis) { Update-Buttons $script:LastAnalysis } else { $c.BtnCheck.Enabled = $true }
  } else {
    foreach ($k in 'BtnProtect', 'BtnService', 'BtnRevert', 'BtnCheck') { $c[$k].Enabled = $false }
  }
}

function Refresh-View {
  param($a)
  $c = $script:Ctrl
  if (-not $c.Form -or $c.Form.IsDisposed) { return }
  $headerInfo = @{
    NoService             = @('Not affected: no AMD External Events Utility', 'Green')
    ServiceDisabled       = @('Stopped: The service is disabled', 'Green')
    ServiceStopped        = @('The service is currently not running', 'Gray')
    MeasurementFailed     = @('Measurement could not be completed', 'Orange')
    Protected             = @('Protected: Targeted protection is active', 'Green')
    NotAffected           = @('This PC is not affected', 'Green')
    AffectedSelfCopy      = @('Affected: Continuous writes to the SSD', 'Red')
    AffectedOther         = @('Affected: Continuous writes to another location', 'Red')
    ProtectionIneffective = @('Warning: Protection is not effective here', 'Red')
  }[[string]$a.Status]
  if (-not $headerInfo) { $headerInfo = @([string]$a.Status, 'Gray') }
  $c.Header.Text = $headerInfo[0]
  $c.Header.ForeColor = $script:Color[$headerInfo[1]]
  $c.Sub.Text = 'Measured at ' + $a.Time.ToString('HH:mm:ss') + '  –  ' + $(if ($a.Rate -lt 0) { 'atieclxx.exe is not running' } else { 'atieclxx.exe writes ' + (Format-Rate $a.Rate) })

  $z = New-Object System.Collections.ArrayList
  switch ([string]$a.Status) {
    'AffectedSelfCopy' {
      [void]$z.Add('atieclxx.exe is continuously copying itself (roughly once per second) to:')
      [void]$z.Add('    ' + $script:TargetFile)
      [void]$z.Add('This is the known bug. Targeted protection blocks this exact copy.')
    }
    'AffectedOther' {
      [void]$z.Add('atieclxx.exe is writing continuously, but not to the known location. Detected:')
      if (@($a.Targets).Count) { foreach ($p in @($a.Targets)) { [void]$z.Add('    ' + $p) } } else { [void]$z.Add('    (target could not be determined unambiguously)') }
      [void]$z.Add('Targeted protection does not apply here. Recommended: Disable service.')
    }
    'ProtectionIneffective' {
      [void]$z.Add('Targeted protection is set, yet the copy continues to be written:')
      [void]$z.Add('    ' + $script:TargetFile)
      [void]$z.Add('Recommended: Disable service.')
    }
    'Protected' {
      [void]$z.Add('The SYSTEM account is no longer allowed to overwrite the copy:')
      [void]$z.Add('    ' + $script:TargetFile)
      [void]$z.Add('The self-copy fails immediately while the service continues running normally.')
      [void]$z.Add('Auto-guard across driver updates: ' + $(if ($a.Task) { 'configured' } else { 'missing - click "Targeted protection" to set up' }))
    }
    'ServiceDisabled' {
      [void]$z.Add('The "AMD External Events Utility" service is disabled. atieclxx.exe is not running and writes nothing.')
      [void]$z.Add('Drawback: FreeSync and frame pacing may be affected. Revert with "Undo all changes".')
    }
    'NotAffected' { [void]$z.Add('atieclxx.exe is running, but is not writing continuously. No action is needed.') }
    'ServiceStopped' { [void]$z.Add('The service is installed, but is not currently running. Please check again later.') }
    'NoService' { [void]$z.Add('There is no "AMD External Events Utility" on this PC. It is not affected by this bug.') }
    'MeasurementFailed' { [void]$z.Add('atieclxx.exe exited or restarted during measurement. Please check again.') }
  }
  $c.Finding.Text = ($z -join $script:NL)
  $c.Finding.ForeColor = $(if ($a.Affected) { $script:Color.Red } else { $script:Color.Text })

  $s = $a.Damage
  $ssdName = $(if ($a.Ssd -and $a.Ssd.Model) { [string]$a.Ssd.Model } else { 'System drive' })
  $d = New-Object System.Collections.ArrayList
  if (-not $s) {
    [void]$d.Add('No continuous writes detected - no measurable wear from this bug.')
    if ($a.Ssd -and $a.Ssd.Wear) { [void]$d.Add(('Total SSD wear reported by drive: {0} %.' -f $a.Ssd.Wear)) }
  } else {
    $until = $(if ($s.Active) { 'today' } else { $s.End.ToString('yyyy-MM-dd') })
    $how = $(if ($s.HoursSource -eq 'SSD') { 'reported by SSD' } else { 'assumed' })
    [void]$d.Add(('Timeframe: {0} to {1} ({2} days), {3:N1} operating hours per day {4}.' -f $s.Since.ToString('yyyy-MM-dd'), $until, $s.Days, $s.HoursPerDay, $how))
    [void]$d.Add(('Unnecessarily written: approx. {0} on {1}.' -f (Format-Volume $s.Bytes), $ssdName))
    if ($s.PercentTbw) { [void]$d.Add(('Roughly {0:N2} % of the typical write warranty for this SSD (approx. {1:N0} TB).' -f $s.PercentTbw, $s.TbwTB)) }
    if ($s.Wear) { [void]$d.Add(('Total SSD wear reported by drive: {0} %.' -f $s.Wear)) }
    if ($s.Active) { [void]$d.Add(('As long as the bug remains active, approx. {0:N0} GB per day is added.' -f $s.GbPerDay)) }
    else { [void]$d.Add('Since applying the fix, no additional writes are occurring.') }
    if ($s.Basis -eq 'Assumption') { [void]$d.Add('Write rate prior to protection unknown; assumed: one copy per second.') }
    [void]$d.Add('Estimated from write rate and operating hours since AMD graphics installation.')
  }
  $c.Damage.Text = ($d -join $script:NL)

  $c.Footer.Text = 'Service: ' + (Get-ServiceText $a.Service) + '   |   Protection: ' + $(if ($a.Protected) { 'active' } else { 'off' }) + '   |   Auto-guard: ' + $(if ($a.Task) { 'on' } else { 'off' }) + '   |   ' + $ssdName
  Update-Buttons $a
}

# ------------------------------------------------------------------ Background Work
function Start-Background([string]$Action) {
  if ($script:Async) { return }
  $c = $script:Ctrl
  Set-Interactive $false
  $title = @{ Analysis = 'Analyzing ...'; Protection = 'Applying targeted protection ...'; Service = 'Disabling service ...'; Revert = 'Reverting all changes ...' }[$Action]
  $c.Header.Text = $title
  $c.Header.ForeColor = $script:Color.Gray
  $c.Sub.Text = 'Please wait a moment'
  $script:Sync.Phase = ''
  $script:Sync.End = [datetime]::MinValue
  $rateBefore = $(if ($script:LastAnalysis) { [double]$script:LastAnalysis.Rate } else { -1.0 })
  $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
  $rs = [runspacefactory]::CreateRunspace($iss)
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript($script:BackgroundScript.ToString()).AddArgument($script:CoreFile).AddArgument($Action).AddArgument($script:ScriptDir).AddArgument($rateBefore).AddArgument($script:Sync)
  $script:Async = @{ PS = $ps; RS = $rs; Action = $Action; Handle = $ps.BeginInvoke() }
  $script:Timer.Start()
}
function Tick-Background {
  try {
    $a = $script:Async
    if (-not $a) { $script:Timer.Stop(); return }
    if (-not $a.Handle.IsCompleted) {
      try {
        $ph = [string]$script:Sync.Phase
        if ($ph) {
          $end = [datetime]$script:Sync.End
          $text = $ph + ' ...'
          if ($end -gt [datetime]::MinValue) {
            $sec = ($end - (Get-Date)).TotalSeconds
            if ($sec -gt 0 -and $sec -lt 3600) { $text = $ph + ' - ' + [math]::Ceiling($sec) + ' s remaining' }
          }
          $script:Ctrl.Sub.Text = $text
        }
      } catch {}   # a faulty progress update must never abort the running background job
      return
    }
    $script:Timer.Stop()
    $res = @(); $err = ''
    try { $res = @($a.PS.EndInvoke($a.Handle)) } catch { $err = $_.Exception.Message }
    if (-not $err -and $a.PS.Streams.Error.Count) { $err = [string]$a.PS.Streams.Error[0] }
    try { $a.PS.Dispose(); $a.RS.Close(); $a.RS.Dispose() } catch {}
    $script:Async = $null
    if ($script:Closing -or $script:Ctrl.Form.IsDisposed) { return }
    $pkg = $res | Where-Object { $_ -and $_.PSObject.Properties['Analysis'] } | Select-Object -Last 1
    if (-not $pkg -or -not $pkg.Analysis) {
      $script:Ctrl.Header.Text = 'Analysis failed'
      $script:Ctrl.Header.ForeColor = $script:Color.Orange
      $script:Ctrl.Sub.Text = 'Please try "Check again"'
      Set-Interactive $true
      Show-Message ('The analysis failed.' + $script:NL + $err) 'OK' 'Warning' | Out-Null
      return
    }
    $script:LastAnalysis = $pkg.Analysis
    Refresh-View $pkg.Analysis
    Report-Action $pkg
  } catch {
    # If the background job is still running, keep waiting rather than losing track of it
    # (otherwise two actions could overlap).
    $a = $script:Async
    if ($a -and -not $a.Handle.IsCompleted) { return }
    try { $script:Timer.Stop() } catch {}
    if ($a) { try { $a.PS.Dispose(); $a.RS.Close(); $a.RS.Dispose() } catch {} }
    $script:Async = $null
    Set-Interactive $true
    Show-Message ('Unexpected error: ' + $_.Exception.Message) 'OK' 'Error' | Out-Null
  }
}
function Stop-Background {
  try { if ($script:Timer) { $script:Timer.Stop() } } catch {}
  $a = $script:Async
  $script:Async = $null
  if ($a) {
    try { $a.PS.Stop() } catch {}
    try { $a.PS.Dispose(); $a.RS.Close(); $a.RS.Dispose() } catch {}
  }
  & logman stop $script:TraceName -ets *> $null   # in case an ETW trace was running
}
function Report-Action($p) {
  $e = $p.Result
  switch ([string]$p.Action) {
    'Protection' {
      if ($e.Ok) {
        $auto = $(if ($e.Task) { 'The automatic guard is configured: it checks at startup and every 30 minutes, re-applies protection after driver updates, and lifts it automatically once AMD has fixed the bug.' }
                  else { 'The automatic guard task could not be created. Protection is still active until a driver update replaces the file.' })
        Show-Message ('Targeted protection applied. The self-copy is stopped while the service continues running.' + $script:NL + $script:NL + $auto) 'OK' 'Information' | Out-Null
      } else {
        Show-Message 'Protection could not be applied: the copy was not found or permissions were insufficient.' 'OK' 'Warning' | Out-Null
      }
    }
    'Service' {
      $t = switch ([string]$e.Result) {
        'OK'           { 'The service is disabled; atieclxx.exe is no longer running.' }
        'StillRunning' { 'The service is disabled, but atieclxx.exe is still running. It will stay off after a reboot.' }
        'NoService'    { 'The service was not found.' }
        default        { 'The service could not be disabled.' }
      }
      Show-Message $t 'OK' $(if ([string]$e.Result -eq 'OK') { 'Information' } else { 'Warning' }) | Out-Null
    }
    'Revert' { Show-Message ('All changes have been reverted.' + $script:NL + 'The program folder is kept. To remove completely: run REMOVE.cmd.') 'OK' 'Information' | Out-Null }
  }
}

# ------------------------------------------------------------------ Button Handlers
function Show-Error($Err) { Set-Interactive $true; Show-Message ('Unexpected error: ' + $Err.Exception.Message) 'OK' 'Error' | Out-Null }
function Click-Check { try { Start-Background 'Analysis' } catch { Show-Error $_ } }
function Click-Protect { try { Start-Background 'Protection' } catch { Show-Error $_ } }
function Click-Service {
  try {
    $r = Show-Message ('Disable the "AMD External Events Utility" service?' + $script:NL + $script:NL +
      'This stops the writes reliably, but may affect FreeSync and frame pacing. You can revert this at any time with "Undo all changes".') 'YesNo' 'Warning'
    if ($r -eq 'Yes') { Start-Background 'Service' }
  } catch { Show-Error $_ }
}
function Click-Revert {
  try {
    $r = Show-Message 'Revert all changes (protection, automatic guard, service disabling)?' 'YesNo' 'Question'
    if ($r -eq 'Yes') { Start-Background 'Revert' }
  } catch { Show-Error $_ }
}
function Click-ReBar {
  Show-Message ('Resizable BAR (called "Smart Access Memory" by AMD) allows the processor to access the entire graphics memory at once, providing extra performance in many games.' + $script:NL + $script:NL +
    'The article suggests disabling Resizable BAR in the BIOS because the bug is triggered in the Smart Access Memory part of the driver. That can help, but it costs performance depending on the game and can only be changed in the BIOS, not from here.' + $script:NL + $script:NL +
    'Targeted protection solves the problem without touching Resizable BAR.') 'OK' 'Information' 'What is Resizable BAR?' | Out-Null
}
function Click-Log {
  if (Test-Path -LiteralPath $script:LogFile) { Start-Process notepad.exe -ArgumentList ('"' + $script:LogFile + '"') }
  else { Show-Message 'No log file exists yet.' | Out-Null }
}
function Click-Help {
  $file = Join-Path (Split-Path -Parent $script:ScriptDir) 'README.txt'
  if (-not (Test-Path -LiteralPath $file)) { $file = Join-Path $script:InstallDir 'README.txt' }
  if (Test-Path -LiteralPath $file) { Start-Process notepad.exe -ArgumentList ('"' + $file + '"') }
  else { Show-Message 'The guide (README.txt) was not found.' | Out-Null }
}
function On-FormClosing($e) {
  if ($script:Async -and $script:Async.Action -ne 'Analysis') {
    Show-Message 'Please wait until the current action has finished.' | Out-Null
    $e.Cancel = $true
    return
  }
  $script:Closing = $true
  Stop-Background
}

# ------------------------------------------------------------------ Startup
if (-not $Global:AMDFIX_NOSHOW) {
  try {
    if (-not (Test-IsAdmin)) {
      # Relaunch with administrator privileges (same PowerShell executable).
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = (Get-Process -Id $PID).Path
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $PSCommandPath + '"'
      $psi.Verb = 'runas'
      $psi.UseShellExecute = $true
      try { [void][System.Diagnostics.Process]::Start($psi) } catch {}   # Windows UAC prompt declined
      return
    }
    $createdNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\Radeon-atieclxx-SSD-Fix-Gui', [ref]$createdNew)
    if (-not $createdNew) {
      [void][System.Windows.Forms.MessageBox]::Show('Radeon-atieclxx-SSD-Fix is already open.', 'Radeon-atieclxx-SSD-Fix', 'OK', 'Information')
      $script:Mutex.Dispose()
      $script:Mutex = $null
      return
    }
    & logman stop $script:TraceName -ets *> $null    # clean up any leftover ETW trace session
    $form = Build-Form
    $form.Add_Shown({ $this.Activate(); Start-Background 'Analysis' })
    [void]$form.ShowDialog()
  } catch {
    $text = 'Radeon-atieclxx-SSD-Fix could not be executed:' + $script:NL + $_.Exception.Message
    try { Add-Content -LiteralPath (Join-Path $env:TEMP 'Radeon-atieclxx-SSD-Fix-Error.txt') -Value ((Get-Date -Format s) + '  ' + $_.Exception.ToString()) -Encoding UTF8 } catch {}
    try { [void][System.Windows.Forms.MessageBox]::Show($text, 'Radeon-atieclxx-SSD-Fix', 'OK', 'Error') } catch {}
  } finally {
    if (Test-IsAdmin) { Stop-Background }
    if ($script:Timer) { try { $script:Timer.Dispose() } catch {} }
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {}; try { $script:Mutex.Dispose() } catch {} }
  }
}
