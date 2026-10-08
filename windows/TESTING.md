# Testing talkflow on a Windows PC

CI already installs every build and dictates with it on x64
(`windows/tests/e2e.ps1`, the `e2e` job in `.github/workflows/windows.yml`).
CI runners have no microphone, no Bluetooth headset and no real user, though,
so these checks need a person and a real PC.

## Get a build

- A release: <https://talkflow.live/download/windows>, or the
  `talkflow-windows-<arch>-setup.exe` assets on GitHub Releases.
- A pull request build: open the PR's **Windows** check, then **Summary**,
  then download `installer-x64` (it runs on Arm PCs too). It is a
  zip with the installer inside. These builds say "dev build" and a commit in
  the dashboard instead of a version number.

## Optional: test in Windows Sandbox (keeps your PC clean)

Windows Sandbox is a throwaway copy of Windows that is wiped when you close
it. It needs Windows 10/11 **Pro, Enterprise or Education** with
virtualization on.

1. Start > "Turn Windows features on or off" > tick **Windows Sandbox** >
   OK, then restart.
2. Put the installer in a folder, for example `C:\talkflow-test`.
3. Save this as `talkflow.wsb` next to it (edit the folder path), then
   double-click it:

   ```xml
   <Configuration>
     <AudioInput>Enable</AudioInput>
     <MappedFolders>
       <MappedFolder>
         <HostFolder>C:\talkflow-test</HostFolder>
         <SandboxFolder>C:\talkflow-test</SandboxFolder>
         <ReadOnly>false</ReadOnly>
       </MappedFolder>
     </MappedFolders>
   </Configuration>
   ```

4. Inside the Sandbox, run the installer from `C:\talkflow-test`. The
   microphone is shared with the Sandbox (Windows may ask once). Diagnostics
   saved to the Sandbox's Desktop can be copied to `C:\talkflow-test` to keep
   them.

Sandbox is a fresh Windows with nothing else installed, so it is good for
"first install" checks. Keep a run on your own PC for things that depend on
your setup: your microphone or headset, your other apps, Start with Windows.

## Checklist

Write down the result of each step. If one fails, use **Report a problem...**
in the tray menu (or Settings) right away and attach the zip it saves to your
Desktop. It has no dictated text.

1. Install. Setup opens. Microphone shows a check (if not, follow its
   button), the speech engine says "Installed", and the model offers its
   download.
2. Download the model. The bar moves, then the engine step says "Running".
   If it shows an error instead, note the exact words.
3. In setup, click the **Try it** box, hold **Ctrl + Win**, say a sentence,
   let go. While holding, the pill at the bottom of the screen shows bars that
   move with your voice and, after a second or two, your words above it. On
   release, the words appear in the box. Setup must keep responding (you can
   drag the window) the whole time.
4. Open Notepad, click in it, and do the same. Then do it in your browser and
   one chat app.
5. Let go of **Win** first one time and **Ctrl** first another time. The
   Start menu must not open, and afterwards normal typing must work: no key
   behaves as if Ctrl or Win were still held.
6. With a Bluetooth or USB headset as the default microphone, dictate once.
   The pill appears at once (it may take a moment for bars to move while the
   headset switches); talkflow never stops responding.
7. Hold the shortcut for about a minute and speak continuously. The text
   arrives within a few seconds of letting go.
8. Settings > **Type while speaking** on. Dictate into Notepad: words appear
   as you speak, and the final text is correct after you let go.
9. Lock the PC with **Win + L**, sign back in, then press **Ctrl** alone a
   few times and type a little. No dictation pill should appear.
10. Quit talkflow from the tray, then end `whisper-server.exe` in Task Manager
    and start talkflow again: it should start the engine itself. With
    talkflow running, end `whisper-server.exe` and dictate: the pill should
    say the engine stopped and is starting again, and the next dictation
    works.
11. The dashboard header shows the version (or "dev build ..."). Click the
    update link: it ends within a few seconds in "Up to date", "<version> has
    no Windows build yet", an update button, or an error with Retry. It never
    stays on "Checking...".
12. Tray > **Report a problem...**: a zip appears on the Desktop and Explorer
    shows it. Open it: `report.txt`, `talkflow.log` and the engine logs. Search
    them for a sentence you dictated; it must not be there.
13. Restart Windows with "Start talkflow when I sign in" on: talkflow is in
    the notification area, and dictation works without opening anything.
14. Settings > **Uninstall...**: the app, models and logs are gone,
    `%APPDATA%\talkflow` is kept.
15. **First press after a pause.** Dictate once, wait a full minute without
    touching the shortcut, then hold it. If the microphone is slow to open (an
    Intel Smart Sound array, a Bluetooth headset) the pill shows a grey dot and
    "Starting microphone..." until sound is flowing, then the dot turns red:
    wait for it, then speak. The first words must be in the text. A second hold
    within two minutes shows no "starting" line (the microphone is still open;
    Windows shows its microphone-in-use icon meanwhile, and drops it about two
    minutes after the last hold on a slow-opening microphone, four seconds on a
    fast one).
16. **A 0.4 s hold.** Tap-and-hold the shortcut for under half a second right
    after a pause (a cold microphone). The pill must say "Hold the shortcut a
    moment longer, the microphone was still starting." and must not send you to
    Sound settings. Nothing is typed.
17. **A hold with no speech.** Hold for three seconds and say nothing. Within a
    moment the pill says "Didn't catch that" (not an error, red), and nothing
    is typed. Tray > Report a problem: the log line for the hold says "too
    quiet to be speech", with no "transcribed" line after it.
18. **A slow PC** (an integrated-graphics laptop, a small.en 1 s clip over 0.8
    s in `report.txt` under "measured here"). Settings > Accurate final pass
    says "Not used on this PC" with the reason; `ggml-large-v3-turbo-q5_0.bin`
    is never downloaded to `%LOCALAPPDATA%\talkflow\models`; Task Manager shows
    one `whisper-server.exe`, not two; the Models card shows the live caption
    as off; the text appears about a second plus the dictation's length after
    letting go. Restart talkflow: the log says the speed was "not measured
    again", and no model is downloaded, started or timed. Dictate during the
    first minute after launch: no slowdown from a model starting.
19. **Diagnostics on a PC with a flaky audio driver.** Report a problem and
    open `report.txt`: every microphone endpoint is listed by number, a bad one
    says what could not be read instead of hiding the others, and "speed on this
    PC" has the thread count, the speed tests, the final-pass verdict, the
    microphone keep-open time and the last holds' decisions.
