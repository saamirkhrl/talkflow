#!/usr/bin/env python3
"""Writes talkflow-release.json for one GitHub release, from the assets on it.

Every talkflow app (macOS, Windows, later Linux) asks one URL for updates:

    https://github.com/saamirkhrl/talkflow/releases/latest/download/talkflow-release.json

This script builds that file. It reads the release with `gh`, downloads each
known asset (the table below), records its sha256 and size, and writes the
manifest. A platform or architecture appears only when its asset is attached.
See docs/releases.md for the schema.

    scripts/release-manifest.py v0.1.4                # write ./talkflow-release.json
    scripts/release-manifest.py v0.1.4 --upload       # ...and attach it to the release
    scripts/release-manifest.py v0.1.4 --out m.json   # write somewhere else

Idempotent: run it again after more assets are attached (the Windows
installers arrive from CI minutes after the Mac release exists) and it
regenerates the whole file, replacing the old one with `--clobber`. It never
creates a release and never touches any asset other than the manifest.

Standard library only; needs the GitHub CLI (`gh`), authenticated.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

MANIFEST_NAME = "talkflow-release.json"
SCHEMA = 1
DEFAULT_REPO = "saamirkhrl/talkflow"
NOTES_LIMIT = 2000

# Asset name -> (platform, arch, roles). "update" is what an installed app
# downloads to update itself; "installer" is what a new user downloads. On
# Windows and Linux one file is both. Names are fixed: the website links to
# releases/latest/download/<name>.
ASSETS = {
    "talkflow-macos.zip": ("macos", "universal", ("update",)),
    "talkflow-macos.dmg": ("macos", "universal", ("installer",)),
    "talkflow-windows-x64-setup.exe": ("windows", "x64", ("update", "installer")),
    "talkflow-windows-arm64-setup.exe": ("windows", "arm64", ("update", "installer")),
    # Reserved: picked up automatically the first time a release carries them.
    "talkflow-linux-x64.AppImage": ("linux", "x64", ("update", "installer")),
    "talkflow-linux-arm64.AppImage": ("linux", "arm64", ("update", "installer")),
}
PLATFORMS = ("macos", "windows", "linux")

TAG_PATTERN = re.compile(r"^v(\d+\.\d+\.\d+)$")


def gh(*args, capture=True):
    result = subprocess.run(["gh", *args], capture_output=capture, text=True)
    if result.returncode != 0:
        detail = (result.stderr or "").strip() if capture else ""
        sys.exit(f"error: gh {' '.join(args)} failed{': ' + detail if detail else ''}")
    return result.stdout if capture else ""


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def plain_notes(body):
    """The release body as short plain text: markdown emphasis and link syntax
    dropped, trimmed to NOTES_LIMIT characters."""
    text = (body or "").replace("\r\n", "\n").strip()
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", text)
    text = re.sub(r"(\*\*|__|`)", "", text)
    text = re.sub(r"^#+\s*", "", text, flags=re.MULTILINE)
    if len(text) > NOTES_LIMIT:
        text = text[: NOTES_LIMIT - 3].rstrip() + "..."
    return text


def build_manifest(repo, tag, workdir):
    match = TAG_PATTERN.match(tag)
    if not match:
        sys.exit(f"error: {tag!r} is not a release tag like v1.2.3")
    release = json.loads(gh("release", "view", tag, "--repo", repo,
                            "--json", "tagName,url,body,publishedAt,createdAt,assets"))
    attached = {asset["name"]: asset for asset in release.get("assets", [])}

    platforms = {name: {} for name in PLATFORMS}
    for name, (platform, arch, roles) in ASSETS.items():
        asset = attached.get(name)
        if asset is None:
            continue
        gh("release", "download", tag, "--repo", repo, "--pattern", name,
           "--dir", workdir, "--clobber")
        path = os.path.join(workdir, name)
        sha256 = sha256_of(path)
        size = os.path.getsize(path)
        # GitHub records its own digest for newer uploads: a mismatch means
        # the download was not the file that is attached.
        recorded = (asset.get("digest") or "").lower()
        if recorded.startswith("sha256:") and recorded[len("sha256:"):] != sha256:
            sys.exit(f"error: {name} downloaded with sha256 {sha256}, GitHub records {recorded}")
        if asset.get("size") not in (None, size):
            sys.exit(f"error: {name} downloaded as {size} bytes, GitHub records {asset['size']}")
        url = asset.get("url") or f"https://github.com/{repo}/releases/download/{tag}/{name}"
        entry = {"name": name, "url": url, "sha256": sha256, "size": size}
        slot = platforms[platform].setdefault(arch, {})
        for role in roles:
            slot[role] = dict(entry)
        print(f"  {platform}/{arch} {'+'.join(roles)}: {name} {size} bytes sha256 {sha256}", file=sys.stderr)

    if not any(platforms.values()):
        print(f"warning: {tag} has none of the known assets; the manifest lists no builds", file=sys.stderr)

    return {
        "schema": SCHEMA,
        "version": match.group(1),
        "tag": tag,
        "published": release.get("publishedAt") or release.get("createdAt"),
        "notesUrl": release.get("url") or f"https://github.com/{repo}/releases/tag/{tag}",
        "notes": plain_notes(release.get("body")),
        "platforms": platforms,
    }


def main():
    parser = argparse.ArgumentParser(description="Write talkflow-release.json for a GitHub release.")
    parser.add_argument("tag", help="release tag, e.g. v0.1.4")
    parser.add_argument("--repo", default=os.environ.get("GH_REPO") or DEFAULT_REPO,
                        help=f"owner/name (default: $GH_REPO or {DEFAULT_REPO})")
    parser.add_argument("--out", help=f"where to write the manifest (default: ./{MANIFEST_NAME})")
    parser.add_argument("--upload", action="store_true",
                        help="attach the manifest to the release, replacing any previous one")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="talkflow-manifest-") as workdir:
        manifest = build_manifest(args.repo, args.tag, workdir)
        text = json.dumps(manifest, indent=2) + "\n"
        out = args.out or MANIFEST_NAME
        with open(out, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"wrote {out}", file=sys.stderr)

        if args.upload:
            # The uploaded asset takes the file's name, so upload a copy that
            # is named exactly MANIFEST_NAME whatever --out was.
            upload = os.path.join(workdir, MANIFEST_NAME)
            with open(upload, "w", encoding="utf-8") as handle:
                handle.write(text)
            gh("release", "upload", args.tag, upload, "--repo", args.repo, "--clobber")
            print(f"uploaded {MANIFEST_NAME} to {args.repo} {args.tag}", file=sys.stderr)


if __name__ == "__main__":
    main()
