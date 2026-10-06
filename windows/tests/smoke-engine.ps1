# Starts a built whisper-server.exe with a small model and transcribes a real
# speech sample through the same /inference endpoint talkflow uses. Proves the
# shipped engine runs on this architecture with only the DLLs next to it.
#
#   pwsh windows/tests/smoke-engine.ps1 -EngineDir out\engine -Model ggml-tiny.en.bin -Wav jfk.wav
param(
    [Parameter(Mandatory)] [string] $EngineDir,
    [Parameter(Mandatory)] [string] $Model,
    [Parameter(Mandatory)] [string] $Wav,
    [int] $Port = 8199
)
$ErrorActionPreference = 'Stop'

$server = Join-Path $EngineDir 'whisper-server.exe'
if (-not (Test-Path $server)) { throw "missing $server" }
Get-ChildItem $EngineDir | Format-Table Name, Length

$log = Join-Path $env:RUNNER_TEMP "whisper-server-$Port.log"
$process = Start-Process -FilePath $server -ArgumentList @('-m', $Model, '--host', '127.0.0.1', '--port', $Port, '-nt') `
    -RedirectStandardError $log -RedirectStandardOutput "$log.out" -PassThru -NoNewWindow
try {
    $up = $false
    foreach ($i in 1..120) {
        if ($process.HasExited) { break }
        try { Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 2 | Out-Null; $up = $true; break } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $up) {
        Get-Content $log, "$log.out" -ErrorAction SilentlyContinue
        throw "whisper-server did not answer (exit code: $($process.ExitCode))"
    }
    $text = & curl.exe -s -F "file=@$Wav" -F "response_format=text" -F "prompt=I use talkflow, a dictation app." "http://127.0.0.1:$Port/inference"
    Write-Host "transcript: $text"
    if ($text -notmatch '(?i)ask not what your country') { throw "unexpected transcript" }
    Write-Host "engine smoke test passed"
}
finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
