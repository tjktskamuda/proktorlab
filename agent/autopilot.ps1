# ProktorLab Autopilot 1.7.0
# ---------------------------------------------------------------
# Dijalankan oleh agen ProktorLab di sesi Windows pengguna yang login.
#
#   -Mode open  : (opsional) membuka Exam Browser, lalu mengklik otomatis
#                 tombol di jendela pembukanya (OK, RUN, Yes, ...).
#   -Mode close : menutup Exam Browser dengan shortcut keluar resminya
#                 (misalnya Ctrl+C+B+L), lalu mengklik konfirmasi Yes/OK.
#   -Mode fullscreen : menjadikan browser yang terbuka layar penuh (F11)
#                 atau mengembalikannya (want = on / off).
#   -Mode kiosk : membuka situs di Edge/Chrome mode kiosk (layar penuh tanpa
#                 bisa keluar) lalu menjaganya: dibuka lagi bila ditutup dan
#                 dikembalikan ke depan bila siswa pindah ke jendela lain.
#
# Pengaturan dibaca dari file -Job (JSON) yang dibuat agen.
# Format aturan klik (satu per baris):   Judul jendela > Tombol1/Tombol2
#   *  = judul apa saja (hanya jendela milik Exam Browser)
#   Setiap tombol diklik sekali per jendela.
# Format shortcut (satu per baris): Ctrl+C+B+L   (dicoba berurutan)
# ---------------------------------------------------------------
param(
  [string]$Job = '',
  [string]$Mode = 'open',
  [string]$ExeB64 = '',
  [string]$ArgsB64 = '',
  [string]$RulesB64 = '',
  [string]$NamesB64 = '',
  [string]$KeysB64 = '',
  [int]$Timeout = 150
)
$ErrorActionPreference = 'SilentlyContinue'
$T0 = Get-Date

function From-B64([string]$s) {
  if (-not $s) { return '' }
  try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) } catch { return '' }
}

$Exe = From-B64 $ExeB64
$ExeArgs = From-B64 $ArgsB64
$RulesText = From-B64 $RulesB64
$KeysText = From-B64 $KeysB64
$NamesText = From-B64 $NamesB64
$Dir = ''
$LogFile = ''
$JobErr = ''
$Want = 'on'
$Delay = 0
$Url = ''
$Browser = 'edge'
if ($Job) {
  try {
    $J = Get-Content -LiteralPath $Job -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    if ($J.mode) { $Mode = [string]$J.mode }
    $Exe = [string]$J.exe
    $ExeArgs = [string]$J.args
    $RulesText = [string]$J.rules
    $KeysText = [string]$J.keys
    $NamesText = [string]$J.names
    $Dir = [string]$J.dir
    $LogFile = [string]$J.log
    if ($J.timeout) { $Timeout = [int]$J.timeout }
    if ($J.want) { $Want = [string]$J.want }
    if ($J.url) { $Url = [string]$J.url }
    if ($J.browser) { $Browser = [string]$J.browser }
    if ($J.delay) { $Delay = [int]$J.delay }
  } catch { $JobErr = 'File tugas tidak terbaca: ' + $_.Exception.Message }
}
$Names = @($NamesText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$DirPrefix = ''
if ($Dir) { if ($Dir.Contains('/') -and -not $Dir.Contains('\')) { $DirPrefix = $Dir.TrimEnd('/') + '/' } else { $DirPrefix = $Dir.TrimEnd('\') + '\' } }
# log: file dari agen (bisa dibaca panel); cadangan %TEMP%
$LogOk = $false
if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, ''); $LogOk = $true } catch {} }
if (-not $LogOk) {
  $LogFile = ''
  if ($env:TEMP) { $LogFile = Join-Path $env:TEMP 'ProktorLab-autopilot.log' }
}

function Write-AutoLog([string]$m) {
  if (-not $LogFile) { return }
  $el = [int]((Get-Date) - $T0).TotalSeconds
  try { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' +' + $el + 's [' + $Mode + '] ' + $m) -Encoding UTF8 } catch {}
}

# Aturan klik. Judul tanpa * / ? dicocokkan sebagai "mengandung" (tidak peka huruf besar),
# judul "*" = dialog milik Exam Browser apa saja.
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
    if ($btns.Count -eq 0) { continue }
    $pat = $title
    if ($title -notmatch '[\*\?]') { $pat = '*' + $title + '*' }
    $list += , @{ title = $title; pat = $pat; any = ($title -eq '*'); btns = $btns; fired = $false; clicked = '' }
  }
  return , $list
}

function Test-ButtonMatch([string]$name, $patterns) {
  $n = $name.Replace('&', '').Trim()
  if (-not $n) { return $false }
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
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath -ErrorAction SilentlyContinue)
  foreach ($p in $all) {
    $n = ([string]$p.Name) -replace '\.exe$', ''
    if ([int]$p.ProcessId -eq $PID) { continue }
    foreach ($pat in $Names) { if ($n -like $pat) { $set[[int]$p.ProcessId] = $true } }
    $path = [string]$p.ExecutablePath
    if ($DirPrefix -and $path -and $path.StartsWith($DirPrefix, [StringComparison]::OrdinalIgnoreCase)) { $set[[int]$p.ProcessId] = $true }
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


# ======================================================================
#  Lapisan tampilan Windows (UI Automation). Dipisah agar logika klik bisa
#  diuji tanpa Windows. Jendela = @{ key; pid; title; cls; dialog; el }
#  Tombol = @{ id; name; enabled; el }
# ======================================================================
function Initialize-Uia {
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
  try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch {}
  $script:AE = [System.Windows.Automation.AutomationElement]
  $script:Scope = [System.Windows.Automation.TreeScope]
  $script:TrueCond = [System.Windows.Automation.Condition]::TrueCondition
  $script:WinCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
  $script:BtnCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
  $script:Desk = $AE::RootElement.Current.BoundingRectangle
}

# fungsi Windows untuk mouse & keyboard; dikompilasi hanya saat dibutuhkan (bisa makan waktu beberapa detik)
$NativeState = 0
function Initialize-Native {
  if ($script:NativeState -ne 0) { return ($script:NativeState -gt 0) }
  if ($env:OS -ne 'Windows_NT') { $script:NativeState = -1; return $false }   # fungsi user32 hanya ada di Windows
  try {
    Add-Type -Namespace ProktorLab -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, int e); [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, int flags, int extra); [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);' -ErrorAction Stop
    try { [void][ProktorLab.Native]::SetProcessDPIAware() } catch {}
    $script:NativeState = 1
  } catch {
    $script:NativeState = -1
    Write-AutoLog ('Fungsi mouse/keyboard Windows tidak tersedia: ' + $_.Exception.Message)
  }
  return ($script:NativeState -gt 0)
}

function ConvertTo-Win($el, [string]$parent) {
  try {
    $c = $el.Current
    $r = $c.BoundingRectangle
    $small = $false
    if (-not $r.IsEmpty -and $script:Desk -and $script:Desk.Width -gt 0) { $small = ($r.Width -lt $script:Desk.Width * 0.75 -and $r.Height -lt $script:Desk.Height * 0.75) }
    $key = [string]$c.NativeWindowHandle
    if ($key -eq '0') { $key = 'r' + ($el.GetRuntimeId() -join '.') }
    return @{ el = $el; key = $key; pid = [int]$c.ProcessId; title = [string]$c.Name; cls = [string]$c.ClassName; dialog = (([string]$c.ClassName) -eq '#32770' -or $small); parent = $parent }
  } catch { return $null }
}

# Semua jendela di layar, termasuk dialog "milik" jendela lain: UI Automation
# menaruh dialog seperti itu sebagai anak jendela pemiliknya, bukan di desktop.
function Get-UiWindows {
  $out = New-Object System.Collections.ArrayList
  $tops = $null
  try { $tops = $script:AE::RootElement.FindAll($script:Scope::Children, $script:TrueCond) } catch { return @() }
  foreach ($t in $tops) {
    $w = ConvertTo-Win $t ''
    if (-not $w) { continue }
    [void]$out.Add($w)
    try {
      foreach ($c in $t.FindAll($script:Scope::Children, $script:WinCond)) {
        $cw = ConvertTo-Win $c $w.title
        if ($cw) { [void]$out.Add($cw) }
      }
    } catch {}
  }
  return $out.ToArray()   # tiap jendela (hashtable) menjadi satu item
}

function ConvertTo-Btn($e) {
  try {
    $c = $e.Current
    $en = $true
    try { $en = [bool]$c.IsEnabled } catch {}
    return @{ el = $e; id = ($e.GetRuntimeId() -join '.'); name = ([string]$c.Name).Replace('&', '').Trim(); enabled = $en }
  } catch { return $null }
}

# Tombol pertama yang cocok. Jika tidak ada tombol biasa, cari kontrol lain dengan
# nama persis sama (tombol RUN pada sebagian aplikasi bukan tombol standar).
function Find-UiButton($w, $patterns) {
  $all = $null
  try { $all = $w.el.FindAll($script:Scope::Descendants, $script:BtnCond) } catch { return $null }
  foreach ($b in $all) {
    $n = ''
    try { $n = [string]$b.Current.Name } catch { continue }
    if (Test-ButtonMatch $n $patterns) { return (ConvertTo-Btn $b) }
  }
  foreach ($p in $patterns) {
    if ($p -match '[\*\?]') { continue }
    try {
      $cond = New-Object System.Windows.Automation.PropertyCondition($script:AE::NameProperty, $p, [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase)
      foreach ($e in $w.el.FindAll($script:Scope::Descendants, $cond)) {
        $ct = $e.Current.ControlType
        if ($ct -eq [System.Windows.Automation.ControlType]::Window -or $ct -eq [System.Windows.Automation.ControlType]::TitleBar) { continue }
        return (ConvertTo-Btn $e)
      }
    } catch {}
  }
  return $null
}

function Get-UiButtonNames($w) {
  $names = @()
  try {
    foreach ($b in $w.el.FindAll($script:Scope::Descendants, $script:BtnCond)) {
      $n = ([string]$b.Current.Name).Replace('&', '').Trim()
      if ($n -and $names -notcontains $n) { $names += $n }
      if ($names.Count -ge 8) { break }
    }
  } catch {}
  return $names
}

# Klik dengan satu cara. Mengembalikan objek (berhasil dijalankan) atau $null.
#  invoke   : UI Automation (tanpa menggerakkan mouse); dijalankan di thread lain karena
#             tombol yang membuka dialog modal membuat Invoke() menunggu dialog ditutup
#  mouse    : gerakkan mouse ke tengah tombol lalu klik
#  keyboard : fokus ke tombol lalu tekan Spasi
function Invoke-UiClick($w, $btn, [string]$how) {
  $script:ClickErr = ''
  try {
    switch ($how) {
      'invoke' {
        $pat = $btn.el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $ps = [powershell]::Create()
        [void]$ps.AddScript('param($p) $p.Invoke()').AddArgument($pat)
        [void]$ps.BeginInvoke()
        return $ps
      }
      'mouse' {
        if (-not (Initialize-Native)) { $script:ClickErr = 'fungsi mouse tidak tersedia'; return $null }
        $pt = $null
        try { $pt = $btn.el.GetClickablePoint() } catch {
          $r = $btn.el.Current.BoundingRectangle
          if ($r.IsEmpty) { throw 'posisi tombol tidak diketahui' }
          $pt = New-Object System.Windows.Point(($r.X + $r.Width / 2), ($r.Y + $r.Height / 2))
        }
        try { [void][ProktorLab.Native]::SetForegroundWindow([IntPtr][int64]$w.el.Current.NativeWindowHandle) } catch {}
        Start-Sleep -Milliseconds 150
        [void][ProktorLab.Native]::SetCursorPos([int]$pt.X, [int]$pt.Y)
        Start-Sleep -Milliseconds 80
        [ProktorLab.Native]::mouse_event(2, 0, 0, 0, 0)
        Start-Sleep -Milliseconds 60
        [ProktorLab.Native]::mouse_event(4, 0, 0, 0, 0)
        return $true
      }
      'keyboard' {
        $btn.el.SetFocus()
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.SendKeys]::SendWait(' ')
        return $true
      }
    }
  } catch { $script:ClickErr = [string]$_.Exception.Message }
  return $null
}

function Test-UacVisible { return (@(Get-Process -Name consent -ErrorAction SilentlyContinue).Count -gt 0) }

function Get-ProcName([int]$id) {
  try { return (Get-Process -Id $id -ErrorAction Stop).ProcessName } catch { return '?' }
}

# ======================================================================
#  Logika klik (tidak bergantung pada Windows)
# ======================================================================
$Methods = @('invoke', 'mouse', 'keyboard')
$RetryMs = 3500
$Tree = @{}
$Learned = @{}
$Seen = @{}
$Clicks = @{}
$FirstPass = $true
$NewWinAt = [datetime]::MinValue
$LastClick = [datetime]::MinValue
$SeenExam = $false
$UacSeen = $false
$WinLogged = 0

function Test-InExam($w) { return ($script:Tree.ContainsKey([int]$w.pid) -or $script:Learned.ContainsKey([int]$w.pid)) }

function Write-WinLog($w, [string]$prefix) {
  if ($script:WinLogged -ge 40) { return }
  $script:WinLogged++
  $t = $prefix + ' "' + $w.title + '" [' + $w.cls + '] proses ' + (Get-ProcName $w.pid) + ' (PID ' + $w.pid + ')'
  if ($w.parent) { $t += ', milik jendela "' + $w.parent + '"' }
  if (Test-InExam $w) { $t += ', bagian Exam Browser' }
  if ($w.dialog) { $b = @(Get-UiButtonNames $w); if ($b.Count) { $t += ', tombol: ' + ($b -join ', ') } }
  Write-AutoLog $t
}

# Hasil klik sebelumnya: 'ok' = sudah berefek (dialog baru muncul, tombol jadi nonaktif, atau
# Invoke masih menunggu karena tombol membuka dialog modal), 'wait' = tunggu dulu,
# 'retry' = coba cara lain. Klik yang tampak berhasil ditunggu 8 detik sebelum diulang
# agar tombol seperti RUN tidak terklik dua kali.
function Get-ClickVerdict($st, $btn) {
  $age = ((Get-Date) - $st.last).TotalMilliseconds
  if ($script:NewWinAt -gt $st.last) { return 'ok' }
  if (-not $btn.enabled) { return 'ok' }
  $state = ''
  if ($st.ps) {
    try {
      $state = [string]$st.ps.InvocationStateInfo.State
      if ($state -eq 'Failed' -and $st.ps.InvocationStateInfo.Reason) { $st.err = [string]$st.ps.InvocationStateInfo.Reason.Message }
    } catch {}
  }
  if ($state -eq 'Running') { if ($age -gt 2000) { return 'ok' } return 'wait' }
  if ($state -eq 'Failed') { return 'retry' }
  $need = $RetryMs
  if ($state -eq 'Completed') { $need = 8000 }
  if ($age -lt $need) { return 'wait' }
  return 'retry'
}

function Invoke-ClickPass {
  $wins = @(Get-UiWindows)
  $now = Get-Date
  foreach ($w in $wins) {
    if ($script:Seen.ContainsKey($w.key)) { continue }
    $script:Seen[$w.key] = $now
    # relevan = milik Exam Browser, dialog standar Windows, atau judulnya ada di aturan
    $relevant = (Test-InExam $w) -or ($w.cls -eq '#32770')
    foreach ($r in $Rules) { if (-not $r.any -and $w.title -like $r.pat) { $relevant = $true } }
    if ($script:FirstPass) {
      if ($relevant) { Write-WinLog $w 'Sudah terbuka:' }
    } elseif ($relevant) {
      $script:NewWinAt = $now
      Write-WinLog $w 'Jendela baru:'
    } elseif ($w.title) {
      Write-WinLog $w 'Jendela lain:'
    }
  }
  if ($script:FirstPass) { Write-AutoLog ('Jendela di layar saat mulai: ' + $wins.Count); $script:FirstPass = $false }

  foreach ($w in $wins) {
    for ($i = 0; $i -lt $Rules.Count; $i++) {
      $r = $Rules[$i]
      if ($r.any) {
        if (-not $w.dialog -or -not (Test-InExam $w)) { continue }
      } else {
        if (-not ($w.title -like $r.pat)) { continue }
        $script:Learned[[int]$w.pid] = $true   # dialog milik proses ini ikut dianggap Exam Browser
      }
      $btn = Find-UiButton $w $r.btns
      if (-not $btn) { continue }
      $key = [string]$i + '|' + $btn.id
      $st = $script:Clicks[$key]
      if ($st) {
        if ($st.done -or $st.gaveUp) { continue }
        $v = Get-ClickVerdict $st $btn
        if ($v -eq 'ok') { $st.done = $true; continue }
        if ($v -eq 'wait') { continue }
        if ($st.tries -ge $Methods.Count) {
          $st.gaveUp = $true
          $why = ''
          if ($st.err) { $why = ': ' + $st.err }
          Write-AutoLog ('Tombol "' + $btn.name + '" di "' + $w.title + '" tidak bereaksi setelah ' + $st.tries + ' cara klik' + $why)
          continue
        }
        Write-AutoLog ('Tombol "' + $btn.name + '" belum bereaksi, dicoba cara lain.' + $(if ($st.err) { ' (' + $st.err + ')' } else { '' }))
      } else {
        if (-not $btn.enabled) {
          if (-not $script:Clicks.ContainsKey('wait|' + $key)) { $script:Clicks['wait|' + $key] = @{ done = $true }; Write-AutoLog ('Menunggu tombol "' + $btn.name + '" di "' + $w.title + '" aktif...') }
          continue
        }
        $st = @{ tries = 0; done = $false; gaveUp = $false; last = [datetime]::MinValue; name = $btn.name; title = $w.title; rule = $i; ps = $null; err = '' }
        $script:Clicks[$key] = $st
      }
      # coba cara berikutnya; lewati cara yang tidak bisa dijalankan
      $h = $null
      $m = ''
      while ($st.tries -lt $Methods.Count -and -not $h) {
        $m = $Methods[$st.tries]
        $st.tries++
        $h = Invoke-UiClick $w $btn $m
        if (-not $h) { Write-AutoLog ('Cara klik ' + $m + ' tidak bisa untuk "' + $btn.name + '": ' + $script:ClickErr); $st.err = $script:ClickErr }
      }
      $st.last = Get-Date
      if (-not $h) { continue }
      $st.ps = $null
      if ($m -eq 'invoke') { $st.ps = $h }
      $r.fired = $true
      $r.clicked = $btn.name
      $script:LastClick = Get-Date
      Write-AutoLog ('Klik "' + $btn.name + '" di jendela "' + $w.title + '" (' + $m + ')')
      Start-Sleep -Milliseconds 300
      break
    }
  }
}

function Test-OpenDone {
  $spec = @($Rules | Where-Object { -not $_.any })
  if ($spec.Count -eq 0) { return $false }
  if (@($spec | Where-Object { -not $_.fired }).Count -gt 0) { return $false }
  return (((Get-Date) - $script:LastClick).TotalSeconds -gt 8)
}

function Write-Summary {
  $clicked = @()
  $missing = @()
  $failed = @()
  for ($i = 0; $i -lt $Rules.Count; $i++) {
    $r = $Rules[$i]
    $sts = @($script:Clicks.Values | Where-Object { $_.ContainsKey('rule') -and $_.rule -eq $i })
    $good = @($sts | Where-Object { -not $_.gaveUp })
    if ($good.Count) { foreach ($x in $good) { if ($clicked -notcontains $x.name) { $clicked += $x.name } } }
    elseif ($sts.Count) { foreach ($x in $sts) { $failed += ($x.name + ' di "' + $x.title + '"' + $(if ($x.err) { ' (' + $x.err + ')' } else { '' })) } }
    elseif (-not $r.any) { $missing += (($r.btns -join '/') + ' di "' + $r.title + '"') }
  }
  $o = @{ clicked = @($clicked); missing = @($missing); failed = @($failed); uac = [bool]$script:UacSeen; admin = [string]$Admin; exam = [bool]$script:SeenExam }
  Write-AutoLog ('RINGKASAN ' + (ConvertTo-Json -InputObject $o -Compress))
}

function Update-State {
  $script:Tree = Get-ExamTree $RootId
  if ($script:Tree.Count -gt 0 -and -not $script:SeenExam) { $script:SeenExam = $true; Write-AutoLog ('Proses Exam Browser terlihat: ' + (@($script:Tree.Keys | ForEach-Object { (Get-ProcName $_) + '(' + $_ + ')' }) -join ', ')) }
  if (-not $script:UacSeen -and (Test-UacVisible)) { $script:UacSeen = $true; Write-AutoLog 'Jendela UAC (izin Administrator) muncul. Jendela ini tidak bisa diklik program apa pun.' }
}

function Start-OpenLoop {
  $deadline = (Get-Date).AddSeconds($Timeout)
  $stateAt = [datetime]::MinValue
  while ((Get-Date) -lt $deadline) {
    if (((Get-Date) - $stateAt).TotalMilliseconds -gt 1500) { Update-State; $stateAt = Get-Date }
    Invoke-ClickPass
    if (Test-OpenDone) { break }
    Start-Sleep -Milliseconds 400
  }
  if (-not $script:SeenExam) { Write-AutoLog 'Proses Exam Browser tidak terlihat selama klik otomatis berjalan.' }
  Write-Summary
}

function Set-ExamFocus($tree) {
  if (-not (Initialize-Native)) { return }
  foreach ($id in @($tree.Keys)) {
    try {
      $p = Get-Process -Id $id -ErrorAction Stop
      if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void][ProktorLab.Native]::SetForegroundWindow($p.MainWindowHandle); return }
    } catch {}
  }
}

function Send-Combo($combo) {
  if (-not (Initialize-Native)) { [System.Windows.Forms.SendKeys]::SendWait('^c'); return }
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

# ======================================================================
#  Mode layar penuh browser
# ======================================================================
$Browsers = @{ chrome = 'Google Chrome'; msedge = 'Microsoft Edge'; firefox = 'Mozilla Firefox'; opera = 'Opera'; brave = 'Brave'; vivaldi = 'Vivaldi'; browser = 'Yandex Browser'; iexplore = 'Internet Explorer' }

# jendela browser yang terlihat, urut dari yang paling depan
function Get-BrowserWindows {
  $out = New-Object System.Collections.ArrayList
  $tops = $null
  try { $tops = $script:AE::RootElement.FindAll($script:Scope::Children, $script:TrueCond) } catch { return @() }
  foreach ($t in $tops) {
    try {
      $c = $t.Current
      $pn = ([string](Get-ProcName ([int]$c.ProcessId))).ToLower()
      if (-not $Browsers.ContainsKey($pn) -or -not [string]$c.Name) { continue }
      $hwnd = [int64]$c.NativeWindowHandle
      $min = $false
      if ($script:NativeState -gt 0) { try { $min = [ProktorLab.Native]::IsIconic([IntPtr]$hwnd) } catch {} }
      $r = $c.BoundingRectangle
      if (-not $min -and ($r.IsEmpty -or $r.Width -lt 300 -or $r.Height -lt 200)) { continue }
      [void]$out.Add(@{ el = $t; hwnd = $hwnd; pid = [int]$c.ProcessId; proc = $pn; title = [string]$c.Name; min = $min })
    } catch {}
  }
  return $out.ToArray()
}

function Get-WinRect($w) {
  try { $r = $w.el.Current.BoundingRectangle; return @{ x = [double]$r.X; y = [double]$r.Y; w = [double]$r.Width; h = [double]$r.Height; empty = [bool]$r.IsEmpty } } catch { return @{ empty = $true } }
}

# layar (monitor) tempat jendela berada
function Get-MonitorRect($r) {
  try {
    $pt = New-Object System.Drawing.Point([int]($r.x + $r.w / 2), [int]($r.y + $r.h / 2))
    $b = [System.Windows.Forms.Screen]::FromPoint($pt).Bounds
    return @{ x = [double]$b.X; y = [double]$b.Y; w = [double]$b.Width; h = [double]$b.Height }
  } catch {}
  $d = $script:Desk
  return @{ x = [double]$d.X; y = [double]$d.Y; w = [double]$d.Width; h = [double]$d.Height }
}

# layar penuh = jendela menutupi seluruh layar tanpa bingkai (jendela maximize biasa
# bergeser beberapa piksel ke luar layar dan tidak menutupi taskbar)
function Test-WinFull($w) {
  $r = Get-WinRect $w
  if ($r.empty) { return $false }
  $m = Get-MonitorRect $r
  return ($r.x -ge $m.x - 1 -and $r.y -ge $m.y - 1 -and $r.w -ge $m.w - 2 -and $r.h -ge $m.h - 2)
}

function Get-RectText($w) { $r = Get-WinRect $w; if ($r.empty) { return '-' }; return ([string][int]$r.x + ',' + [int]$r.y + ' ' + [int]$r.w + 'x' + [int]$r.h) }

function Set-WinForeground($w) {
  $ok = $false
  if (Initialize-Native) {
    $h = [IntPtr]$w.hwnd
    try { if ([ProktorLab.Native]::IsIconic($h)) { [void][ProktorLab.Native]::ShowWindow($h, 9); Start-Sleep -Milliseconds 500 } } catch {}
    try { $w.el.SetFocus() } catch {}
    Start-Sleep -Milliseconds 250
    if ([ProktorLab.Native]::GetForegroundWindow() -ne $h) {
      # Windows hanya mengizinkan pindah jendela aktif dari program yang baru memberi input
      [ProktorLab.Native]::keybd_event(0x12, 0, 0, 0)
      [void][ProktorLab.Native]::SetForegroundWindow($h)
      [ProktorLab.Native]::keybd_event(0x12, 0, 2, 0)
      Start-Sleep -Milliseconds 300
    }
    $ok = ([ProktorLab.Native]::GetForegroundWindow() -eq $h)
  } else {
    try { $w.el.SetFocus(); $ok = $true } catch {}
    Start-Sleep -Milliseconds 300
  }
  return $ok
}

function Send-F11 {
  if ($script:NativeState -gt 0) {
    $sc = [byte][ProktorLab.Native]::MapVirtualKey(0x7A, 0)
    [ProktorLab.Native]::keybd_event(0x7A, $sc, 0, 0)
    Start-Sleep -Milliseconds 60
    [ProktorLab.Native]::keybd_event(0x7A, $sc, 2, 0)
  } else {
    [System.Windows.Forms.SendKeys]::SendWait('{F11}')
  }
}

function Write-Result([bool]$ok, [string]$msg) {
  Write-AutoLog ('HASIL ' + (ConvertTo-Json -InputObject @{ ok = $ok; msg = $msg } -Compress))
}

function Start-FullscreenMode {
  $wantFull = ($Want -ne 'off')
  if ($Delay -gt 0) { Start-Sleep -Seconds $Delay }
  [void](Initialize-Native)
  $deadline = (Get-Date).AddSeconds($Timeout)
  $w = $null
  $waited = $false
  while ((Get-Date) -lt $deadline) {
    $list = @(Get-BrowserWindows)
    if ($list.Count) { $w = $list[0]; break }
    $waited = $true
    Start-Sleep -Milliseconds 700
  }
  if (-not $w) { Write-Result $false 'Tidak ada jendela browser yang terbuka di layar siswa.'; return }
  if ($waited) { Start-Sleep -Milliseconds 1500 }   # browser baru dibuka, tunggu sampai siap
  $desc = $Browsers[$w.proc] + ' ("' + $w.title + '")'
  Write-AutoLog ('Browser paling depan: ' + $desc + ', posisi ' + (Get-RectText $w))
  if ((Test-WinFull $w) -eq $wantFull) {
    if ($wantFull) { Write-Result $true ('Browser ' + $desc + ' sudah dalam layar penuh.') }
    else { Write-Result $true ('Browser ' + $desc + ' tidak dalam layar penuh.') }
    return
  }
  for ($try = 1; $try -le 3; $try++) {
    $before = Get-RectText $w
    $fg = Set-WinForeground $w
    Send-F11
    Write-AutoLog ('Tekan F11 (percobaan ' + $try + ', jendela aktif: ' + $fg + ')')
    Start-Sleep -Milliseconds 1500
    $after = Get-RectText $w
    if ((Test-WinFull $w) -eq $wantFull) {
      if ($wantFull) { Write-Result $true ('Browser ' + $desc + ' sekarang layar penuh.') }
      else { Write-Result $true ('Browser ' + $desc + ' keluar dari layar penuh.') }
      return
    }
    if ($after -ne $before) {
      # ukuran berubah tapi tidak cocok dengan perkiraan: jangan tekan F11 lagi (bisa membalikkan)
      Write-Result $true ('F11 sudah ditekan di ' + $desc + ' (ukuran jendela berubah ' + $before + ' -> ' + $after + ').')
      return
    }
  }
  Write-Result $false ('Browser ' + $desc + ' tidak berubah setelah F11 ditekan 3 kali. Pastikan tidak ada jendela lain yang menghalangi.')
}

# ======================================================================
#  Mode kiosk: situs layar penuh terkunci + penjaga
# ======================================================================
$KioskNames = @{ edge = 'Microsoft Edge'; chrome = 'Google Chrome' }
$KioskAllow = @('osk', 'tabtip', 'textinputhost', 'lockapp')   # keyboard layar sentuh dsb. boleh tampil
$KioskMaxLoops = 0      # >0 hanya untuk pengujian

function Find-BrowserExe([string]$b) {
  if ($env:PROKTORLAB_TEST_BROWSER) { return $env:PROKTORLAB_TEST_BROWSER }   # hanya untuk pengujian
  $c = @()
  if ($b -eq 'chrome') {
    if ($env:ProgramFiles) { $c += (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe') }
    if (${env:ProgramFiles(x86)}) { $c += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe') }
    if ($env:LOCALAPPDATA) { $c += (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe') }
  } else {
    if (${env:ProgramFiles(x86)}) { $c += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:ProgramFiles) { $c += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
  }
  foreach ($x in $c) { if ($x -and (Test-Path -LiteralPath $x)) { return $x } }
  return ''
}

# Profil browser terpisah: memaksa jendela baru bermode kiosk walau browser biasa
# sedang terbuka, dan menjadi penanda proses kiosk (untuk dijaga / ditutup).
function Get-KioskDataDir([string]$b) {
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = $env:TEMP }
  if (-not $base) { $base = '/tmp' }
  return (Join-Path $base ('ProktorLab-kiosk-' + $b))
}

function Get-KioskArgs([string]$b, [string]$url, [string]$dataDir) {
  $u = $url.Replace('"', '%22')
  $a = '--kiosk "' + $u + '" --no-first-run --no-default-browser-check --hide-crash-restore-bubble --user-data-dir="' + $dataDir + '"'
  if ($b -eq 'edge') { $a += ' --edge-kiosk-type=fullscreen' } else { $a += ' --disable-session-crashed-bubble' }
  return $a
}

# PID proses browser kiosk (baris perintahnya memuat folder profil kiosk)
function Get-KioskProcs {
  $leaf = [IO.Path]::GetFileName($script:KioskExe)
  $out = @()
  $list = $null
  try {
    $list = @(Get-CimInstance Win32_Process -Filter ("Name='" + $leaf + "'") -Property ProcessId, CommandLine -ErrorAction Stop | ForEach-Object { @{ id = [int]$_.ProcessId; cmd = [string]$_.CommandLine } })
  } catch {
    $n = $leaf -replace '\.exe$', ''
    $list = @(Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { $cl = ''; try { $cl = [string]$_.CommandLine } catch {}; @{ id = [int]$_.Id; cmd = $cl } })
  }
  foreach ($x in $list) { if ($x.cmd -and $x.cmd.Contains($script:KioskMark)) { $out += $x.id } }
  return $out
}

function Start-KioskBrowser {
  $sp = @{ FilePath = $script:KioskExe; ArgumentList = (Get-KioskArgs $Browser $Url $script:KioskData); PassThru = $true }
  try { $pr = Start-Process @sp -ErrorAction Stop; return [int]$pr.Id } catch { Write-AutoLog ('Gagal membuka browser: ' + $_.Exception.Message); return 0 }
}

# jendela utama kiosk: hwnd, 0 = belum ada, -1 = tidak bisa diperiksa (tanpa fungsi Windows)
function Get-KioskWindow($pids) {
  if ($script:NativeState -le 0) { return [int64]-1 }
  foreach ($id in $pids) {
    try { $h = (Get-Process -Id $id -ErrorAction Stop).MainWindowHandle; if ($h -ne [IntPtr]::Zero) { return [int64]$h } } catch {}
  }
  return [int64]0
}

function Get-ForegroundInfo {
  if ($script:NativeState -le 0) { return @{ pid = 0; name = '' } }
  try {
    $h = [ProktorLab.Native]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return @{ pid = 0; name = '' } }
    [uint32]$fp = 0
    [void][ProktorLab.Native]::GetWindowThreadProcessId($h, [ref]$fp)
    return @{ pid = [int]$fp; name = ([string](Get-ProcName ([int]$fp))).ToLower() }
  } catch { return @{ pid = 0; name = '' } }
}

function Set-KioskFront([int64]$hwnd) {
  if ($hwnd -le 0) { return }
  $h = [IntPtr]$hwnd
  try { if ([ProktorLab.Native]::IsIconic($h)) { [void][ProktorLab.Native]::ShowWindow($h, 9) } } catch {}
  [ProktorLab.Native]::keybd_event(0x12, 0, 0, 0)
  [void][ProktorLab.Native]::SetForegroundWindow($h)
  [ProktorLab.Native]::keybd_event(0x12, 0, 2, 0)
}

function Start-KioskGuard {
  $b = 'edge'
  if ($Browser -eq 'chrome') { $b = 'chrome' }
  $exe = Find-BrowserExe $b
  if (-not $exe -and $b -eq 'chrome') { $b = 'edge'; $exe = Find-BrowserExe 'edge'; if ($exe) { Write-AutoLog 'Google Chrome tidak ada, memakai Microsoft Edge.' } }
  if (-not $exe) { Write-Result $false ('Browser ' + $KioskNames[$b] + ' tidak ditemukan di komputer ini.'); return }
  $script:Browser = $b
  $script:KioskExe = $exe
  $script:KioskData = Get-KioskDataDir $b
  $script:KioskMark = $script:KioskData
  $name = $KioskNames[$b]
  Write-AutoLog ('Penjaga situs terkunci: ' + $Url + ' di ' + $name + ' (' + $exe + ')')
  $reported = $false
  $launched = $false
  $start = Get-Date
  $relaunch = 0
  $refocus = 0
  $away = 0
  $lastNote = [datetime]::MinValue
  $loops = 0
  while ($true) {
    $loops++
    if ($script:KioskMaxLoops -gt 0 -and $loops -gt $script:KioskMaxLoops) { break }
    $pids = @(Get-KioskProcs)
    if ($pids.Count -eq 0) {
      if ($launched) { $relaunch++; Write-AutoLog ('Browser ditutup, situs dibuka lagi (ke-' + $relaunch + ').') }
      [void](Start-KioskBrowser)
      $launched = $true
      Start-Sleep -Milliseconds 2000
      continue
    }
    $launched = $true
    if ($script:NativeState -eq 0) { [void](Initialize-Native) }   # setelah browser terbuka, agar tidak menunda
    $hw = Get-KioskWindow $pids
    if (-not $reported) {
      if ($hw -ne 0) {
        $t = 'Situs dibuka terkunci layar penuh di ' + $name + '. Siswa tidak bisa keluar; tutup dengan #Tutup Browser.'
        if ($hw -lt 0) { $t += ' (Penjagaan jendela depan tidak aktif di komputer ini.)' }
        Write-Result $true $t
        $reported = $true
      } elseif (((Get-Date) - $start).TotalSeconds -gt 30) {
        Write-Result $false ('Browser ' + $name + ' berjalan tetapi jendelanya belum muncul setelah 30 detik.')
        $reported = $true
      }
    }
    if ($hw -gt 0) {
      $fg = Get-ForegroundInfo
      if ($fg.pid -gt 0 -and $pids -notcontains $fg.pid -and $KioskAllow -notcontains $fg.name) { $away++ } else { $away = 0 }
      if ($away -ge 2) {
        Set-KioskFront $hw
        $refocus++
        $away = 0
        if (((Get-Date) - $lastNote).TotalSeconds -gt 30) { Write-AutoLog ('Siswa membuka "' + $fg.name + '", situs dikembalikan ke depan (total ' + $refocus + 'x).'); $lastNote = Get-Date }
      }
    }
    Start-Sleep -Milliseconds 700
  }
}

# ---------------- mulai ----------------
if ($MyInvocation.InvocationName -eq '.') { return }   # dimuat untuk pengujian
if ($Mode -eq 'open' -and -not $Job) { try { Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue } catch {} }
if ($JobErr) { Write-AutoLog $JobErr; exit 1 }
$Rules = Read-Rules $RulesText
$Admin = '?'
try { $Admin = [string]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
Write-AutoLog ('Mulai (PID ' + $PID + ', admin: ' + $Admin + '). Proses: ' + ($Names -join ',') + ' | Folder: ' + $Dir + ' | Aturan: ' + (($Rules | ForEach-Object { $_.title + ' > ' + ($_.btns -join '/') }) -join ' ; '))

# buka Exam Browser lebih dulu (bila diminta), baru siapkan UI Automation
$RootId = 0
if ($Mode -eq 'open' -and $Exe) {
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
if ($Mode -eq 'open' -and $Rules.Count -eq 0) { Write-AutoLog 'Tidak ada aturan klik.'; exit 0 }

# ================= MODE KIOSK (tidak butuh UI Automation) =================
if ($Mode -eq 'kiosk') { Start-KioskGuard; exit 0 }

try { Initialize-Uia } catch {
  Write-AutoLog ('UI Automation tidak tersedia, klik otomatis dilewati: ' + $_.Exception.Message)
  if ($Mode -eq 'open') { Write-Summary }
  if ($Mode -eq 'fullscreen') { Write-Result $false ('UI Automation tidak tersedia: ' + $_.Exception.Message) }
  exit 0
}
Write-AutoLog 'Siap memantau jendela.'

# ================= MODE FULLSCREEN =================
if ($Mode -eq 'fullscreen') { Start-FullscreenMode; exit 0 }

# ================= MODE CLOSE =================
if ($Mode -eq 'close') {
  $combos = Read-Combos $KeysText
  if ($combos.Count -eq 0) { Write-AutoLog 'Tidak ada shortcut keluar yang valid.'; exit 0 }
  $done = $false
  foreach ($c in $combos) {
    $Tree = Get-ExamTree 0
    if ($Tree.Count -eq 0) { $done = $true; break }
    Set-ExamFocus $Tree
    Start-Sleep -Milliseconds 300
    Send-Combo $c
    Write-AutoLog ('Tekan ' + $c.text)
    $until = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $until) {
      Start-Sleep -Milliseconds 500
      $Tree = Get-ExamTree 0
      if ($Tree.Count -eq 0) { $done = $true; break }
      Invoke-ClickPass
    }
    if ($done) { break }
  }
  if ($done) { Write-AutoLog 'Exam Browser tertutup.' } else { Write-AutoLog 'Exam Browser masih terbuka setelah semua shortcut dicoba.' }
  exit 0
}

# ================= MODE OPEN =================
# Exam Browser dibuka oleh agen (atau di atas); di sini tombol jendela pembukanya
# diklik sampai semua aturan berjudul khusus selesai, lalu ringkasan ditulis ke log.
Start-OpenLoop
