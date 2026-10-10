<div align="center">

<img src="client/app/icon.svg" alt="talkflow" width="96" height="96">

# talkflow

**Free, open-source dictation that runs on your own computer.**<br>
Hold <kbd>fn</kbd>, speak, let go. Your words are typed into whatever app you're in.

[![Latest release](https://img.shields.io/github/v/release/saamirkhrl/talkflow?label=release&color=1f1e22)](https://github.com/saamirkhrl/talkflow/releases/latest)
[![License: MIT](https://img.shields.io/github/license/saamirkhrl/talkflow?color=1f1e22)](LICENSE)
[![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-1f1e22)](#download)
[![GitHub stars](https://img.shields.io/github/stars/saamirkhrl/talkflow?style=flat&color=1f1e22)](https://github.com/saamirkhrl/talkflow/stargazers)
![Visits](https://visitor-badge.laobi.icu/badge?page_id=saamirkhrl.talkflow&left_text=visits&left_color=%231f1e22)

[Website](https://talkflow.live) · [Download](#download) · [Report a bug](https://github.com/saamirkhrl/talkflow/issues/new) · [Security](SECURITY.md)

</div>

<p align="center">
<a href="https://www.star-history.com/#saamirkhrl/talkflow&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=saamirkhrl/talkflow&type=Date&theme=dark">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=saamirkhrl/talkflow&type=Date">
    <img alt="Star history chart for saamirkhrl/talkflow" src="https://api.star-history.com/svg?repos=saamirkhrl/talkflow&type=Date">
  </picture>
</a>
</p>

<br>

![How talkflow works: hold fn, Whisper transcribes on your Mac, simple rules tidy the text, the words are typed into your app](docs/how-it-works.svg)

## Contents

- [Features](#features)
- [Download](#download)
- [How it works](#how-it-works)
- [First launch](#first-launch)
- [Privacy](#privacy)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Works in every app.** Text lands in the focused field, whether that's a chat, an email, a terminal or a document.
- **Private by design.** Speech is recognized by Whisper ([whisper.cpp](https://github.com/ggml-org/whisper.cpp)) on your own processor. It works with Wi-Fi off.
- **Free, with no account.** No sign-up, no subscription and no word limit.
- **Clean text.** Spoken punctuation, lists and filler-word removal are handled for you.
- **Learns your words.** Names and terms you correct are remembered.
- **Your shortcut.** <kbd>fn</kbd> by default, or any modifier key or combination you record.
- **A dashboard.** Words dictated, speaking speed, your daily streak and the typing time you've saved.

## Download

| Platform | Download |
|---|---|
| macOS (Apple Silicon) | [Download](https://talkflow.live/download/mac-apple-silicon) |
| macOS (Intel) | [Download](https://talkflow.live/download/mac-intel) |
| Windows (x64, runs on Arm too) | [Download](https://talkflow.live/download/windows-x64) |

**Requirements:** macOS 13 or later, or Windows 10 (1809) or later. The speech model needs about 200 MB of disk space, plus about 575 MB for the more accurate final-pass model, which downloads in the background on Macs with more than 8 GB of memory.

### Build from source

You need the Swift toolchain (`xcode-select --install`) and `cmake` to build the speech engine ([cmake.org](https://cmake.org/download/), `brew install cmake` or `pip3 install cmake`).

```bash
git clone https://github.com/saamirkhrl/talkflow.git
cd talkflow
./install.sh
```

## How it works

1. Hold <kbd>fn</kbd> and speak.
2. Let go of <kbd>fn</kbd>.
3. Your words are typed into the focused text field, once, when you release.

Nothing is typed while you speak, so nothing is ever deleted and retyped. That's what makes it feel smooth. English only for now.

To use a different shortcut, open **Settings > Shortcut** and pick Right Option, Right Command, Control + Option, or record your own.

## First launch

Setup walks you through it:

1. **Permissions:** Microphone and Accessibility. Accessibility also lets talkflow notice the <kbd>fn</kbd> key, so it doesn't ask for Input Monitoring (and isn't listed there).
2. **Speech engine:** it downloads the English model (about 190 MB) and starts the engine in the background. The engine (whisper.cpp's `whisper-server`) ships inside the app at `talkflow.app/Contents/Helpers/whisper-server`, so Homebrew isn't needed.

<details>
<summary>Upgrading from a Homebrew-based install</summary>

If an earlier talkflow set the engine up with Homebrew's `whisper-cpp`, talkflow moves its background service onto the bundled engine the next time it starts, keeping your model and settings. Homebrew's `whisper-cpp` stays installed; `brew uninstall whisper-cpp` removes it if nothing else needs it.

</details>

## Privacy

- **Speech stays on your Mac.** It is transcribed locally by Whisper. Audio is held in memory and never written to disk.
- **Optional cloud keys.** In Settings you can add your own OpenAI key (transcription) or Anthropic key (punctuation). That step then goes to that provider. It's off unless you add a key.
- **Update checks.** The app checks GitHub for updates shortly after it starts (when you're online), every few hours while it runs, and when you open the dashboard. It downloads only the release's small manifest file. Updates install only when you click, and only if the download matches the release's sha256 checksum. See [docs/releases.md](docs/releases.md).
- **Install count.** The first time an official release runs while online, it sends one empty request so installs can be counted. It sends no ID and nothing about you, your computer or your usage, and once it succeeds it never sends again. Builds from source send nothing. See [docs/telemetry.md](docs/telemetry.md).
- **Your data** lives in one folder, `~/Library/Application Support/talkflow/`: `stats.json` for your stats and `settings.json` for your settings and learned words.

## Uninstall

In talkflow's **Settings**, scroll to **Uninstall talkflow** and click **Uninstall...**. It removes the app (the speech engine is inside it), the engine's background service, the speech models, saved API keys, logs, caches, the login item and the app's permissions. It doesn't touch Homebrew or anything installed with it.

Your data folder is kept, so reinstalling picks up where you left off. Delete `~/Library/Application Support/talkflow/` for a completely fresh start.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Holding fn does nothing | Open **Setup...** from the menu bar; each step should show a green check. If Accessibility was just granted, press **Restart talkflow**. |
| The emoji picker or dictation opens when you press fn | System Settings > Keyboard > "Press the globe key to" > **Do Nothing**. |
| Words never appear | The speech engine may be down. `curl http://127.0.0.1:8178/` should answer. Log: `~/Library/Logs/TalkFlow/whisper-server.log`. Restart it with `launchctl kickstart -k gui/$(id -u)/com.samir.talkflow.whisperserver`. |
| Setup says the speech engine is missing | The app is damaged or incomplete. Download talkflow again and replace the copy in Applications. |
| A permission is on but it still fails (often right after an update) | macOS is holding the permission for the previous copy. Open **Setup...** and press **Reset and allow again** on that step, or remove talkflow from that list in System Settings with **-**, add it again with **+** and switch it on. Why: [docs/signing.md](docs/signing.md). |

Still stuck? [Open an issue](https://github.com/saamirkhrl/talkflow/issues/new) with your macOS version and what you tried.

## Contributing

Bug reports, ideas and pull requests are welcome.

- **Bugs and ideas:** [open an issue](https://github.com/saamirkhrl/talkflow/issues). Include your OS version and steps to reproduce.
- **Pull requests:** keep each one focused on a single change, and describe how you tested it.
- **Security issues:** please don't file a public issue. See [SECURITY.md](SECURITY.md) for private reporting.

## License

talkflow is released under the [MIT License](LICENSE).
