# Meeting notes, for contributors

Notes is a section of the Mac app window. The user clicks **Start recording**, talks, and
clicks **Stop and write notes**; talkflow then writes a transcript on the Mac, with the voices
told apart. Summary, action items and Ask are optional and use the user's own key. Notes is
Mac only for now; the Windows app has no note taker. The measurements behind the constants
are in [notes-measurements.md](notes-measurements.md).

## What it does, in order

1. **Capture** (`MeetingRecorder.swift`, `SystemAudioTap.swift`). Two tracks, never mixed:
   the microphone, and the sound the Mac plays through a Core Audio process tap
   (`CATapDescription`, a global tap that excludes talkflow itself). The tap needs macOS 14.2
   or later and the System Audio Recording permission; on older macOS the Notes page says what
   is needed and recording stays off. It never uses Screen Recording or ScreenCaptureKit, and
   it never talks to the meeting app. Meeting capture does not touch dictation's recorder, so
   dictation keeps working during a meeting and while notes are written.
2. **Echo removal** (`EchoStage`): takes the far side's sound out of the microphone track,
   so voices from the speakers are not counted twice. It is skipped when the output was
   headphones throughout.
3. **Telling voices apart**, on the system track only, by the speaker helper
   `Contents/Helpers/talkflow-diarize` (a separate Swift package over FluidAudio, in
   `Helpers/talkflow-diarize`). It runs only on Apple Silicon with macOS 14 or later and needs
   the speaker models downloaded; otherwise the other side is labelled "Everyone else". The
   microphone side is "You"; other voices are "Speaker 1", "Speaker 2" and so on; a name
   said in the meeting can replace a label. The helper writes speaker turns only. No voice data is saved, and voices
   are not remembered from one meeting to the next.
4. **Transcription** by whisper.cpp on a private `whisper-server`, started for notes and
   listening only on `127.0.0.1`. It uses large-v3-turbo when that model is on disk,
   otherwise the dictation model.
5. **Save**: the transcript is written, then the audio is deleted. Audio is kept only if
   writing the notes or deleting the audio fails; the note then shows as failed, never as
   finished, with **Delete audio** and **Delete**.

## Where the data lives

```
~/Library/Application Support/talkflow/notes/<id>/
  note.json        the note's details (title, start, length, state, speaker names)
  transcript.json  once written
  summary.json     only if the user made a summary
  questions.json   only if the user used Ask
  audio/           the two recorded tracks, only until the transcript is saved
```

Until notes, talkflow stored no text of what was said apart from learned words. The speaker
models live next to the speech models, in `~/Library/Application Support/TalkFlow/models/diarization/`.
Uninstall removes the models and keeps the data folder, notes included.

Logs (`~/Library/Logs/talkflow/talkflow.log`) get counts and durations only: never transcript
text, speaker names, summaries or questions. Keep it that way in any new log line.

## Network

None for notes, except:

- two optional downloads the user starts from the Notes list: the large-v3-turbo speech model
  (about 574 MB, shared with Accurate final pass) and the speaker models (about 21 MB, from
  Hugging Face, `FluidInference/speaker-diarization-coreml`);
- Summary, action items and Ask, once an Anthropic or OpenAI key is saved in Settings > API keys
  (talkflow asks once before the first request to a provider; without a key nothing is sent).
  They send the transcript text, with the speakers' names, never audio, to Anthropic (if an
  Anthropic key is saved) or OpenAI, with the user's key and billed to them.

## Document-style notes

The summary request returns one JSON reply that fills a document-style page. Everything below
comes from that single request, never a second one.

- **Title and description.** The reply proposes a title (3 to 7 words) and a one-line description
  (at most 10 words). `NotesDoc.cleanTitle` and `cleanDescription` tidy them (quotes, ending
  periods, generic words such as "Meeting" are refused). A new summary refreshes the description
  and replaces the title only while the title is the placeholder or an earlier auto title. A title
  the user typed is never changed. Emptying the title in the editor returns it to the placeholder.
- **Speaker names.** The request is serialized with sorted keys, so the model writes the fields in
  alphabetical order. The reply fields are named so that this order is the one we want: `attendees`
  comes first (the model looks for names before it writes anything else), then `decisions`,
  `description`, `details`, `next_steps`, `summary`, `summary_times`, `title`; inside an attendee,
  `label`, `quote`, `quote_time`, `relation`, `speaker_name`, `strength`. Older field spellings
  (`speakers`, `action_items`, `name`, `kind`, `evidence`, `time`, `confidence`) still decode.
  The prompt gives a positive procedure for each label: look at the line before the speaker talks and
  the line after they finish for a name said to them (relation "addressed", with the direction
  spelled out: the person who says "Thanks, Marcus" is not Marcus), otherwise a self-introduction
  ("introduced"). `strength` is high, medium or low. `NotesAI.nameReview` checks each entry and gives
  a verdict with a fixed reason when refused ("no name", "not a speaker label", "speaker already
  named", "generic name", "too long", "low confidence", "unknown kind", "quote not found", "name not
  in quote", "introduced by someone else", "named speaker said it", "not next to the named speaker",
  "two names for one speaker", "name on two speakers", "name already used"). High and medium pass,
  low is refused. The quote is searched in the whole transcript and the turn nearest the cited time
  is used; for "addressed", the speaker before or after the quoting turn must be the named one.
  Invalid names are dropped and never fail the reply. A name the user typed is never replaced.
  `NotesModel.clearSuggestedName` returns a speaker to "Speaker N" and marks it user-set, so it is
  not suggested again; the meeting page has no control for renaming or clearing at the moment. A long meeting merges the names of its parts (`NotesAI.mergedNames`).
- **Local vocative pass.** Without any model, `NotesAI.localVotes` reads the transcript for names
  said to a speaker: a sentence that starts with "Name," or says "over to Name" names whoever speaks
  next; "Thanks, Name", "Hi Name", or a trailing or enclosed ", Name" names whoever spoke before.
  A name is two capitalised words at most and never a stopword (okay, sorry, everyone, weekdays,
  months and similar). A turn with two or more different names in one direction is a list and counts
  for nobody. A vote is not counted when it points at You, at a speaker that already has a name, or
  when the name is too long. `NotesAI.localNames` names a speaker only when exactly one name has two
  or more counted votes for them, nobody else has a counted vote for that name, and no other speaker
  already shows it. `NotesAI.combinedNames` merges these with the model's accepted names; a speaker
  the two name differently, or one name on two speakers, gets none.
- **Stored references follow renames.** In stored summary text, a speaker's label or name is saved
  as a `{{s2}}` token (`NotesDoc.tokenizing`) and turned into the current display name when shown,
  copied or sent on (`NotesDoc.resolving`), so a changed name updates the notes.
  Old summaries have no tokens and show as saved.
- **Diagnostics.** `--notesasktest` also writes the raw reply texts, the review of every proposed
  name and the number of speakers it would rename into the result file (meeting text, local only),
  and prints one counts line: `names: proposed N, applied M, rejected K (reason xC, ...)`, then
  `local names: N vote(s) counted, M name(s)` for the local pass (its votes and names are also in the
  result file).
- **Layout.** The Summary tab reads as a document: Summary, Decisions (each with a status:
  aligned, needs further discussion, disagreed or shelved), Details (topics, each with time links
  into the transcript) and Suggested next steps. Copy on the Summary tab writes the same
  structure as Markdown (`NotesDoc.markdown`).
- **Ask** is its own tab: the conversation fills the page under the header and answers read like
  the Summary, without a bubble; the question field stays pinned at the bottom. Before the first
  question the tab shows one line saying each question sends the transcript to the provider with
  the user's key. The Summary and the answers carry no "Written by" line.
- **Backward compatible.** Every new field is optional, so notes saved earlier still open:
  `titleSource` and `subtitle` in `note.json`, `nameSource` on each speaker, and `details`,
  `title`, `subtitle`, `suggestedNames` and a decision's `status` in `summary.json`. A missing
  source is read from the old rule (an empty or placeholder title is a placeholder, a name is the
  user's). An old summary shows its decisions as aligned and its open questions as needing
  further discussion, and has no Details.
- Logs carry counts only (details, names suggested, whether a title was set), never the text.

## Not in this version

No live transcript, no Windows note taker, no calendar or automatic meeting detection, no
remembering voices across meetings, and no local model for summaries. There is no built-in
recording-consent reminder: telling the other people that they are being recorded is the
user's responsibility, and the rules differ from place to place.

## Self-tests

Run them from a build (`swift build`, then `"$(swift build --show-bin-path)/talkflowd" <flag>`).
Each writes its results where the table says; most write a log in `$TMPDIR`.
Fixtures are never in the repository: they live under
`~/Library/Application Support/talkflow/test-fixtures/`, and a test whose fixtures are absent
skips with one line.

| Flag | What it checks | Output |
|---|---|---|
| `--notestest` | pure logic and the notes store, in a temporary folder (merge, speaker, label and copy rules). No fixtures needed; CI runs it | `$TMPDIR/talkflow-notestest.log` |
| `--capturetest [seconds]` | the real capture for a few seconds (default 10): durations, sample counts against the clock, levels, the system-audio state; then deletes the audio. Never asks for a permission | `$TMPDIR/talkflow-capturetest.log` |
| `--echotest [folder]` | the echo canceller on the digital echo fixtures (default `test-fixtures/echo/digital`) | `$TMPDIR/talkflow-echotest.log` |
| `--diarizetest [--helper PATH] [--models DIR]` | the speaker helper on the diarization fixtures (`test-fixtures/spikes/diarization/fixtures`): error rate, voices found, time | `$TMPDIR/talkflow-diarizetest.log` |
| `--notespipeline <mic.wav> <system.wav> [options]` | the whole after-Stop pipeline on two WAV files, with a transcript JSON out (`--out`); options include `--headphones` or `--speakers`, `--model`, `--server`, `--helper`, `--speaker-models`, `--no-speakers`, `--check` | numbers on stdout |
| `--fakemeeting [folder] [--dry-run [--misaligned \| --headphones \| --silent-user]] [--dictionary] [--keep-debug DIR] [--fake-pipeline]` | end to end on a made-up meeting (`test-fixtures/fakemeeting`), scored against its truth; `--dry-run` copies the fixture instead of recording, and `--dry-run --misaligned` writes the tracks as a bad first meeting leaves them. `--headphones` uses the headphones microphone (echo stage bypassed). `--silent-user` uses `mic_speakers_silent.wav` (built by the fixture's `tools/build_silent.py`: the user says nothing while the meeting plays through laptop speakers that leave real-room residue) with a placeholder dictionary, and is scored on the words in "You" (at most 5) and on prompt text in the transcript (none). `--dictionary` sends the placeholder dictionary on any run; `--keep-debug DIR` keeps the debug data below in DIR. **Plays sound** unless `--dry-run`, so no build script runs it | terminal and `$TMPDIR/talkflow-fakemeeting.log` |
| `--notesprobe <mic.wav> <system.wav> [--dump DIR] [--no-residue]` | the audio stages only (echo canceller, near-end gate, echo residue rule, cutter), no speech engine: leakage, regions dropped, pieces | `$TMPDIR/talkflow-notesprobe.log` |
| `--notesasktest <transcript.json> [summary \| ask "<question>"] [anthropic \| openai]` | one real Summary or Ask request with the key in the Keychain. **Billed** to that key; run it from the installed app | `$TMPDIR/talkflow-notesasktest.json` |

## Debug data (local test builds only)

A hidden preference, off by default and with no switch in the app, keeps a copy of each meeting's
audio and the pipeline's numbers before the audio is deleted:
`defaults write com.samir.talkflow notesKeepDebugData -bool true` (quit and reopen talkflow), and
`defaults delete com.samir.talkflow notesKeepDebugData` to stop. Each note then leaves
`~/Library/Application Support/talkflow/debug-runs/<note id>/` with both tracks, the timelines,
`session.json`, the aligned and echo-cancelled microphone tracks when they exist, and
`pipeline.json`: stage times, piece counts, the echo stage's estimates, every speech region of the
microphone with its level and the echo residue rule's decision, and every transcribed piece with
its level, word count, the engine's probabilities and what happened to it. No transcript text. The
notes folder still deletes its own audio as usual; the copies stay until removed by hand.

## Licences

The speaker helper ships FluidAudio (Apache-2.0) and uses its Core ML speaker models
(CC-BY-4.0: attribution to pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference; the files
are modified conversions). The notices are in `Helpers/talkflow-diarize/THIRD-PARTY-NOTICES.txt`
and ship as `Contents/Resources/talkflow-diarize-NOTICES.txt`, next to whisper.cpp's licence.
