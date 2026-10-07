# Installs a built installer silently on the CI machine, checks the install,
# runs the installed app's self-checks, uninstalls, and checks that the user's
# data folder (%APPDATA%\talkflow) survived while everything else is gone.
#
#   pwsh windows/tests/smoke-install.ps1 -Installer out\talkflow-windows-x64-setup.exe
param(
    [Parameter(Mandatory)] [string] $Installer,
    # The version the installed app must report (0.0.0 for a build not made from a release tag).
    [string] $ExpectVersion
)
$ErrorActionPreference = 'Stop'

$app = Join-Path $env:LOCALAPPDATA 'Programs\talkflow'
$local = Join-Path $env:LOCALAPPDATA 'talkflow'
$data = Join-Path $env:APPDATA 'talkflow'

function Run($exe, $arguments) {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "$exe $arguments exited with $($p.ExitCode)" }
}

Run $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
foreach ($file in 'talkflow.exe', 'engine\whisper-server.exe', 'unins000.exe') {
    if (-not (Test-Path (Join-Path $app $file))) { throw "missing after install: $file" }
}
if (-not (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\talkflow.lnk'))) { throw "no Start menu shortcut" }

# The installed app runs, renders text exactly like the tests, and reports its setup.
$exe = Join-Path $app 'talkflow.exe'
Run $exe @('--formattest', '"um so the the meeting is on Friday, wait no, Thursday period see you there"')
$format = Get-Content (Join-Path $env:TEMP 'talkflow-formattest.txt') -Raw
Write-Host $format
if ($format -notmatch 'So the meeting is on Thursday\. See you there') { throw "unexpected --formattest output" }
Run $exe @('--enginecheck')
$check = Get-Content (Join-Path $env:TEMP 'talkflow-enginecheck.txt') -Raw
Write-Host $check
if ($ExpectVersion -and $check -notmatch "(?m)^version: $([regex]::Escape($ExpectVersion)) ") { throw "the installed app does not report version $ExpectVersion" }
# "Report a problem...": a zip with the report and logs, and no dictated text.
Run $exe @('--diagnostics')
$zip = (Get-Content (Join-Path $env:TEMP 'talkflow-diagnostics.txt') -Raw).Trim()
if (-not (Test-Path $zip)) { throw "--diagnostics did not save $zip" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
$entries = $archive.Entries | ForEach-Object { $_.FullName }
$report = $archive.Entries | Where-Object { $_.FullName -eq 'report.txt' } | ForEach-Object {
    $reader = New-Object IO.StreamReader($_.Open()); try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}
$archive.Dispose()
Write-Host "diagnostics: $zip ($($entries -join ', '))"
if ($entries -notcontains 'report.txt') { throw "the diagnostics zip has no report.txt" }
Write-Host $report
# The microphone section must be there even on a runner with no microphone.
foreach ($line in 'microphones \(WASAPI\):', 'one second from the default microphone, WASAPI: ', 'one second from the default microphone, waveIn: ') {
    if ($report -notmatch $line) { throw "report.txt has no '$line' line" }
}
Remove-Item $zip
Run $exe @('--uninstallplan')
Get-Content (Join-Path $env:TEMP 'talkflow-uninstallplan.txt')

# User data that must survive, and machine data that must not.
New-Item -ItemType Directory -Force $data, (Join-Path $local 'models') | Out-Null
Set-Content (Join-Path $data 'stats.json') '{"totalWords":7,"totalSessions":1,"totalSpeakingSeconds":3,"dailyWordCounts":{}}'
Set-Content (Join-Path $local 'models\placeholder.bin') 'x'
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (-not (Test-Path $run)) { New-Item -Path $run | Out-Null } # never -Force: it would wipe other startup entries
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name talkflow -Value "`"$exe`" --background" -Force | Out-Null

Run (Join-Path $app 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
Start-Sleep -Seconds 3 # the uninstaller finishes from a temporary copy
if (Test-Path $app) { throw "program folder still there: $app" }
if (Test-Path $local) { throw "local data still there: $local" }
if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).talkflow) { throw "startup entry still there" }
if (-not (Test-Path (Join-Path $data 'stats.json'))) { throw "user data was removed: $data" }
Write-Host "install/uninstall smoke test passed; $data kept"
