# Security

By default talkflow runs on your Mac and sends your speech and text nowhere. Audio
is kept in memory, transcribed by a Whisper server listening only on `127.0.0.1`,
and never written to disk. The network use is the one-time setup (the speech model
download from Hugging Face), update checks and the one-time install count
(see the README's Privacy section), and, if you ask for it, building from source.
If you add your own OpenAI or Anthropic key in Settings, the step that key is for
is sent to that provider. With an Anthropic key and Claude punctuation on, the
experimental AI corrections option (off by default; used on Macs without Apple
Intelligence) sends the dictated text to Anthropic in a second request.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private
reporting instead: **Security tab > Report a vulnerability** on this repository.
Include what you found, how to reproduce it, and the macOS version.

## What talkflow needs, and why

| Permission | Used for |
|---|---|
| Microphone | capturing your voice while Fn is held |
| Accessibility | reading the focused text field and typing into it |
| Input Monitoring | not requested: Accessibility already lets talkflow notice the Fn key (modifier keys only; it does not log typing) |

## For contributors

- Never commit `.env` files, keys, certificates or signing identities. They are in `.gitignore`.
- Do not commit screen recordings or logs; they can contain private text.
- If a secret is ever committed, treat it as leaked and rotate it. Deleting it in a later
  commit does not remove it from history.
