# Code signing and permissions across updates

Status: **Option B, reusing the "TalkFlow Local Dev" certificate**, chosen by
the owner on 2026-10-09 and in effect from 0.1.8. No certificate, key or
secret exists in this repository, and none should ever be added to it.

What is in place:

- `release.sh` signs the app and its bundled engine with the certificate
  whose SHA-1 is `F38EDDA5DB8580C91C067FF8EE3AEFEF8B5F05BA`, checks the
  result's designated requirement against `RELEASE_DR`, and refuses to
  publish without that certificate. Only `--dry-run` (CI) falls back to ad hoc.
- `Updater.installBundle` installs a download that satisfies
  `Updater.releaseRequirement` exactly as published, without editing or
  re-signing it. Anything else is re-signed as before.
- The certificate's private key lives only in the owner's login keychain.
  **Export it (Keychain Access > My Certificates > TalkFlow Local Dev >
  Export, as a password-protected .p12) and keep it offline before this Mac
  is replaced.** Losing it means one more re-grant for every user; leaking it
  lets anyone ship an app macOS treats as talkflow.
- Existing users: 0.1.8 is installed by the old updater (re-signed ad hoc on
  their Macs, so one re-grant as before). 0.1.9 is installed by 0.1.8's
  updater with the release signature (one last re-grant, as the requirement
  changes from a cdhash to the stable one). From then on, updates keep every
  permission. New installs from the DMG, the zip or install.sh have the
  stable signature from the start.

The rest of this file is the analysis the choice was made from.

## The problem

After an in-app update, talkflow often stops working: setup opens again,
System Settings still shows talkflow switched on under Accessibility and
Input Monitoring, yet the app is not trusted, holding fn does nothing and no
text is typed.

### Why

macOS (TCC, the privacy database) does not remember a permission for "the app
called talkflow". It stores the *designated requirement* (DR) of the exact
code that was granted, and checks every later copy against it. System
Settings lists the entry by name, so it keeps showing the switch on even when
the running copy no longer satisfies the stored requirement.

An ad-hoc signature has no identity behind it, so its DR is the hash of the
code itself (the cdhash). Every build is a different app to macOS.

Today:

- `release.sh` signs releases ad hoc: `codesign --force --deep --sign - "$APP"`.
- `Updater.swift` (`installBundle`) re-signs the downloaded app with the local
  "talkflow Local Dev" identity when that Mac has one, otherwise ad hoc
  (`localIdentityHash ?? "-"`). Only the owner's Mac has that identity, so for
  everyone else every update changes the DR.
- `install.sh` and `deploy.sh` use the local identity when it exists, which is
  why rebuilds on the owner's Mac keep their grants.

On the owner's Mac, updates are re-signed with the local identity, so they
keep their grants once the installed copy is signed with it. A copy installed
from the release DMG (ad hoc) has a cdhash DR, so the first update re-signed
with the local identity changes the DR once.

### Evidence (checked on this Mac, scratch copies only, nothing installed)

Two copies of the same build, differing only in `CFBundleVersion`, as two
releases would:

```
ad hoc, build a:   # designated => cdhash H"9a441fbec90171cb17332a559e352f22c9f44d4c"
ad hoc, build b:   # designated => cdhash H"4cd4b9d43c16ce743480a884e7e0240545e06774"
codesign --verify -R='cdhash H"9a44..."' b/talkflow.app
                   -> code failed to satisfy specified code requirement(s)

local identity, build c: designated => identifier "com.samir.talkflow" and certificate leaf = H"f38edda5db8580c91c067ff8ee3aefef8b5f05ba"
local identity, build d: designated => identifier "com.samir.talkflow" and certificate leaf = H"f38edda5db8580c91c067ff8ee3aefef8b5f05ba"
codesign --verify -R='identifier "com.samir.talkflow" and certificate leaf = H"f38e..."' d/talkflow.app
                   -> satisfied
```

So any stable signing identity fixes it; the question is which one.

## What the app does meanwhile

Setup (Onboarding.swift, Permissions.swift) now:

- Records, per permission, the DR it was last seen granted to
  (`PermissionHistory`). When a later build is not trusted and its DR
  differs, the step says the grant belongs to an older copy instead of
  asking again from scratch. It also treats as stale a permission the user
  says is already on, or one still not applying after they come back from
  System Settings.
- Explains the fix (remove talkflow from the list with "-" and add it again
  with "+", or switch it off and on) and offers **Reset and allow again**,
  which runs `/usr/bin/tccutil reset <Accessibility|ListenEvent|Microphone>
  <talkflow's own bundle id>` and asks again. It never runs tccutil without a
  bundle id (that would reset the permission for every app).
- Opens straight on the step that needs attention after an update, and not at
  all when the grants still apply.

That makes each re-grant quick, but users still have to do it after every
update until releases have a stable identity.

## Option A: Apple Developer ID and notarization

Best experience. Costs the Apple Developer Program fee (99 USD a year).

- DR: `anchor apple generic and identifier "com.samir.talkflow" and (...)
  certificate leaf[subject.OU] = "<TEAMID>"`. It is tied to the team, so it
  stays the same across releases and across certificate renewals.
- Gatekeeper opens the app without the "unidentified developer" warning, and
  the README's "not notarized yet" note can go.
- Notarization needs the hardened runtime. talkflow then needs the
  `com.apple.security.device.audio-input` entitlement, or the microphone is
  silently denied.
- The certificate's private key lives in the owner's keychain (or as a CI
  secret). Losing it means revoking and issuing a new one; the DR is
  team-based, so users keep their grants.

Plan (not run):

```bash
# One time
xcrun notarytool store-credentials talkflow-notary \
    --apple-id "<apple id>" --team-id "<TEAMID>" --password "<app-specific password>"

# Packaging/talkflow.entitlements (new file)
#   <key>com.apple.security.device.audio-input</key><true/>

# In release.sh, in place of the ad-hoc codesign line
IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
codesign --force --deep --options runtime --timestamp \
    --entitlements Packaging/talkflow.entitlements --sign "$IDENTITY" "$APP"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile talkflow-notary --wait
xcrun stapler staple "$APP"
# then zip and build the DMG from the stapled app as today; sign, notarize and
# staple the DMG too
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile talkflow-notary --wait
xcrun stapler staple "$DMG"
```

## Option B: one persistent self-signed certificate for every release

Free. Same effect on permissions as Option A; Gatekeeper still warns on the
first open of a downloaded copy, exactly as today.

- DR: `identifier "com.samir.talkflow" and certificate leaf = H"<sha1 of the
  certificate>"`. Stable for as long as the same certificate signs every
  release. Make it long-lived (for example 20 years): a new certificate means
  one more re-grant for everyone.
- Keep the DR pinned to the certificate hash (the default). Do not pin it to
  the certificate's name: anyone can make a self-signed certificate with any
  name, and an app matching the requirement inherits talkflow's Accessibility
  and Input Monitoring grants.
- **The private key is the key to every user's grants.** Anyone holding it
  can sign an app with talkflow's bundle id that macOS treats as talkflow, so
  it would read keystrokes and type into other apps without a prompt. Keep the
  .p12 and its password offline or in a password manager; if CI signs, store
  them as an Actions secret in a protected environment. Never commit them.
- The owner can reuse the existing "talkflow Local Dev" certificate as the
  release certificate. The owner's Mac then never re-grants, and dev builds
  and releases share grants. The trade-off: the key that signs releases is the
  everyday dev key, and it must be backed up before the Mac it lives on is
  replaced.

Plan (not run):

```bash
# One time: make the certificate (or use Keychain Access > Certificate
# Assistant > Create a Certificate, Self Signed Root, Code Signing).
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
    -keyout talkflow-release.key -out talkflow-release.crt \
    -subj "/CN=talkflow Release Signing" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -inkey talkflow-release.key -in talkflow-release.crt \
    -name "talkflow Release Signing" -out talkflow-release.p12
security import talkflow-release.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
rm talkflow-release.key   # keep only the password-protected .p12, somewhere safe
shasum -a 1 < <(openssl x509 -in talkflow-release.crt -outform der)   # the leaf hash

# In release.sh, in place of the ad-hoc codesign line
IDENTITY="${TALKFLOW_RELEASE_IDENTITY:-talkflow Release Signing}"
EXPECTED_DR='identifier "com.samir.talkflow" and certificate leaf = H"<leaf sha1>"'
codesign --force --deep --sign "$IDENTITY" "$APP"
ACTUAL_DR=$(codesign -dr - "$APP" 2>/dev/null | sed -n 's/^designated => //p')
[ "$ACTUAL_DR" = "$EXPECTED_DR" ] || { echo "error: unexpected DR: $ACTUAL_DR" >&2; exit 1; }
```

## Either option: the updater must stop re-signing

`Updater.installBundle` re-signs every download. With A or B that would throw
away the release signature (and break notarization). The change (not made
yet):

1. Verify instead of sign:
   `codesign --verify --deep --strict -R="<this app's own DR>" <downloaded app>`.
   An update signed by the same identity passes; anything else is refused.
   This is also a real security gain over today's checksum-only check.
2. While the running copy is still ad hoc (its DR is a cdhash, which no new
   build can satisfy), accept a download whose DR equals the release DR
   pinned in the source, and keep its signature.
3. Remove the "talkflow Local Dev" re-signing (unless Option B reuses that
   certificate, in which case step 1 already covers it).

### What existing users see on the switch

The update is installed by the updater that is already running, which is the
old one. So:

- Release N ships the new updater. The old updater installs it and re-signs it
  ad hoc, as today: one re-grant, as today.
- Release N+1 is installed by N's updater, which keeps the release signature.
  The DR changes from a cdhash to the stable one: one more re-grant.
- From N+2 on, updates keep every permission.

Anyone who installs from the DMG or the website after N+1 gets the stable
identity straight away. In each of those re-grants, setup shows the stale
explanation and the Reset button.

## Option C: keep ad-hoc signing

No cost and no key to protect. Every update needs the three permissions
granted again; the in-app reset above makes that about a minute. This is
today's behaviour.

## Summary

| | A: Developer ID | B: self-signed | C: ad hoc |
|---|---|---|---|
| Cost | 99 USD a year | free | free |
| Permissions after updates | kept | kept | asked again every update |
| Gatekeeper on first open | no warning | warning (as today) | warning |
| Secret to protect | Developer ID key | release .p12 (critical) | none |
| Survives a new certificate | yes (team based) | no, one re-grant | n/a |
| Work | release.sh, entitlements, notarization, updater | release.sh, updater | none |
