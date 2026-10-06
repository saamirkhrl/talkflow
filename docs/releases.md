# Releases and updates

Every talkflow release on GitHub carries a small JSON file,
`talkflow-release.json`, that lists the builds attached to that release with
their sha256 and size. Every app (macOS today, Windows next, Linux later)
checks for updates by fetching one URL:

```
https://github.com/saamirkhrl/talkflow/releases/latest/download/talkflow-release.json
```

GitHub serves `releases/latest/download/<name>` from the newest published,
non-prerelease release, so the URL never changes.

## The manifest

```json
{
  "schema": 1,
  "version": "0.1.4",
  "tag": "v0.1.4",
  "published": "2026-10-05T12:00:00Z",
  "notesUrl": "https://github.com/saamirkhrl/talkflow/releases/tag/v0.1.4",
  "notes": "short plain-text release notes (may be empty)",
  "platforms": {
    "macos": {
      "universal": {
        "update":    { "name": "talkflow-macos.zip", "url": "...", "sha256": "<hex>", "size": 123 },
        "installer": { "name": "talkflow-macos.dmg", "url": "...", "sha256": "<hex>", "size": 456 }
      }
    },
    "windows": {
      "x64":   { "update": { "name": "talkflow-windows-x64-setup.exe", "...": "..." },
                 "installer": { "name": "talkflow-windows-x64-setup.exe", "...": "..." } },
      "arm64": { "...": "..." }
    },
    "linux": {}
  }
}
```

- `schema` is 1. It changes only for a change older apps could not read; an
  app that does not know the schema treats the manifest as missing.
- `version` is the tag without the `v`. Apps compare it numerically
  (`0.10.0` is newer than `0.9.2`).
- `notes` is the release body as plain text (markdown emphasis and link syntax
  removed), at most 2000 characters.
- Each asset entry has `name`, `url` (the GitHub download URL), `sha256`
  (lowercase hex) and `size` (bytes).
- `update` is what an installed app downloads to update itself; `installer` is
  what a new user downloads. On Windows and Linux they are the same file.
- `macos`, `windows` and `linux` are always present, possibly empty. An arch
  appears only when its asset is attached to that release.
- Apps ignore platforms, arches and keys they do not know.

### Asset names

The names are fixed. The website links to
`releases/latest/download/<name>`, and the generator recognizes only these:

| Asset | platform / arch | roles |
|---|---|---|
| `talkflow-macos.zip` | macos / universal | update |
| `talkflow-macos.dmg` | macos / universal | installer |
| `talkflow-windows-x64-setup.exe` | windows / x64 | update, installer |
| `talkflow-windows-arm64-setup.exe` | windows / arm64 | update, installer |
| `talkflow-linux-x64.AppImage` | linux / x64 | update, installer (reserved) |
| `talkflow-linux-arm64.AppImage` | linux / arm64 | update, installer (reserved) |

Any other asset on a release (and the manifest itself) is left out.

## How each app finds its build

- **macOS** (`Sources/talkflowd/Updater.swift`) reads
  `platforms.macos.universal.update`. The entry counts only with an https URL
  and a 64-character sha256. If the manifest is missing (a release made
  before it existed), is not JSON, or has an unknown schema, the app falls
  back to the GitHub API (`api.github.com/repos/saamirkhrl/talkflow/releases/latest`)
  and takes the first `.zip` asset, using GitHub's own `digest` for that asset
  as the checksum when the API reports one. A valid manifest with no macOS
  update entry means there is no update for the Mac. Before installing, the
  app checks the downloaded zip's sha256 against the expected one and refuses
  to install on a mismatch ("The download did not match the release's
  checksum, so it was not installed").
- **Windows** reads `platforms.windows.<arch>.update`, where `<arch>` is `x64`
  or `arm64`.
- **Linux**, when it exists, reads `platforms.linux.<arch>.update`.

### When the Mac app checks

- About 10 seconds after the network becomes reachable (so shortly after
  launch when online; nothing is attempted while offline), then again once 6
  hours have passed since the last successful check, while it runs. These
  background checks fail quietly: a failure is logged, the dashboard keeps
  showing what it showed before, and the next try is at least 15 minutes
  later.
- When the dashboard opens, if the last check (a successful background check
  counts) was more than 6 hours ago, as before; failures from this check show
  in the dashboard with a Retry link.

When a newer version is found, the menu bar menu shows **Update to X.Y.Z...**
at the top and macOS shows one notification for that version (permission is
asked the first time; if it is refused, the menu item is the only sign). Both
open the dashboard, whose **Update to X.Y.Z** button downloads, verifies,
installs and relaunches. Nothing is installed without that click.

## How a release gets its manifest

`scripts/release-manifest.py` (Python 3, standard library only, needs an
authenticated `gh`) builds the manifest for one tag:

```bash
scripts/release-manifest.py v0.1.4                 # write ./talkflow-release.json
scripts/release-manifest.py v0.1.4 --out /tmp/m.json
scripts/release-manifest.py v0.1.4 --upload        # also attach it to the release
```

It reads the release with `gh release view`, downloads each known asset with
`gh release download`, computes sha256 and size, checks them against what
GitHub records for the asset (when GitHub has a digest), and writes the file.
`--upload` runs `gh release upload --clobber`, which replaces the previous
manifest. It never creates a release or a tag and never touches another asset.
It is idempotent: running it again regenerates the whole file from what is
attached now.

Three things run it:

1. `release.sh` runs it with `--upload` right after `gh release create`, so a
   Mac-only release has a manifest immediately. If that step fails, the
   release stays published and the script prints the command to rerun.
2. `.github/workflows/release-manifest.yml` runs it with `--upload`:
   - on `release: published`;
   - on `workflow_run`, when the workflow named `Windows` completes
     successfully (that workflow attaches the Windows installers to an
     existing release, minutes after the Mac assets). It uses the run's tag
     (`head_branch`) when that is a release tag, otherwise the latest
     release;
   - by hand: Actions > Release manifest > Run workflow, with a `tag`.
   The job has `contents: write` only; the workflow's default is no
   permissions. Runs are serialized. GitHub only triggers `workflow_run` and
   `release` workflows from the copy of the file on the default branch.
3. Anyone, by hand, with the commands above.

## Adding Linux

1. Build and attach `talkflow-linux-x64.AppImage` and/or
   `talkflow-linux-arm64.AppImage` to the release (from CI or by hand).
2. Regenerate the manifest: if the Linux build comes from its own workflow,
   add that workflow's name to `workflow_run.workflows` in
   `release-manifest.yml`; otherwise run the workflow by hand with the tag.
   The generator already knows these names, so no code change is needed.
3. In the Linux app, read `platforms.linux.<arch>.update` from the manifest
   URL and verify the download's sha256 before replacing anything.

Adding another platform or file name means a row in the `ASSETS` table in
`scripts/release-manifest.py`, and an entry under `platforms` in this file.

## Verifying a release

```bash
# What the apps see:
curl -sL https://github.com/saamirkhrl/talkflow/releases/latest/download/talkflow-release.json

# Regenerate locally and compare (uploads nothing):
scripts/release-manifest.py v0.1.4 --out /tmp/m.json && cat /tmp/m.json

# Check one asset by hand:
curl -sLO https://github.com/saamirkhrl/talkflow/releases/download/v0.1.4/talkflow-macos.zip
shasum -a 256 talkflow-macos.zip

# The Mac app's parsing and version rules:
swift build && "$(swift build --show-bin-path)/talkflowd" --streamtest   # ends in ALL PASS
```
