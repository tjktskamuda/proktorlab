# ProktorLab Autopilot 1.2.0
# ---------------------------------------------------------------
# Dijalankan oleh agen ProktorLab di sesi Windows pengguna yang login.
# Membuka Exam Browser, lalu mengklik otomatis tombol di jendela
# pembukanya (misalnya OK, RUN, Yes) sesuai aturan dari panel proktor.
#
# Format aturan (satu per baris):   Judul jendela > Tombol1/Tombol2
#   *  = judul apa saja (hanya jendela milik Exam Browser)
#   Setiap tombol diklik sekali per jendela.
# Log: %TEMP%\ProktorLab-autopilot.log
# ---------------------------------------------------------------
param(
  [string]$ExeB64 = '',
  [string]$ArgsB64 = '',
  [string]$RulesB64 = '',
  [string]$NamesB64 = '',
  [int]$Timeout = 150
)
$ErrorActionPreference = 'SilentlyContinue'

function From-B64([string]$s) {
  if (-not $s) { return '' }
  try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) } catch { return '' }
}

$Exe = From-B64 $ExeB64
$ExeArgs = From-B64 $ArgsB64
$RulesText = From-B64 $RulesB64
$Names = @((From-B64 $NamesB64) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$LogFile = Join-Path $env:TEMP 'ProktorLab-autopilot.log'

function Write-AutoLog([string]$m) {
  try { Add-Content -Path $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) } catch {}
}

function Read-Rules([string]$text) {
  $list = @()
  foreach ($line in ($text -split "\r?\n")) {
    $l = $line.Trim()
    if (-not $l -or $l.StartsWith('#')) { continue }
    $ix = $l.LastIndexOf('>')
    if ($ix -lt 0) { continue }
    $title = $l.Substring(0, $ix).Trim()
    if (-not $title) { $title = '*' }
    $btns = @($l.Substring($ix + 1).Split('/') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($btns.Count -gt 0) { $list += , @{ title = $title; btns = $btns; fired = $false } }
  }
  return , $list
}

function Test-ButtonMatch([string]$name, $patterns) {
  $n = $name.Replace('&', '').Trim()
  foreach ($p in $patterns) { if ($n -like $p) { return $true } }
  return $false
}

# proses Exam Browser: proses yang dibuka + semua turunannya + nama proses dari panel
function Get-ExamTree([int]$rootId) {
  $set = @{}
  if ($rootId -gt 0) { $set[$rootId] = $true }
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction SilentlyContinue)
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($p in $all) {
      $id = [int]$p.ProcessId
      if (-not $set.ContainsKey($id) -and $set.ContainsKey([int]$p.ParentProcessId)) { $set[$id] = $true; $changed = $true }
    }
  }
  foreach ($p in $all) {
    $n = ([string]$p.Name) -replace '\.exe$', ''
    foreach ($pat in $Names) { if ($n -like $pat) { $set[[int]$p.ProcessId] = $true } }
  }
  return $set
}

# ---------------- mulai ----------------
if ($MyInvocation.InvocationName -eq '.') { return }   # dimuat untuk pengujian
try { Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue } catch {}
Write-AutoLog ('Autopilot mulai. Exe: ' + $Exe)
$Rules = Read-Rules $RulesText
Write-AutoLog ('Aturan: ' + (($Rules | ForEach-Object { $_.title + ' > ' + ($_.btns -join '/') }) -join ' ; '))

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
$MouseOk = $true
try {
  Add-Type -Namespace ProktorLab -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, int e);'
} catch { $MouseOk = $false }

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$BtnCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)

function Invoke-Click($win, $el) {
  # InvokePattern dijalankan di thread lain: tombol yang membuka dialog modal
  # (misalnya RUN) membuat Invoke() menunggu sampai dialog ditutup.
  try {
    $pat = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($pat) {
      $ps = [powershell]::Create()
      [void]$ps.AddScript({ param($p) $p.Invoke() }).AddArgument($pat)
      [void]$ps.BeginInvoke()
      return 'invoke'
    }
  } catch {}
  try {
    $r = $el.Current.BoundingRectangle
    if ($MouseOk -and -not $r.IsEmpty) {
      [void][ProktorLab.Native]::SetForegroundWindow([IntPtr]$win.Current.NativeWindowHandle)
      Start-Sleep -Milliseconds 150
      [void][ProktorLab.Native]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
      [ProktorLab.Native]::mouse_event(2, 0, 0, 0, 0)
      Start-Sleep -Milliseconds 60
      [ProktorLab.Native]::mouse_event(4, 0, 0, 0, 0)
      return 'mouse'
    }
  } catch {}
  try { $el.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait(' '); return 'keyboard' } catch {}
  return ''
}

$RootId = 0
if ($Exe) {
  try {
    $sp = @{ FilePath = $Exe; PassThru = $true; WorkingDirectory = (Split-Path -Parent $Exe) }
    if ($ExeArgs) { $sp.ArgumentList = $ExeArgs }
    $proc = Start-Process @sp -ErrorAction Stop
    $RootId = $proc.Id
    Write-AutoLog ('Exam Browser dibuka, PID ' + $RootId)
  } catch {
    Write-AutoLog ('Gagal membuka Exam Browser: ' + $_.Exception.Message)
    exit 1
  }
}
if ($Rules.Count -eq 0) { Write-AutoLog 'Tidak ada aturan klik.'; exit 0 }

$Fired = @{}
$Tree = @{}
$TreeAt = [datetime]::MinValue
$LastClick = Get-Date
$Deadline = (Get-Date).AddSeconds($Timeout)
while ((Get-Date) -lt $Deadline) {
  if (((Get-Date) - $TreeAt).TotalMilliseconds -gt 1500) { $Tree = Get-ExamTree $RootId; $TreeAt = Get-Date }
  $wins = $AE::RootElement.FindAll($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($w in $wins) {
    try { $wPid = [int]$w.Current.ProcessId; $title = [string]$w.Current.Name; $hwnd = [int64]$w.Current.NativeWindowHandle } catch { continue }
    $inTree = $Tree.ContainsKey($wPid)
    for ($i = 0; $i -lt $Rules.Count; $i++) {
      $r = $Rules[$i]
      if ($r.title -eq '*') { if (-not $inTree) { continue } }
      elseif (-not ($title -like $r.title)) { continue }
      $key = [string]$i + '|' + [string]$hwnd
      if ($Fired.ContainsKey($key)) { continue }
      $btns = $null
      try { $btns = $w.FindAll($Scope::Descendants, $BtnCond) } catch { continue }
      foreach ($b in $btns) {
        $name = ''
        try { $name = [string]$b.Current.Name } catch { continue }
        if (-not (Test-ButtonMatch $name $r.btns)) { continue }
        $enabled = $true
        try { $enabled = $b.Current.IsEnabled } catch {}
        if (-not $enabled) { break }          # tunggu sampai tombol aktif
        $how = Invoke-Click $w $b
        if ($how) {
          $Fired[$key] = $true
          $r.fired = $true
          $LastClick = Get-Date
          Write-AutoLog ('Klik "' + $name.Replace('&', '') + '" di jendela "' + $title + '" (' + $how + ')')
          Start-Sleep -Milliseconds 500
        }
        break
      }
    }
  }
  # selesai jika semua aturan berjudul khusus sudah diklik dan 8 detik tidak ada klik baru
  $specific = @($Rules | Where-Object { $_.title -ne '*' })
  if ($specific.Count -gt 0 -and @($specific | Where-Object { -not $_.fired }).Count -eq 0 -and ((Get-Date) - $LastClick).TotalSeconds -gt 8) { break }
  Start-Sleep -Milliseconds 400
}
Write-AutoLog 'Autopilot selesai.'
