# Meeting notes: what was measured and what was chosen

Measured on 23 November 2026 on an Apple M4 with 16 GB, macOS 27.2.1, before the note taker
was built. The constants in the notes code point back to this page. Where a number here
disagrees with an earlier plan, the number won.

Every fixture is synthetic speech rendered with macOS `say` to files (nothing was recorded from
a real call, and no fixture is in the repository). That is the main limit of everything below:
real voices, codecs and rooms will score worse. Dead ends are listed so nobody repeats them.

## 1. Capture

Design: the microphone through an AVAudioEngine tap, started first, converted to 16 kHz mono
16-bit and streamed to disk. System audio through a Core Audio process tap (macOS 14.2 or later):
a global tap that excludes talkflow's own process, wrapped in a private aggregate device and read
by an IOProc. The IOProc only downmixes and copies into a lock-free ring; a writer thread converts
and writes. The two tracks are never mixed.

| Measured | Value |
|---|---|
| System tap format | 48 kHz, stereo, Float32 interleaved, 512 frames per callback (10.667 ms) |
| Tap timestamp lag behind the callback | 11.4 ms |
| Tap drift against the host clock | -2.8 to -8.3 ppm |
| Microphone, 361 s recording | 52 samples (3.25 ms) short of the host clock, +2.1 ppm |
| Dictation while a second recorder runs | `--rectest 3` passed (2.99 s of 3.00 s), twice |
| Killed mid-recording | header 0.2 s stale; repair recovered all the audio |
| Rebuilding the tap after a route change | 87.7 ms |

Choices that follow:

- The WAV header is written by hand and patched every second, so a killed process leaves a
  repairable file.
- Both tracks use the host clock and keep a small timeline file. Gaps of 50 ms to 5 s are filled
  with silence, longer ones are marked as a break.
- After Stop, before the echo stage, both tracks are put on one time axis, seconds since the
  recording started (`TrackAlign`): each stretch between breaks is placed at the median of
  (host time - sample index / 16000) over its timeline points, so equal sample index means equal
  host time. A late start (the system track begins only when the permission prompt is answered,
  5 to 30 s in) becomes leading silence; a break in one track becomes silence so later audio stays
  in place; when neither track has audio for more than 5 s (sleep) the span is kept as 2 s and
  the removed seconds are added back to every turn time. The transcript shows no marker across a
  break: turn times simply jump. Recordings without timeline files are read as before.
- Offsets only, no drift stretching. The real drift measured above (-8.3 to +2.1 ppm) is at most
  60 ms over two hours, inside the echo stage's own delay and drift fit (0.5 s search) and the
  transcript rule's 1.0 s pad, while straight-line fits over 10 to 20 s read hundreds of ppm from
  converter jitter (microphone residuals up to 8.9 ms). A median offset ignores that jitter; the
  fitted drift is only logged.
- The tracks are read straight into their aligned place 1 MB at a time, so memory holds one copy
  of each track (a two-hour track is 230 MB).
- Checked by `--notestest` (TA1 to TA12) and by `--fakemeeting --dry-run --misaligned`: the
  fixture recut so the system track starts 12 s late and the microphone has an 8 s break, with
  timeline files written as the capture writes them, scored against the shifted truth.
- Every Core Audio create, start and stop call runs on its own queue with a timeout. A pending
  permission prompt stalled `AudioDeviceStop` for more than 60 s in one run.

What turned out different from the plan:

- "Without permission every buffer is zeros" is only true while another app is playing. With
  nothing playing, the IOProc is never called at all. The rule used: no callbacks within 1 s of
  starting means not authorised or waiting for the prompt; exact zeros for 3 s while another app
  is playing means no computer audio is arriving; exact zeros with nothing playing cannot be told
  apart from a missing permission, so the screen stays neutral ("nothing playing yet").
- Without `NSAudioCaptureUsageDescription` in Info.plist macOS refuses silently. No prompt appears.

Not proven without the permission or a person: real system audio content, an explicit Deny, a real
output device switch, AirPods, sleep and wake, a tapped app quitting, a run on macOS 13.

## 2. Echo

On speakers the microphone also hears the other people. Targets: at most 2% of far-end words leak
into "You", at least 98% of the user's own words survive double talk, no change on headphones.

29 synthetic fixtures (delay 20 to 120 ms, simulated room with RT60 0.2 to 0.6 s, echo 6 to 30 dB
below the voice), transcribed with small.en. Leak is the share of far-end words found in "You".

| Candidate | Leak, user silent | Leak, double talk | Leak, hard cases | Keep | Headphones |
|---|---|---|---|---|---|
| Nothing (route check only) | 88.6% | 28.0% | 58.9% | 98.1% | unchanged |
| Transcript rule only | 1.1% | 2.3% | 0.8% | 98.1% | unchanged |
| NLMS adaptive filter | 26.9% | 25.7% | 31.6% | 72.8% | changed (diverged) |
| Frequency-domain adaptive filter | 19.5% | 28.0% | 17.3% | 94.4% | unchanged |
| Offline Wiener canceller | 0.0% | 0.0% | 25.7% | 98.4% | 0.028 change |
| Speex DSP | 8.7% | 0.0% | 29.1% | 98.6% | 0.021 change |
| Speex DSP + transcript rule | 1.2% | 0.0% | 1.7% | 98.6% | 0.021 change |
| **Chosen: delay gate + Wiener + rule** | **0.0%** | **0.0%** | **2.5%** | **98.8%** | **bit-exact** |

The chosen stage: (1) on headphones skip it; (2) estimate the delay and clock drift between the
tracks, and if no consistent delay exists pass the microphone through untouched; (3) otherwise run
an offline Wiener echo canceller in 30 s segments (no double-talk detector, cannot diverge);
(4) apply the transcript rule: drop "You" text that overlaps system-track speech in time and
closely matches its words, never where the system track is silent. It costs about 0.2 s per
80 s of audio and needs only Accelerate.

Shortfalls and dead ends:

- With +100 ppm clock drift and the user silent, 8.7% of far-end words still leak (target 2%).
  This matters mostly when microphone and speakers run on different clocks, such as a USB speaker.
- Keep has a floor of about 98.4% from the recogniser's own run-to-run variation.
- Not validated on real echo. The one acoustic capture lost 21% of its samples in the recording
  tool and could only test the transcript rule (0.0 to 0.8% leak).
- A delay search margin of 32 samples locked onto a room reflection; 320 samples fixed it (echo
  reduction went from 10 dB to 19 dB).
- Residual suppressors lowered keep and gained nothing once the transcript rule runs.
- WebRTC AEC3 was not built: meson, abseil and C++17 for a stage that the table shows is not
  needed, and its patent grant was not confirmed. Apple voice processing was not evaluated.

## 3. Telling voices apart

Run on the system track only, in a separate helper so the main app keeps its macOS 13 minimum.
Error is diarization error rate with a 0.25 s collar, overlapped speech scored.

| | FluidAudio 0.18.4 | sherpa-onnx, WeSpeaker | sherpa-onnx, 3D-Speaker |
|---|---|---|---|
| 2 voices / 3 voices / 5 voices | 0.14% / 0.80% / 1.91% | 0.34% / 1.22% / 1.24% | 0.34% / 1.22% / 0.81% |
| Made-up meeting (5 voices, 8.9 min, 27 overlaps) | **6.08%** | 16.65% | 8.57% |
| Voices found on that meeting | 5 of 5 | 5 of 5 (by splitting one voice) | 9 of 5 |
| Quiet voice covered | 0.92 | 0.98 | 0.76 |
| Bad-line voice covered | 0.88 | 0.22 | 0.85 |
| Voice returning after minutes keeps its label | yes | yes | yes |
| Time for the 8.9 min meeting | 2.7 to 4.2 s | 44 s | 34 s |
| Peak memory | 720 to 850 MB | 187 to 275 MB | 395 to 460 MB |
| Model download | 21 MB | 32.5 MB | 32.5 MB |
| Shipped code | 8.1 MB, system frameworks only | 51.7 MB static | 51.7 MB static |
| Runs on Intel Macs / Windows | no / no | yes / yes | yes / yes |

Chosen: FluidAudio's offline pipeline (pyannote community-1 segmentation, WeSpeaker embeddings,
VBx clustering), threshold 0.6, no fixed speaker count. Where the helper cannot run (Intel, macOS
older than 14) the system track is labelled "Everyone else". sherpa-onnx stays the documented
option for a later Windows note taker.

Known weakness: isolated turns of 0.4 to 0.8 s ("Okay.", "No.") are dropped, because the library
does not embed segments shorter than 1.0 s. The threshold sweep did not finish in the time box.

Licences: FluidAudio is Apache-2.0. Its Core ML models (FluidInference/speaker-diarization-coreml)
are CC-BY-4.0 and require attribution to pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference,
with a note that the files are modified conversions. The attribution ships next to whisper.cpp's.

## 4. Transcription

One hour of synthetic speech (3604 s, 9557 words), cut into 167 pieces at pauses and sent one at
a time to a dedicated whisper-server (whisper.cpp v1.9.4) on port 8192.

| | small.en-q5_1 | large-v3-turbo-q5_0 |
|---|---|---|
| Time for the hour | 85.8 s | 238.2 s |
| Real-time factor | 0.024 | 0.066 |
| Peak memory of the server | 417 MB | 798 MB |
| Word error rate | 0.99% | 0.81% |
| Words invented on silence | 0 | 0 |
| Cold start | 0.18 s | 0.35 s |

Chosen: turbo when it is on disk, otherwise the live model; started with `-nt`; one piece at a
time; `response_format=json` with the language and the vocabulary prompt on every request.

- The pause cutter is energy based: speech is 10 dB above the noise floor, pieces are at most
  28 s, pauses over 2 s are dropped.
- Retry rule: a piece that comes back with fewer than 1.0 words per second of speech is sent
  again at temperature 0.4. All three failed pieces that were retried came back in full.
- The estimate shown while notes are written is (cold start + pieces x a + speech seconds x b)
  x 1.25, about 5 minutes for an hour on turbo.
- Two requests at once are 38% slower: the server handles one request at a time.
- A dictation engine next to a busy notes server answered in 0.85 s instead of 0.32 s (worst
  1.42 s). The notes server slowed by 7%.
- Memory while notes are written: about 1.2 GB with turbo, counting the dictation engine
  (419 MB). If the optional accurate final pass is also on, it holds its own copy of turbo, about
  2 GB together. Accepted for now.

What turned out different from the plan:

- small.en needs 1.4 minutes per hour of audio, not 1. Turbo's 4 minutes held.
- Cutting into pieces does not remove the dropped-text failure: 5 of 668 piece requests lost most
  of their text, 3 of them right after a forced cut inside a long monologue. Hence the retry rule.
- The earlier failure on a 69 s clip did not reproduce, as one request or in pieces.
- whisper.cpp's built-in voice detection needs its own model at startup and cannot say where to
  cut. It is not used.

Speed on a dense meeting (the 8.9 minute fake meeting, 23 November 2026, turbo, this M-series Mac):

- The whole pipeline took 0.19x real time on headphones (100 s; transcription 93 s of it), against
  0.066x on the spike's hour. The difference is the number of pieces, not the speed of a piece:
  77 requests for 502 s of speech, a mean of 6.5 s each, against 167 requests of 19.8 s for an hour.
- Every request costs about 1.1 s whatever its length (fit over the 77 requests: 1.11 s + 0.0135 s
  per second of audio). The server's own timings put 1.02 s of that in one encoder pass: whisper
  always encodes a full 30 s window, so a 3 s piece costs the same as a 20 s one. Decoding is
  about 2.5 ms per token.
- `no_language_probabilities` matters: without it the server runs the encoder a second time per
  request to detect the language (2.1 s per request measured). The pipeline already sends it.
- `audio_ctx` sent with a request is ignored by the server (same 1.02 s encode); setting it for the
  whole server would shorten the window for every piece, which whisper is known to transcribe less
  reliably, so it was not tried.
- Merging neighbouring pieces of the same speaker: only 3 of 73 turns qualify, each across a 3.8 to
  10.7 s pause the cutter drops on purpose (silence is where whisper invents words). At most 3 s
  saved. Not done.
- The pieces are short because the turns are: they are cut at every speaker change so that each
  piece has one speaker. Joining different speakers' pieces into one request would need the reply
  split back by word times; not done without a measurement that the scores hold.

## 5. Summary and Ask

No measurement, but the choices rest on the provider documentation as read on 23 November 2026:
Anthropic Messages API (version 2026-10-21, structured output through `output_config.format`,
prompt caching with a 512 token minimum) and the OpenAI Responses API (`text.format` with a strict
JSON schema, `store: false`, automatic caching). Defaults are the cheapest suitable model of each
provider. Nothing is sent unless the user has saved a key (Settings > API keys) and has agreed once to the first request.
