# talkflow

Dictation for your Mac. Hold **fn**, speak, let go: your words are typed into
whatever text field you are in. No account needed.

![How talkflow works: hold fn, Whisper transcribes on your Mac, simple rules tidy the text, the words are typed into your app](docs/how-it-works.svg)

## Download

| Platform | Download |
|---|---|
| macOS (Apple Silicon) | [Download](https://talkflow.live/download/mac-apple-silicon) |
| macOS (Intel) | [Download](https://talkflow.live/download/mac-intel) |
| Windows | [Download](https://talkflow.live/download/windows) |

Requires macOS 13 or later, or Windows 10 (1809) or later.

The app is not notarized yet, so macOS asks you to confirm the first time you
open a downloaded copy.

**Build from source** (needs the Swift toolchain, `xcode-select --install`, and
`cmake` to build the speech engine: [cmake.org](https://cmake.org/download/),
`brew install cmake` or `pip3 install cmake`):

```bash
git clone https://github.com/saamirkhrl/talkflow.git
cd talkflow
./install.sh
```

## How it works

1. Hold **fn** and speak.
2. Let go of **fn**.
3. Your words are typed into the focused text field, once, when you release.

Nothing is typed while you speak, so nothing is ever deleted and retyped. This
is what makes it feel smooth. English only.

## First launch

Setup walks you through it:

1. Permissions: **Microphone** and **Accessibility**. Accessibility also lets
   talkflow notice the fn key, so it does not ask for Input Monitoring (and
   is not listed there).
2. It downloads the English model (about 500 MB) and starts the speech engine
   in the background. The engine (whisper.cpp's `whisper-server`) comes inside
   the app, at `talkflow.app/Contents/Helpers/whisper-server`, so Homebrew is
   not needed.

If an earlier talkflow set the engine up with Homebrew's `whisper-cpp`,
talkflow moves its background service onto the bundled engine the next time it
starts, keeping your model and settings. Homebrew's `whisper-cpp` stays
installed; `brew uninstall whisper-cpp` removes it if nothing else needs it.

## Privacy

- Speech is transcribed locally by Whisper (whisper.cpp) on your Mac.
- Optional: in Settings you can add your own OpenAI key (transcription) or
  Anthropic key (punctuation). That step then goes to that provider. It is off
  unless you add a key.
- The app checks GitHub for updates shortly after it starts (when you are
  online), every few hours while it runs, and when you open the dashboard. It
  downloads only the release's small manifest file (or asks the GitHub API,
  for older releases). A newer version shows in the menu bar menu and as one
  notification. Updates install only when you click, and not at all if the
  download does not match the release's sha256 checksum. See
  [docs/releases.md](docs/releases.md).
- Install count: the first time an official release runs while online, it
  sends one empty request to talkflow's website so installs can be counted.
  It sends no ID and nothing about you, your computer or your usage; the site
  stores only a running total. If it fails, it tries again next launch; once it
  succeeds, never again. Builds from source send nothing. See
  [docs/telemetry.md](docs/telemetry.md).
- Your data lives in one folder, `~/Library/Application Support/talkflow/`:
  `stats.json` for your stats, `settings.json` for your settings and learned
  words.

## Uninstall

In talkflow's **Settings**, scroll to **Uninstall talkflow** and click
**Uninstall...**. It removes the app
(the speech engine is inside it), the engine's background service, the speech
models, saved API keys, logs, caches, the login item and the app's
permissions. It does not touch Homebrew or anything installed with it.

Your data folder is kept, so reinstalling picks up where you left off. Delete
`~/Library/Application Support/talkflow/` for a completely fresh start.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Holding fn does nothing | Open **Setup...** from the menu bar; each step should show a green check. If Accessibility was just granted, press **Restart talkflow**. |
| The emoji picker or dictation opens when you press fn | System Settings > Keyboard > "Press the globe key to" > **Do Nothing**. |
| Words never appear | The speech engine may be down. `curl http://127.0.0.1:8178/` should answer. Log: `~/Library/Logs/TalkFlow/whisper-server.log`. Restart it with `launchctl kickstart -k gui/$(id -u)/com.samir.talkflow.whisperserver`. |
| Setup says the speech engine is missing from this copy of talkflow | The app is damaged or incomplete. Download talkflow again and replace the copy in Applications. |
| A permission is on but it still fails (often right after an update) | macOS is holding the permission for the previous copy. Open **Setup...** and press **Reset and allow again** on that step, or remove talkflow from that list in System Settings with **-**, add it again with **+** and switch it on. Why: [docs/signing.md](docs/signing.md). |

## Development

```bash
./deploy.sh   # release build, install to /Applications, re-sign, restart the LaunchAgent
```

The speech engine is built from a pinned whisper.cpp tag by
`scripts/build-whisper-macos.sh` (needs cmake; the result is cached in
`.build/whisper-engine`), which `release.sh`, `deploy.sh` and `install.sh` run.
`scripts/smoke-whisper-macos.sh` transcribes a test recording with it, and
`.github/workflows/macos-engine.yml` builds and checks it on Apple Silicon and
Intel.

Self-tests, run against the installed binary:

```bash
B=/Applications/talkflow.app/Contents/MacOS/talkflowd
$B --streamtest              # append-only streaming logic
$B --typetest                # the writing layer (takes focus)
$B --rectest 3               # mic capture and transcription round trip
$B --formattest "raw text"   # the text pipeline, no microphone
$B --dashboardshot           # render the dashboard to PNGs
$B --onboardingshot [dir]    # render every setup step to PNGs (fake permissions)
$B --enginecheck             # setup state: engine, model, permissions
$B --uninstallplan           # what Uninstall would remove, changes nothing
$B --focusprobe              # what the focused element accepts
$B --writetest [seconds]     # which write path the focused app accepts
$B --newlinetest [seconds]   # whether a newline sends a chat message
```

Source layout (`Sources/talkflowd/`):

| file | role |
|---|---|
| `Dictation.swift` | orchestrator: record, transcribe, format, write |
| `Recorder.swift` | mic to in-memory audio |
| `Transcriber.swift` | sends audio to the local whisper-server |
| `FieldWriter.swift` | Accessibility write, verified before it is believed |
| `LiveType.swift` | paced keystroke write |
| `TextCommands.swift`, `Cleanup.swift` | spoken punctuation, lists, filler removal |
| `Hotkey.swift` | fn key via CGEventTap |
| `Onboarding.swift`, `Permissions.swift` | first-run setup and permissions |
| `SpeechEngine.swift` | finds the bundled whisper-server, fetches the model, keeps its LaunchAgent pointed at it |
| `Preferences.swift`, `Vocabulary.swift` | settings and learned words |

The marketing site is a Next.js app in `client/`.

## Windows

The Windows app lives in `windows/` and is built by
`.github/workflows/windows.yml`, which attaches
`talkflow-windows-x64-setup.exe` to each release. There is one Windows build,
x64: it runs on every Windows 10 (1809) or later PC, Arm PCs included, through
Windows' built-in emulation.

- **Install:** run the installer. It installs for your account only, no
  administrator rights, to `%LOCALAPPDATA%\Programs\talkflow`. The installer is
  not code-signed yet, so Windows SmartScreen may say it "protected your PC":
  click **More info**, then **Run anyway**.
- **First launch:** setup opens and does the rest by itself. It downloads the
  English model (about 500 MB, once) in the background, keeps checking
  microphone access (Settings > Privacy & security > Microphone, including "Let
  desktop apps access your microphone") and, if it is off, opens that page for
  you, then starts the speech engine and gives you a box to try it in. Closing
  setup does not stop the download. The speech engine (whisper.cpp) ships in
  the installer.
- **Dictate:** hold **Ctrl + Win**, speak, let go. The shortcut can be changed
  in Settings. If focus moved to another app, or the app runs as administrator,
  the text goes to the clipboard instead.
- **Your data:** `%APPDATA%\talkflow\` holds `stats.json` and `settings.json`,
  in the same format as on the Mac, plus `windows.json` (your shortcut, and which update you were last told about). Models
  and logs are in `%LOCALAPPDATA%\talkflow\`.
- **Something wrong?** Tray menu > **Report a problem...** (also in
  Settings) saves a zip to your Desktop: the version, setup checks, settings
  switches and recent logs, without anything you dictated, your learned words
  or API keys. Attach it to an issue. `talkflow.exe --diagnostics` makes the
  same zip when the app will not start. `windows/TESTING.md` is the manual
  test checklist, including how to test in Windows Sandbox.
- **Uninstall:** Settings > **Uninstall...**, or Windows Settings > Apps >
  talkflow > Uninstall. Either removes the app, the speech engine, the models,
  logs, the startup entry and saved API keys, and keeps `%APPDATA%\talkflow\`.

Development: `dotnet test windows/Talkflow.Core.Tests` runs the text-rule tests
on any OS, including the Mac app's own outputs for 860 transcripts
(`windows/tools/make_golden.py` regenerates them). On Windows,
`talkflow.exe --formattest "raw text"` prints what a dictation would type.

## License

MIT
