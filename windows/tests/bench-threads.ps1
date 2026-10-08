# Times whisper-server's CPU path with the old thread count (logical
# processors - 1) against the new one (physical cores, DevicePolicy.Threads),
# on the same clip, on this machine. Informational: it prints a table (and
# adds it to the job summary) and never fails the build, because a shared CI
# runner is too noisy to gate on.
#
#   pwsh windows/tests/bench-threads.ps1 -EngineDir dl/engine -Model ggml-tiny.en.bin -Wav dl/jfk.wav
param(
    [Parameter(Mandatory)] [string] $EngineDir,
    [Parameter(Mandatory)] [string] $Model,
    [Parameter(Mandatory)] [string] $Wav,
    [int] $Rounds = 5
)
$ErrorActionPreference = 'Stop'

$server = Join-Path $EngineDir 'whisper-server.exe'
$logical = [Environment]::ProcessorCount
$cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
# DevicePolicy.Threads: the cores, one fewer on a chip with more than four.
$new = [Math]::Min(8, [Math]::Max(1, $(if ($cores -gt 4) { $cores - 1 } else { $cores })))
$old = [Math]::Min(8, [Math]::Max(1, $logical - 1))
Write-Host "logical processors: $logical, physical cores: $cores; old thread count: $old, new: $new"

function Measure-Threads([int] $threads, [int] $port) {
    $log = Join-Path $env:RUNNER_TEMP "bench-$port.log"
    $process = Start-Process -FilePath $server -ArgumentList @('-m', $Model, '--host', '127.0.0.1', '--port', $port, '-nt', '-t', $threads, '-ng') `
        -RedirectStandardError $log -RedirectStandardOutput "$log.out" -PassThru -NoNewWindow
    try {
        foreach ($i in 1..120) {
            try { Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 500 }
        }
        $times = @()
        foreach ($round in 0..$Rounds) {
            $seconds = & curl.exe -s -o NUL -w '%{time_total}' -F "file=@$Wav" -F 'response_format=text' "http://127.0.0.1:$port/inference"
            if ($round -gt 0) { $times += [double]::Parse($seconds, [Globalization.CultureInfo]::InvariantCulture) } # the first run loads lazily
        }
        $sorted = $times | Sort-Object
        return $sorted[[int]($sorted.Count / 2)]
    }
    finally {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
}

# Interleaved, so a noisy minute hits both.
$oldTimes = @(); $newTimes = @()
foreach ($pass in 1..2) {
    $oldTimes += Measure-Threads $old 8190
    $newTimes += Measure-Threads $new 8191
}
$oldMedian = ($oldTimes | Sort-Object)[0]
$newMedian = ($newTimes | Sort-Object)[0]
$table = @(
    '| threads | value | best median of 2 passes (s) |',
    '|---|---|---|',
    "| old: logical - 1 | $old | $('{0:F2}' -f $oldMedian) |",
    "| new: physical cores | $new | $('{0:F2}' -f $newMedian) |"
) -join "`n"
Write-Host $table
if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY "### whisper-server CPU threads ($logical logical, $cores cores, tiny.en, one clip)`n$table" }
