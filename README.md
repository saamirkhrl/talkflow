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

fn is the default. Settings > Shortcut switches it to another modifier key or
combination (Right Option, Right Command, Control + Option, or any you record).

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

## License

MIT
