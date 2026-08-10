# TalkFlow

macOS dictation. Hold **Fn**, speak, the words appear in whatever text field you
are typing in. Local transcription, no cloud, no account.

Works in native apps, Electron apps (Cursor, Discord, Slack, VS Code) and
terminals, because it can write either through the Accessibility API or as
paced synthetic keystrokes, and it checks which one an app actually honours
rather than assuming.

## How it works

```
Fn held -> mic -> in-memory PCM -> whisper-server (local, warm)
        -> every 0.7s: transcribe the whole buffer so far
        -> StreamCommit: which words have stopped changing?
        -> FieldSync: append them to the focused field
Fn released -> final transcript -> one correction pass
```

**Live typing is append-only.** Whisper revises what it already said as more
audio arrives ("to" becomes "two", punctuation slides), so typing each new
transcript in full meant deleting and retyping text several times a second.
Instead a word is released only once two consecutive transcripts agree on it
and another word sits behind it - LocalAgreement-2, the standard streaming-ASR
approach. Committed words are never taken back, so the only edit a live update
can make is an append. Corrections are deferred to a single pass when the key
is released, which is also where email paragraph breaks are decided.

**Nothing is believed without proof.** An Accessibility write that returns
success has not necessarily done anything - Discord accepts every such call and
changes nothing - so the write is verified (did the caret move? does the text
read back?) and falls through to keystrokes when it cannot be confirmed. That
one check is the difference between working everywhere and looking completely
dead in half the apps you use.

**No LLM in the pipeline.** Local models were tried for filler removal and
structure; every one of them rewrote the user's words instead of editing them
and was rejected by its own safety check on real transcripts. Filler removal and
email structure are deterministic rules that can only delete from a fixed list
or add whitespace.

## Build and install

```bash
./deploy.sh   # release build, installs to /Applications/TalkFlow.app,
              # signs with a stable local identity so the Accessibility,
              # Input Monitoring and microphone grants survive rebuilds,
              # and restarts the LaunchAgent
```

Needs a local `whisper-server` on `127.0.0.1:8178` with `ggml-small.en.bin`
resident, run as a LaunchAgent so the model stays warm. Transcription costs
about 0.35s warm, and 60s of speech transcribes in about 1.5s.

`swift build` on its own changes nothing that is running. Use `deploy.sh`.

## Self-tests

```bash
B=/Applications/TalkFlow.app/Contents/MacOS/talkflowd
$B --streamtest              # append-only streaming: replays whisper revision
                             #   sequences, asserts zero mid-stream deletes
$B --typetest                # the writing layer, against the real event pipeline
$B --rectest 3               # mic capture, WAV header, transcription round trip
$B --formattest "raw text"   # the text pipeline, no microphone
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

`HANDOFF.md` carries the detail: what is measured, what is verified, which bugs
are already fixed, and which dead ends not to repeat.
