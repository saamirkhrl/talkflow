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
