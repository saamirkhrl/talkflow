# Security

By default talkflow runs on your Mac and sends your speech and text nowhere. Dictation
audio is kept in memory, transcribed by a Whisper server listening only on `127.0.0.1`,
and never written to disk. The network use is the one-time setup (the speech model
download from Hugging Face), update checks and the one-time install count
(see the README's Privacy section), and, if you ask for it, building from source.
If you add your own OpenAI or Anthropic key in Settings, the step that key is for
is sent to that provider. With an Anthropic key and Claude punctuation on, the
experimental AI corrections option (off by default; used on Macs without Apple
Intelligence) sends the dictated text to Anthropic in a second request.

Meeting notes (Mac only) work differently. A meeting the user records is written to disk:
the microphone and the sound the Mac plays, as two tracks in
`~/Library/Application Support/talkflow/notes/<id>/audio/`. After Stop, the notes are
written on the Mac by a second Whisper server, also only on `127.0.0.1`, and the audio is
deleted as soon as the transcript is saved. It is kept only if writing the notes or deleting
the audio fails; the note then says so and offers Delete. The transcript and the note's details stay in that folder
(talkflow's first stored text of what was said, apart from learned words); logs hold counts
and durations, never transcript text. Notes use the network only for two downloads the user
clicks (a larger speech model, about 574 MB, and speaker models, about 21 MB, both from
Hugging Face) and, with **Use my key for meeting notes** on (off by default), to send a
transcript's text, never audio, to Anthropic or OpenAI with the user's own key for the
summary, action items and Ask.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private
reporting instead: **Security tab > Report a vulnerability** on this repository.
Include what you found, how to reproduce it, and the macOS version.

## What talkflow needs, and why

| Permission | Used for |
|---|---|
| Microphone | capturing your voice while Fn is held |
| Accessibility | reading the focused text field and typing into it |
| System Audio Recording | meeting notes only: recording the sound the Mac plays, through a Core Audio process tap (macOS 14.2 or later). Asked for the first time a meeting is recorded; talkflow never asks for Screen Recording |
| Input Monitoring | not requested: Accessibility already lets talkflow notice the Fn key (modifier keys only; it does not log typing) |

## For contributors

- Never commit `.env` files, keys, certificates or signing identities. They are in `.gitignore`.
- Do not commit screen recordings, logs, meeting recordings or transcripts; they can contain
  private text. Notes test fixtures live outside the repository.
- If a secret is ever committed, treat it as leaked and rotate it. Deleting it in a later
  commit does not remove it from history.
