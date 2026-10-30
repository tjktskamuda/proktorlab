# ProktorLab Autopilot 1.3.0
# ---------------------------------------------------------------
# Dijalankan oleh agen ProktorLab di sesi Windows pengguna yang login.
#
#   -Mode open  : membuka Exam Browser lalu mengklik otomatis tombol di
#                 jendela pembukanya (OK, RUN, Yes, ...) sesuai aturan.
#   -Mode close : menutup Exam Browser dengan shortcut keluar resminya
#                 (misalnya Ctrl+C+B+L), lalu mengklik konfirmasi Yes/OK.
#
# Format aturan klik (satu per baris):   Judul jendela > Tombol1/Tombol2
#   *  = judul apa saja (hanya jendela milik Exam Browser)
#   Setiap tombol diklik sekali per jendela.
# Format shortcut (satu per baris): Ctrl+C+B+L   (dicoba berurutan)
# Log: %TEMP%\ProktorLab-autopilot.log
# ---------------------------------------------------------------
param(
  [string]$Mode = 'open',
  [string]$ExeB64 = '',
  [string]$ArgsB64 = '',
  [string]$RulesB64 = '',
  [string]$NamesB64 = '',
  [string]$KeysB64 = '',
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
$KeysText = From-B64 $KeysB64
$Names = @((From-B64 $NamesB64) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$LogFile = Join-Path $env:TEMP 'ProktorLab-autopilot.log'

function Write-AutoLog([string]$m) {
  try { Add-Content -Path $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  [' + $Mode + '] ' + $m) } catch {}
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

# kode tombol virtual Windows untuk satu nama tombol (Ctrl, C, F4, Esc, ...)
function Get-VirtualKey([string]$t) {
  $k = $t.Trim().ToLower()
  switch -regex ($k) {
    '^(ctrl|control|ctl)$' { return 0x11 }
    '^shift$' { return 0x10 }
    '^(alt|menu)$' { return 0x12 }
    '^(win|windows|super)$' { return 0x5B }
    '^(enter|return)$' { return 0x0D }
    '^(esc|escape)$' { return 0x1B }
    '^tab$' { return 0x09 }
    '^(space|spasi)$' { return 0x20 }
    '^(del|delete)$' { return 0x2E }
    '^(backspace|bksp)$' { return 0x08 }
    '^f([1-9]|1[0-2])$' { return 0x6F + [int]$Matches[1] }
    '^[a-z0-9]$' { return [int][char]$k.ToUpper() }
  }
  return 0
}

function Read-Combos([string]$text) {
  $list = @()
  foreach ($line in ($text -split "\r?\n")) {
    $l = $line.Trim()
    if (-not $l -or $l.StartsWith('#')) { continue }
    $vks = @()
    $ok = $true
    foreach ($part in ($l -split '\+')) {
      $vk = Get-VirtualKey $part
      if ($vk -eq 0) { $ok = $false; break }
      $vks += $vk
    }
    if ($ok -and $vks.Count) { $list += , @{ text = $l; vks = $vks } }
  }
  return , $list
}

# proses Exam Browser: proses yang dibuka + nama proses dari panel + semua turunannya
function Get-ExamTree([int]$rootId) {
  $set = @{}
  if ($rootId -gt 0) { $set[$rootId] = $true }
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction SilentlyContinue)
  foreach ($p in $all) {
    $n = ([string]$p.Name) -replace '\.exe$', ''
    foreach ($pat in $Names) { if ($n -like $pat) { $set[[int]$p.ProcessId] = $true } }
  }
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($p in $all) {
      $id = [int]$p.ProcessId
      if (-not $set.ContainsKey($id) -and $set.ContainsKey([int]$p.ParentProcessId)) { $set[$id] = $true; $changed = $true }
    }
  }
  if ($rootId -gt 0 -and -not ($all | Where-Object { [int]$_.ProcessId -eq $rootId })) { $set.Remove($rootId) }
  return $set
}

# ---------------- mulai ----------------
if ($MyInvocation.InvocationName -eq '.') { return }   # dimuat untuk pengujian
if ($Mode -eq 'open') { try { Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue } catch {} }
$Rules = Read-Rules $RulesText
Write-AutoLog ('Mulai. Exe: ' + $Exe + ' | Proses: ' + ($Names -join ',') + ' | Aturan: ' + (($Rules | ForEach-Object { $_.title + ' > ' + ($_.btns -join '/') }) -join ' ; '))

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
$NativeOk = $true
try {
  Add-Type -Namespace ProktorLab -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, int e); [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, int flags, int extra); [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);'
} catch { $NativeOk = $false }

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$BtnCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$Fired = @{}
$LastClick = Get-Date

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
    if ($NativeOk -and -not $r.IsEmpty) {
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

# satu putaran: cek semua jendela, klik tombol yang cocok dengan aturan
function Invoke-RulesPass($tree) {
  $wins = $AE::RootElement.FindAll($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($w in $wins) {
    try { $wPid = [int]$w.Current.ProcessId; $title = [string]$w.Current.Name; $hwnd = [int64]$w.Current.NativeWindowHandle } catch { continue }
    $inTree = $tree.ContainsKey($wPid)
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
          $script:Fired[$key] = $true
          $r.fired = $true
          $script:LastClick = Get-Date
          Write-AutoLog ('Klik "' + $name.Replace('&', '') + '" di jendela "' + $title + '" (' + $how + ')')
          Start-Sleep -Milliseconds 500
        }
        break
      }
    }
  }
}

function Set-ExamFocus($tree) {
  if (-not $NativeOk) { return }
  foreach ($id in @($tree.Keys)) {
    try {
      $p = Get-Process -Id $id -ErrorAction Stop
      if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void][ProktorLab.Native]::SetForegroundWindow($p.MainWindowHandle); return }
    } catch {}
  }
}

function Send-Combo($combo) {
  if (-not $NativeOk) { [System.Windows.Forms.SendKeys]::SendWait('^c'); return }
  foreach ($vk in $combo.vks) {
    $flags = 0
    if ($vk -eq 0x5B -or $vk -eq 0x2E) { $flags = 1 }
    [ProktorLab.Native]::keybd_event([byte]$vk, [byte][ProktorLab.Native]::MapVirtualKey([uint32]$vk, 0), $flags, 0)
    Start-Sleep -Milliseconds 90
  }
  Start-Sleep -Milliseconds 350
  for ($k = $combo.vks.Count - 1; $k -ge 0; $k--) {
    $vk = $combo.vks[$k]
    $flags = 2
    if ($vk -eq 0x5B -or $vk -eq 0x2E) { $flags = 3 }
    [ProktorLab.Native]::keybd_event([byte]$vk, [byte][ProktorLab.Native]::MapVirtualKey([uint32]$vk, 0), $flags, 0)
    Start-Sleep -Milliseconds 40
  }
}

# ================= MODE CLOSE =================
if ($Mode -eq 'close') {
  $combos = Read-Combos $KeysText
  if ($combos.Count -eq 0) { Write-AutoLog 'Tidak ada shortcut keluar yang valid.'; exit 0 }
  $done = $false
  foreach ($c in $combos) {
    $tree = Get-ExamTree 0
    if ($tree.Count -eq 0) { $done = $true; break }
    Set-ExamFocus $tree
    Start-Sleep -Milliseconds 300
    Send-Combo $c
    Write-AutoLog ('Tekan ' + $c.text)
    $until = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $until) {
      Start-Sleep -Milliseconds 500
      $tree = Get-ExamTree 0
      if ($tree.Count -eq 0) { $done = $true; break }
      Invoke-RulesPass $tree
    }
    if ($done) { break }
  }
  if ($done) { Write-AutoLog 'Exam Browser tertutup.' } else { Write-AutoLog 'Exam Browser masih terbuka setelah semua shortcut dicoba.' }
  exit 0
}

# ================= MODE OPEN =================
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

$Tree = @{}
$TreeAt = [datetime]::MinValue
$Deadline = (Get-Date).AddSeconds($Timeout)
while ((Get-Date) -lt $Deadline) {
  if (((Get-Date) - $TreeAt).TotalMilliseconds -gt 1500) { $Tree = Get-ExamTree $RootId; $TreeAt = Get-Date }
  Invoke-RulesPass $Tree
  # selesai jika semua aturan berjudul khusus sudah diklik dan 8 detik tidak ada klik baru
  $specific = @($Rules | Where-Object { $_.title -ne '*' })
  if ($specific.Count -gt 0 -and @($specific | Where-Object { -not $_.fired }).Count -eq 0 -and ((Get-Date) - $LastClick).TotalSeconds -gt 8) { break }
  Start-Sleep -Milliseconds 400
}
Write-AutoLog 'Selesai.'
