# talkflow

## Git workflow

- Small changes go straight to `main`: copy and text tweaks, docs, comments, config,
  dependency or version bumps, typo and styling fixes, cleanup chores. Verify, commit,
  `git pull --rebase origin main`, `git push origin main`. No branch, no PR.
- New features, product or behavior changes, non-trivial bug fixes, and anything touching
  the release pipeline, signing, the updater, CI, or many files use a branch
  (`feat/...`, `fix/...`) and a PR. Merging a PR needs the owner's explicit approval.
- Releases, tags and deploys always need the owner's explicit approval (see
  `docs/releases.md`).
- Never force-push or rewrite history on `main`. When unsure whether a change is small, use
  a PR.
- `main` is protected on GitHub: other contributors must open a PR; only the owner pushes
  directly.

## Windows ships one build

Windows has a single build, x64 (`talkflow-windows-x64-setup.exe`). It runs on
every Windows 10 (1809) or 11 PC, Arm PCs included, through Windows' built-in
emulation. There is no arm64 build, installer, CI job or website choice; do not
add one without the owner asking. (The Mac app is separate and stays universal.)

