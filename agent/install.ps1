# ProktorLab - Pemasang Agen
# Jalankan di PowerShell (Administrator) pada setiap komputer lab.
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host ''
  Write-Host 'GAGAL: PowerShell belum dibuka sebagai Administrator.' -ForegroundColor Red
  Write-Host 'Klik kanan Start > Terminal (Admin) / Windows PowerShell (Admin), lalu tempel perintah lagi.' -ForegroundColor Yellow
  return
}
$Base = Join-Path $env:ProgramData 'ProktorLab'
$TaskName = 'ProktorLab Agent'
Write-Host ''
Write-Host '=== Memasang Agen ProktorLab di' $env:COMPUTERNAME '===' -ForegroundColor Cyan

# 1. hentikan agen lama bila ada
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*ProktorLab\agent.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 2. folder agen (hanya SYSTEM & Administrator yang boleh mengubah)
New-Item -ItemType Directory -Path $Base -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Base 'run') -Force | Out-Null
& icacls.exe $Base /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
Write-Host '[1/4] Folder agen siap:' $Base

# 3. tulis agen + konfigurasi
$agent = @'
{{AGENT}}
'@
[IO.File]::WriteAllText((Join-Path $Base 'agent.ps1'), $agent, (New-Object Text.UTF8Encoding($true)))
$cfg = ConvertTo-Json -InputObject @{ server = '{{URL}}'; key = '{{KEY}}'; group = '{{GROUP}}' }
$cfgPath = Join-Path $Base 'config.json'
[IO.File]::WriteAllText($cfgPath, $cfg, (New-Object Text.UTF8Encoding($false)))
& icacls.exe $cfgPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
Write-Host '[2/4] Agen & konfigurasi ditulis.'

# 4. tugas terjadwal: jalan saat komputer menyala + penjaga tiap 5 menit
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Base 'agent.ps1') + '"')
$triggers = @(New-ScheduledTaskTrigger -AtStartup)
try { $triggers += New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) } catch {}
$pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $triggers -Principal $pri -Settings $set -Description 'Agen ProktorLab: menerima perintah dari Panel Proktor (buka/tutup Exam Browser, WOL, shutdown).' -Force | Out-Null
Write-Host '[3/4] Tugas terjadwal "ProktorLab Agent" dibuat.'

# 5. Wake on LAN: matikan Fast Startup agar komputer bisa dinyalakan dari jaringan
try {
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
  Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    try { Set-NetAdapterPowerManagement -Name $_.Name -WakeOnMagicPacket Enabled -ErrorAction SilentlyContinue } catch {}
  }
} catch {}

Start-ScheduledTask -TaskName $TaskName
Write-Host '[4/4] Agen dijalankan.'
Write-Host ''
Write-Host ('BERHASIL! ' + $env:COMPUTERNAME + ' akan muncul di Panel Proktor dalam beberapa detik.') -ForegroundColor Green
Write-Host ''
