# talkflow

macOS dictation. Hold **Fn**, speak, the words appear in whatever text field you
are typing in. Local transcription, no cloud, no account.

Works in native apps, Electron apps (Cursor, Discord, Claude) and terminals,
because it can write either through the Accessibility API or as paced synthetic
keystrokes, and it checks which one an app actually honours rather than
assuming. See [Known limitations](#known-limitations) for what has and has not
been tested.

## How it works

![How talkflow works: hold Fn, Whisper transcribes on your Mac, simple rules tidy the text, settled words are typed into your app](docs/how-it-works.svg)

Speech is transcribed by Whisper, running locally in `whisper-server`:
`ggml-small.en` while you speak, and `large-v3-turbo` for the final text when it
is installed (it downloads once, 574 MB, and is optional). It supplies most of
the capitalisation and punctuation itself; everything after it is plain rules.
Its prompt carries your name, names visible on screen around the caret, and
spellings talkflow has learned from your fixes.

```
Fn held -> mic -> in-memory PCM -> whisper-server small.en (local, warm)
        -> every 0.7s: transcribe the whole buffer so far
        -> show it in the caption above the pill (settled words solid)
        -> in the background: read names and the text before the caret
Fn released -> final transcript (large-v3-turbo, else small.en)
            -> rules: corrections, lists, email breaks, casing for where it lands
            -> optional: AI punctuation (on-device, never changes a word)
            -> one write into the focused field
```

**Insert once, at release.** Nothing is typed while you speak, so nothing on
screen is ever deleted and retyped, and every correction is free - the false
start in "meet at 2, no wait, 3" never reaches the field. This is how Wispr Flow
feels smooth. The write is one verified Accessibility call where the app allows
it, else one paced keystroke insert (no deletes, so nothing can be lost; the
clipboard is never touched). If the app you were in lost focus, the text goes
to the clipboard instead of being dropped.

**Fitted to where it lands.** Mid-sentence, the first word is lowercased (not
"I", acronyms or names). In chat apps a one-sentence message drops its final
period. Names on screen and learned words go into Whisper's prompt: measured on
"Can Niamh and Saoirse join us", small.en alone wrote "Neevan Sersha" and
large-v3-turbo with the on-screen names wrote both correctly.

**Learning from your fixes.** When you correct a word Whisper misspelled (a
word the macOS dictionary does not know, replaced between the same two
neighbours), the spelling is learned. Settings lists learned words; click one
to remove it.

**Type while speaking (Settings).** The original live mode, described in the
next two paragraphs, is still there for anyone who wants text in the field as
they talk.

**Live typing is append-only.** Whisper revises what it already said as more
audio arrives ("to" becomes "two", punctuation slides), so typing each new
transcript in full meant deleting and retyping text several times a second.
Instead a word is released only once two consecutive transcripts agree on it
and another word sits behind it - LocalAgreement-2, the standard streaming-ASR
approach. Committed words are never taken back, so the only edit a live update
can make is an append. Corrections are deferred to a single pass when the key
is released, which is also where email paragraph breaks are decided.

**A correction is never worth losing words for.** The pass at release does two
jobs, and they carry opposite risk. Adding the words the live path held back is a
pure append: they have never been on screen, so no write path can destroy
anything by delivering them badly. Correcting words that are already on screen
means deleting text you can see and is correct, then retyping it - and a
synthetic keystroke that gets dropped is reported nowhere, so nothing can prove
the retype arrived. On a long hold that rewrite reached 470 characters, and what
came back was the start of the dictation, a hole, and the tail. So the append
always happens, and the correction happens only when it is one atomic verified
Accessibility call, or small enough to trust to keystrokes. Past that it is
refused and logged, and your words stay as you said them.

**Nothing is believed without proof.** An Accessibility write that returns
success has not necessarily done anything - Discord accepts every such call and
changes nothing - so the write is verified (did the caret move? does the text
read back?) and falls through to keystrokes when it cannot be confirmed. That
one check is the difference between working everywhere and looking completely
dead in half the apps you use.

**No language model writes your text.** Local models were tried for filler
removal and structure; every one of them rewrote the user's words instead of
editing them and was rejected by its own safety check on real transcripts.
Filler removal and email structure are deterministic rules that can only delete
from a fixed list or add whitespace and punctuation. The optional AI punctuation
setting (off by default; it adds 0.5-2s) uses Apple's on-device model, which
also rewrote words when tested ("is" became "are") - so its answer is aligned
word by word with yours and only the punctuation, casing and line breaks around
words it left alone are used. The words that reach the field are always the
words you said.

## Install

Needs macOS 13 or newer, and the Swift toolchain (`xcode-select --install`).
[Homebrew](https://brew.sh) is used to install the speech engine; setup tells you
if it is missing.

```bash
git clone https://github.com/saamirkhrl/talkflow.git
cd talkflow
./install.sh
```

That builds the app, installs it to `/Applications/talkflow.app` (or
`~/Applications` if `/Applications` is not writable) and opens it. The first
launch opens a setup window that walks you through everything:

1. **Microphone** so it can hear you.
2. **Accessibility** so it can type into the app you are using.
3. **Input Monitoring** so it can tell when you hold Fn.
4. **Speech engine**: installs `whisper-cpp` with Homebrew, downloads the English
   model (about 490 MB) and starts a local server. One time, needs the internet.
5. **Try it** in a text box, plus an option to open talkflow at login.

Setup reopens by itself if a permission is ever turned off, and you can open it
any time from the menu bar icon (**Setup...**).

macOS ties permissions to the app's code signature. `install.sh` signs ad hoc,
which works, but you will have to grant the permissions again after each rebuild.
To avoid that, create a self-signed code-signing certificate named
`talkflow Local Dev` in Keychain Access (Certificate Assistant > Create a
Certificate > Code Signing); `install.sh` uses it automatically when present.

The app is not notarized, so installing a downloaded copy would show a Gatekeeper
warning. Building from source with `install.sh` does not.

### Privacy

- Audio is captured in memory, sent to a Whisper server on `127.0.0.1`, and
  never written to disk. Nothing is sent over the internet.
- Your dictation stats are a local JSON file in
  `~/Library/Application Support/TalkFlow/stats.json`.
- The only network use is setup: Homebrew and the model download from Hugging
  Face.
- Input Monitoring is used for modifier keys only (Fn). It does not log typing.

### Troubleshooting

| Symptom | Fix |
|---|---|
| Holding Fn does nothing | Open **Setup...** from the menu bar; each step should show a green check. If Input Monitoring was just granted, press **Restart talkflow**. |
| The emoji picker or dictation opens when you press Fn | System Settings > Keyboard > "Press the globe key to" > **Do Nothing**. |
| Words never appear | The speech engine may be down. `curl http://127.0.0.1:8178/` should answer. Log: `~/Library/Logs/TalkFlow/whisper-server.log`. |
| A permission toggle is on but it still fails | Remove talkflow from that list in System Settings, run **Setup...** again and re-grant it. This happens after a rebuild with a different signature. |
| Anything else | `~/Library/Logs/talkflow/talkflow.log` |

### Uninstall

```bash
launchctl bootout gui/$(id -u)/com.samir.talkflow.whisperserver 2>/dev/null
rm -f ~/Library/LaunchAgents/com.samir.talkflow.whisperserver.plist
rm -rf /Applications/talkflow.app ~/Library/Application\ Support/TalkFlow
brew uninstall whisper-cpp   # only if nothing else uses it
```

Then remove talkflow from the lists in System Settings > Privacy & Security.

## Known limitations

- Only English (`small.en`).
- Writing method per app was measured on 2026-08-10: Notes-style native fields
  take Accessibility writes; Cursor, Discord, Terminal, Claude and Chrome (Gmail)
  take paced keystrokes. **Slack and VS Code have not been verified.** Run
  `--writetest` to see which path an app takes.
- Keystroke delivery cannot confirm that every event arrived, so very long
  corrections over keystrokes are refused rather than risked. Your words stay as
  you said them.
- Not notarized (see Install). The login item and the speech engine's LaunchAgent
  are named `com.samir.talkflow...`; that is just an identifier.

## Development

```bash
./deploy.sh   # developer loop: release build, installs to /Applications/talkflow.app,
              # re-signs with the "talkflow Local Dev" identity (keeps the permission
              # grants across rebuilds) and restarts the LaunchAgent.
              # Assumes a Mac that is already set up. New machines use install.sh.
```

`swift build` on its own changes nothing that is running. Use `deploy.sh`.

## Self-tests

```bash
B=/Applications/talkflow.app/Contents/MacOS/talkflowd
$B --streamtest              # append-only streaming: replays whisper revision
                             #   sequences, asserts zero mid-stream deletes
$B --typetest                # the writing layer, against the real event pipeline
$B --rectest 3               # mic capture, WAV header, transcription round trip
$B --formattest "raw text"   # the text pipeline, no microphone
$B --dashboardshot           # renders the dashboard (grid, bars, light, dark) to
                             #   PNGs in $TMPDIR, to check its layout
$B --enginecheck             # read-only: setup state (engine, model, permissions)
$B --focusprobe              # read-only: what the focused element accepts
$B --writetest [seconds]     # which write path the app you focus accepts
$B --newlinetest [seconds]   # whether a newline sends the message in a chat app
```

`--streamtest` and `--formattest` are pure logic and run anywhere. The others
need the signed bundle's permissions. `--typetest` takes focus, so don't run it
while you are typing.

## Layout

| file | role |
|---|---|
| `Dictation.swift` | orchestrator: record, transcribe, render, commit, write |
| `StreamCommit.swift` | decides which words are settled enough to type |
| `Recorder.swift` | mic to in-memory PCM to WAV bytes |
| `Transcriber.swift` | posts WAV to whisper-server |
| `FieldSync.swift` | diffs desired against on-screen text, picks a write path |
| `FieldWriter.swift` | Accessibility write, verified before it is believed |
| `LiveType.swift` | keystroke write: chunked, paced, serial background queue |
| `TextCommands.swift` | emoji, spoken punctuation, list cues, capitalisation |
| `StructurePolish.swift` | email greeting and sign-off paragraph breaks |
| `Cleanup.swift` | filler-word removal |
| `Hotkey.swift` | Fn key via CGEventTap |
| `Onboarding.swift` | first-run setup window: permissions, speech engine, try it |
| `Permissions.swift` | microphone, Accessibility, Input Monitoring: status, requests, deep links |
| `SpeechEngine.swift` | finds or installs whisper-server, downloads the model, manages its LaunchAgent; `FinalPassEngine` runs large-v3-turbo for the final pass |
| `ScreenContext.swift` | read-only snapshot at key-down: text before the caret, names on screen, app; casing and chat style |
| `Polish.swift` | optional on-device AI punctuation, merged so no word can change |
| `Vocabulary.swift` | learns spellings from the user's fixes |
| `Preferences.swift` | the Settings page's values |
