# End-to-end test of the installed Windows app, as a person would use it:
# install, start, hold Ctrl + Win while "speaking", let go, and check that the
# words were typed. Runs on GitHub's Windows runners (x64 and Arm).
#
#   powershell -ExecutionPolicy Bypass -File windows\tests\e2e.ps1 `
#       -Installer dist\talkflow-windows-x64-setup.exe -Model ggml-tiny.en.bin -Wav jfk.wav -Out e2e-out
#
# A runner has no microphone, so the app plays the WAV in real time instead
# (TALKFLOW_TEST_AUDIO), and the shortcut is held with SendInput, which the
# app accepts only in this test (TALKFLOW_TEST_INJECTED_KEYS). See
# windows/Talkflow/TestHooks.cs.
#
# Three dictations:
#   1. into Notepad (another app), letting go of Win first;
#   2. into talkflow's own setup window, the "Try it" box, letting go of Ctrl
#      first (talkflow reading and typing into its own window);
#   3. into Notepad again with "type while speaking" on.
# Each one checks that the text arrived, that talkflow's windows kept
# answering (a stuck UI thread does not answer WM_NULL), that the pill was on
# screen while the keys were held and gone afterwards, that no key was left
# held down, that letting go did not open Start, and that talkflow.log has no
# STALL line (UiWatchdog.cs).
#
# Written for Windows PowerShell 5.1, which has UI Automation built in.
param(
    [Parameter(Mandatory)] [string] $Installer,
    [Parameter(Mandatory)] [string] $Model,
    [Parameter(Mandatory)] [string] $Wav,
    [Parameter(Mandatory)] [string] $Out,
    [string] $Expect = 'ask not what your country'
)
$ErrorActionPreference = 'Stop'
$Out = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force $Out | Out-Null
Start-Transcript -Path (Join-Path $Out 'e2e.log') | Out-Null

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'E2eNative.cs') -ReferencedAssemblies System.Windows.Forms, System.Drawing
$UIA = [System.Windows.Automation.AutomationElement]
$Tree = [System.Windows.Automation.TreeScope]

$app = Join-Path $env:LOCALAPPDATA 'Programs\talkflow'
$exe = Join-Path $app 'talkflow.exe'
$logs = Join-Path $env:LOCALAPPDATA 'talkflow\logs'
$appLog = Join-Path $logs 'talkflow.log'
$data = Join-Path $env:APPDATA 'talkflow'
$work = Join-Path $Out 'files'
New-Item -ItemType Directory -Force $work | Out-Null

$failures = New-Object System.Collections.Generic.List[string]
$results = New-Object System.Collections.Generic.List[string]
function Say($text) { Write-Host ("[{0:HH:mm:ss.fff}] {1}" -f (Get-Date), $text) }
function Fail($text) { Say "FAIL: $text"; $failures.Add($text) }

function LogLines {
    if (Test-Path $appLog) { return @(Get-Content $appLog) } else { return @() }
}

# (The parameter is not called $condition: the scripts it runs use that name.)
function WaitFor([scriptblock] $until, [int] $seconds, [string] $what) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $until) { return $true }
        Start-Sleep -Milliseconds 250
    }
    Say "timed out after $seconds s waiting for $what"
    return $false
}

function Talkflow { Get-Process talkflow -ErrorAction SilentlyContinue | Select-Object -First 1 }

function StartTalkflow {
    $before = (LogLines | Where-Object { $_ -match 'speech engine ready|speech engine is not running' }).Count
    Start-Process -FilePath $exe -ArgumentList '--background' | Out-Null
    $ok = WaitFor { (LogLines | Where-Object { $_ -match 'speech engine ready|speech engine is not running' }).Count -gt $before } 180 'the speech engine'
    $line = LogLines | Where-Object { $_ -match 'speech engine ready|speech engine is not running' } | Select-Object -Last 1
    Say "talkflow: $line"
    if (-not $ok -or $line -notmatch 'speech engine ready') { throw "the speech engine did not start: $line" }
}

function StopTalkflow {
    Get-Process talkflow, whisper-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

# The text of the first edit control under a window: WM_GETTEXT first, which
# works for both Notepads, then UI Automation.
function ReadText($hwnd) {
    $direct = [E2e]::ChildText($hwnd)
    if ($null -ne $direct) { return $direct }
    $window = $UIA::FromHandle($hwnd)
    foreach ($type in [System.Windows.Automation.ControlType]::Document, [System.Windows.Automation.ControlType]::Edit) {
        $condition = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $type)
        $element = $window.FindFirst($Tree::Descendants, $condition)
        if ($null -eq $element) { continue }
        $pattern = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref] $pattern)) {
            return $pattern.DocumentRange.GetText(-1)
        }
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $pattern)) {
            return $pattern.Current.Value
        }
    }
    return $null
}

# Windows 11 runners sometimes open a "Microsoft account" sign-in prompt
# (WWAHost) and then the Search flyout (SearchHost), before anything is
# pressed; either takes the foreground. The prompt is closed; shell flyouts
# (Search, Start) cannot be pushed behind with SetForegroundWindow, but close
# on Escape.
function CloseIntruders {
    $intruders = Get-Process WWAHost -ErrorAction SilentlyContinue
    if ($intruders) {
        Say "closing a sign-in prompt that holds the foreground (WWAHost, pid $($intruders.Id -join ', '))"
        $intruders | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
    # The Arm runner can open a "WSL must be updated" prompt by itself, which
    # then takes the foreground in the middle of a dictation.
    $wsl = Get-Process wsl, wslhost -ErrorAction SilentlyContinue
    if ($wsl) {
        Say "closing a WSL prompt the runner opened (pid $($wsl.Id -join ', '))"
        $wsl | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
    for ($i = 0; $i -lt 5; $i++) {
        $front = [E2e]::GetForegroundWindow()
        $owner = Get-Process -Id ([E2e]::ProcessOf($front)) -ErrorAction SilentlyContinue
        if ($null -eq $owner -or $owner.ProcessName -notin 'SearchHost', 'SearchApp', 'StartMenuExperienceHost', 'ShellExperienceHost') { return }
        Say "closing a shell flyout that holds the foreground: $([E2e]::Describe($front))"
        [void][E2e]::Press([E2e]::VK_ESCAPE, $false); [void][E2e]::Press([E2e]::VK_ESCAPE, $true)
        Start-Sleep -Seconds 1
    }
}

function OverlayVisible($process) {
    foreach ($hwnd in [E2e]::VisibleWindows($process.Id)) {
        if ([E2e]::IsTopmostToolWindow($hwnd)) { return $true }
    }
    return $false
}

function OpenNotepad($name) {
    $file = Join-Path $work "$name.txt"
    Set-Content -Path $file -Value '' -NoNewline
    Start-Process notepad.exe -ArgumentList "`"$file`"" | Out-Null
    $script:hwnd = [IntPtr]::Zero
    if (-not (WaitFor { $script:hwnd = [E2e]::FindWindow($name); $script:hwnd -ne [IntPtr]::Zero } 30 "Notepad with $name")) {
        throw "Notepad did not open $file"
    }
    Start-Sleep -Seconds 1
    return $script:hwnd
}

# Holds Ctrl + Win for the WAV's length, then lets go in the given order,
# watching talkflow the whole time. Then waits for the text to arrive.
function Dictate([string] $label, [IntPtr] $hwnd, [scriptblock] $read, [string] $releaseFirst) {
    Say "=== $label ==="
    CloseIntruders
    Write-Host "visible windows:"; Write-Host ([E2e]::ListWindows())
    $process = Talkflow
    if ($null -eq $process) { Fail "${label}: talkflow is not running"; return }
    if (-not [E2e]::Focus($hwnd)) {
        Say "could not bring $([E2e]::Describe($hwnd)) to the front; in front: $([E2e]::Describe([E2e]::GetForegroundWindow()))"
        CloseIntruders
        if (-not [E2e]::Focus($hwnd)) { Fail "${label}: could not bring the target window to the front"; return }
    }
    Say "foreground: $([E2e]::Describe([E2e]::GetForegroundWindow()))"
    $logStart = (LogLines).Count
    $holdSeconds = [Math]::Ceiling($script:wavSeconds) + 1.5
    $slowest = 0; $unanswered = 0; $overlaySeen = $false

    [void][E2e]::Press([E2e]::VK_LCONTROL, $false)
    Start-Sleep -Milliseconds 60
    $sent = [E2e]::Press([E2e]::VK_LWIN, $false)
    Say "holding Ctrl + Win (SendInput accepted $sent) for $holdSeconds s"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $shot = $false
    while ($watch.Elapsed.TotalSeconds -lt $holdSeconds) {
        $answer = [E2e]::SlowestAnswer($process.Id, 5000)
        if ($answer -eq -1) { $unanswered++ } elseif ($answer -gt $slowest) { $slowest = $answer }
        if (OverlayVisible $process) { $overlaySeen = $true }
        if (-not $shot -and $watch.Elapsed.TotalSeconds -gt 4) {
            [E2e]::Screenshot((Join-Path $Out "$label-holding.png")); $shot = $true
        }
        Start-Sleep -Milliseconds 200
    }
    if ($releaseFirst -eq 'ctrl') {
        [void][E2e]::Press([E2e]::VK_LCONTROL, $true); Start-Sleep -Milliseconds 60; [void][E2e]::Press([E2e]::VK_LWIN, $true)
    } else {
        [void][E2e]::Press([E2e]::VK_LWIN, $true); Start-Sleep -Milliseconds 60; [void][E2e]::Press([E2e]::VK_LCONTROL, $true)
    }
    Say "released ($releaseFirst first)"
    Start-Sleep -Milliseconds 800
    # Letting go of Win alone opens Start; talkflow must prevent that.
    $front = [E2e]::GetForegroundWindow()
    $startOpened = $front -ne $hwnd
    if ($startOpened) { Say "in front after release: $([E2e]::Describe($front))" }

    $script:text = $null
    $arrived = WaitFor {
        $answer = [E2e]::SlowestAnswer($process.Id, 5000)
        if ($answer -eq -1) { $script:unansweredAfter++ } elseif ($answer -gt $script:slowestAfter) { $script:slowestAfter = $answer }
        $script:text = & $read
        $script:text -match $Expect
    } 60 "the dictation in $label"
    Start-Sleep -Seconds 1
    $script:text = & $read
    [E2e]::Screenshot((Join-Path $Out "$label-after.png"))
    $overlayAfter = OverlayVisible $process
    if ($overlayAfter) { Start-Sleep -Seconds 5; $overlayAfter = OverlayVisible $process }

    $newLines = @(LogLines | Select-Object -Skip $logStart)
    $stalls = @($newLines | Where-Object { $_ -match 'STALL' })
    $stuck = @([E2e]::VK_LWIN, [E2e]::VK_LCONTROL) | Where-Object { [E2e]::IsDown($_) }

    Say "text now: [$($script:text)]"
    Say "foreground now: $([E2e]::Describe([E2e]::GetForegroundWindow()))"
    Write-Host "visible windows:"; Write-Host ([E2e]::ListWindows())
    Say "slowest window answer while holding: $slowest ms ($unanswered probes unanswered within 5 s); after: $($script:slowestAfter) ms ($($script:unansweredAfter) unanswered)"
    Say "pill seen while holding: $overlaySeen; still visible 5 s after: $overlayAfter"
    Say "talkflow.log during this dictation:"
    $newLines | ForEach-Object { Write-Host "    $_" }

    if (-not $arrived) { Fail "${label}: the dictation never arrived (expected '$Expect')" }
    if ($unanswered -gt 0 -or $script:unansweredAfter -gt 0) { Fail "${label}: talkflow's windows stopped answering ($unanswered while holding, $($script:unansweredAfter) after)" }
    if ($stalls.Count -gt 0) { Fail "${label}: talkflow.log reports $($stalls.Count) UI stall line(s)" }
    if (-not $overlaySeen) { Fail "${label}: the pill was never on screen while the keys were held" }
    if ($overlayAfter) { Fail "${label}: the pill was still on screen after the dictation" }
    if ($stuck) { Fail "${label}: keys still logically down after release: $($stuck -join ', ')" }
    if ($startOpened) { Fail "${label}: another window (the Start menu?) came to the front when the keys were released" }
    $results.Add(("{0}: arrived={1} slowest-answer={2}ms/{3}ms stalls={4} pill={5}" -f $label, $arrived, $slowest, $script:slowestAfter, $stalls.Count, $overlaySeen))
}

try {
    Say ([E2e]::Session())
    Say "OS: $([Environment]::OSVersion.VersionString), $env:PROCESSOR_ARCHITECTURE, $([Environment]::ProcessorCount) logical processors"

    # The audio the app will "hear".
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $Wav))
    $script:wavSeconds = ($bytes.Length - 44) / 32000.0
    Say ("test audio: {0} ({1:F1} s)" -f $Wav, $script:wavSeconds)

    Say "installing $Installer"
    $p = Start-Process -FilePath $Installer -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "installer exited with $($p.ExitCode)" }

    # Settings a person would have after setup. The accurate final pass is
    # off so the test does not download the 574 MB large model.
    New-Item -ItemType Directory -Force $data | Out-Null
    Set-Content -Path (Join-Path $data 'settings.json') -Value '{ "accurateFinalPass": false, "typeWhileSpeaking": false }'

    $env:TALKFLOW_TEST_AUDIO = (Resolve-Path $Wav).Path
    $env:TALKFLOW_TEST_INJECTED_KEYS = '1'
    $env:TALKFLOW_TEST_MODEL = (Resolve-Path $Model).Path
    $env:TALKFLOW_LOG_TRANSCRIPTS = '1' # the test's own recording, so the log may show it

    CloseIntruders
    # Control: the same kind of keystrokes talkflow sends (Unicode, 16 per
    # SendInput call), typed by this script with talkflow not running. If
    # this already comes out wrong, the app being typed into is the cause.
    $control = OpenNotepad 'control'
    if ([E2e]::Focus($control)) {
        $sentence = 'And so my fellow Americans, ask not what your country can do for you.'
        [E2e]::TypeUnicode($sentence, 16, 4)
        Start-Sleep -Seconds 1
        $typed = ReadText $control
        Say "control: typed [$sentence] with no talkflow; Notepad has [$typed]"
        $results.Add("control: $(if ($typed -eq $sentence) { 'Notepad received the keystrokes exactly' } else { 'Notepad changed the keystrokes: [' + $typed + ']' })")
    }

    StartTalkflow
    $script:slowestAfter = 0; $script:unansweredAfter = 0

    # 1. Notepad.
    $note1 = OpenNotepad 'pass1'
    Dictate 'notepad' $note1 { ReadText $note1 } 'win'

    # 2. talkflow's own setup window, the "Try it" box.
    $script:slowestAfter = 0; $script:unansweredAfter = 0
    Start-Process -FilePath $exe -ArgumentList '--setup' | Out-Null
    $setup = [IntPtr]::Zero
    if (WaitFor { $script:setupHwnd = [E2e]::FindWindow('talkflow setup'); $script:setupHwnd -ne [IntPtr]::Zero } 20 'the setup window') {
        $setup = $script:setupHwnd
        [void][E2e]::Focus($setup)
        $condition = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
        $script:tryIt = $null
        [void](WaitFor { $script:tryIt = $UIA::FromHandle($setup).FindFirst($Tree::Descendants, $condition); $null -ne $script:tryIt -and $script:tryIt.Current.IsEnabled } 30 'the Try it box to be enabled')
        if ($null -eq $script:tryIt) { Fail 'try-it: no Try it box in the setup window' }
        else {
            $script:tryIt.SetFocus()
            Start-Sleep -Milliseconds 500
            Dictate 'try-it' $setup { $script:tryIt.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } 'ctrl'
        }
    } else {
        Fail 'try-it: talkflow.exe --setup did not open the setup window'
    }

    # 3. Type while speaking, into Notepad.
    StopTalkflow
    Set-Content -Path (Join-Path $data 'settings.json') -Value '{ "accurateFinalPass": false, "typeWhileSpeaking": true }'
    StartTalkflow
    $script:slowestAfter = 0; $script:unansweredAfter = 0
    $note3 = OpenNotepad 'pass3'
    Dictate 'type-while-speaking' $note3 { ReadText $note3 } 'win'
}
catch {
    Fail "error: $($_.Exception.Message)"
    Say $_.ScriptStackTrace
    try { [E2e]::Screenshot((Join-Path $Out 'error.png')) } catch { }
}
finally {
    StopTalkflow
    Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path $logs) { Copy-Item (Join-Path $logs '*') $Out -Force }
    Get-ChildItem $env:TEMP -Filter 'talkflow-*.txt' -ErrorAction SilentlyContinue | Copy-Item -Destination $Out -Force
    Say "=== summary ==="
    $results | ForEach-Object { Say $_ }
    if ($failures.Count -gt 0) {
        Say "$($failures.Count) failure(s):"
        $failures | ForEach-Object { Say "  - $_" }
    } else {
        Say 'all end-to-end checks passed'
    }
    Stop-Transcript | Out-Null
}
if ($failures.Count -gt 0) { exit 1 }
