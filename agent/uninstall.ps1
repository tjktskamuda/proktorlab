# ProktorLab - Hapus Agen
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'GAGAL: buka PowerShell sebagai Administrator.' -ForegroundColor Red; return }
$Base = Join-Path $env:ProgramData 'ProktorLab'
try { Stop-ScheduledTask -TaskName 'ProktorLab Agent' -ErrorAction SilentlyContinue } catch {}
try { Unregister-ScheduledTask -TaskName 'ProktorLab Agent' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
try {
  Get-ScheduledTask -TaskPath '\ProktorLab\Run\' -ErrorAction SilentlyContinue |
    ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
} catch {}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*ProktorLab\agent.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Remove-Item -Path $Base -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ('Agen ProktorLab sudah dihapus dari ' + $env:COMPUTERNAME + '.') -ForegroundColor Green
