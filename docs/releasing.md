# Releasing

Publishing a GitHub release runs `.github/workflows/release.yml`, which runs
the UI tests, then builds Archipel and attaches `Archipel-<version>.dmg` to the
release. If the tests fail, no DMG is built and the appcast is left alone.
When the signing secrets below are set, the DMG is signed with Developer ID,
notarized, and added to the [Sparkle](https://sparkle-project.org) appcast at
`https://<owner>.github.io/<repo>/appcast.xml`, so installed copies update
themselves.

The appcast is deployed by `.github/workflows/pages.yml`, which rebuilds it
from all releases each time. Every signed release carries an
`appcast-item.json` with the update's signature and size, and the release
notes are read from the release itself. Editing or deleting a release
redeploys the appcast, so fixed release notes reach the update window too. To
redeploy by hand, run `gh workflow run pages.yml`.

There are two channels in that one appcast:

| GitHub release | Tag example     | Appcast channel | Who gets it                                  |
| -------------- | --------------- | --------------- | -------------------------------------------- |
| Prerelease     | `v0.3.0-beta.1` | `beta`          | Users with "Include beta versions" turned on |
| Release        | `v0.3.0`        | none (stable)   | Everyone                                     |

The workflow refuses a prerelease without a `-suffix` and a release with one.
The app turns beta updates on by default when its own version has a suffix, so
anyone who installs a beta DMG stays on the beta channel until they switch it
off in Settings > General > Updates.

## Cutting a release

1. Create a release with a tag like `v0.2.0`, or `v0.2.0-beta.1` with "Set as
   a pre-release" ticked. The version in the app comes from the tag.
2. Write the release notes. They are shown in the update window, rendered from
   Markdown.
3. Publish. The DMG shows up on the release once the workflow finishes. The
   first run takes longer, because GhosttyKit has to be built once before it
   is cached. Installed copies pick the update up on their next daily check,
   or straight away with Archipel > Check for Updates….

The build number (`CFBundleVersion`) is the workflow run number, and that is
what Sparkle compares. Versions in the tag are only for people. So if you ship
a stable `0.2.1` hotfix after `0.3.0-beta.1`, beta users are offered `0.2.1`
too, since it was built later.

To try the pipeline without a release, run the workflow by hand from the
Actions tab (`gh workflow run release.yml`). The DMG is then a workflow
artifact named `Archipel-0.0.0-dev.<run>`, the appcast is left alone, and the
UI tests are skipped.

To build the same DMG locally:

```sh
./scripts/build-dmg.sh 0.2.0      # writes .build/dmg/Archipel-0.2.0.dmg
```

This needs [uv](https://docs.astral.sh/uv/) (`brew install uv`) for
`dmgbuild`. The window layout is in `scripts/dmg/settings.py`, and the
background is drawn by `scripts/dmg/make-background.swift`. If you change one,
check the icon positions still match the other, then regenerate the background:

```sh
swift scripts/dmg/make-background.swift scripts/dmg/background.tiff
```

## Signing

The workflow runs without any secrets. The app is then signed ad-hoc, macOS
refuses to open it on first launch, and the release is not added to the
appcast. To open such a build anyway, go to System Settings > Privacy &
Security and click Open Anyway, or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Archipel.app
```

For a DMG that opens without a warning and reaches installed copies through
Sparkle, set up everything below. The workflow uses the secrets as soon as
they are set.

### 1. Team ID

```sh
gh variable set APPLE_TEAM_ID --body ABCDE12345
```

The team ID is not a secret (it is in the signature of every app you ship),
so it is a repository variable.

### 2. Developer ID certificate

Needs the paid Apple Developer Program.

1. Create a **Developer ID Application** certificate under Certificates,
   Identifiers & Profiles (or Xcode > Settings > Accounts > Manage
   Certificates > + > Developer ID Application).
2. Export it from Keychain Access with its private key as a `.p12` with a
   password.
3. Store both:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
   gh secret set DEVELOPER_ID_P12_PASSWORD
   ```

### 3. Notarization API key

In App Store Connect > Users and Access > Integrations > App Store Connect API,
create a team key with the **Developer** role and download the `.p8` file (you
can only download it once).

```sh
gh secret set NOTARY_API_KEY < AuthKey_XXXXXXXXXX.p8
gh secret set NOTARY_KEY_ID      # the key ID, e.g. XXXXXXXXXX
gh secret set NOTARY_ISSUER_ID   # the issuer ID shown above the keys list
```

Without the notarization key the DMG is still signed with Developer ID, but
Gatekeeper blocks it the same way as an ad-hoc one, and it is not added to the
appcast.

### 4. Sparkle signing key

Sparkle rejects any update that isn't signed with this key. Back up the
private key somewhere safe: if you lose it, installed copies can't update
anymore.

```sh
xcodebuild -resolvePackageDependencies -project Archipel.xcodeproj
bin=$(echo ~/Library/Developer/Xcode/DerivedData/Archipel-*/SourcePackages/artifacts/sparkle/Sparkle/bin)
"$bin/generate_keys"                     # stores the key in your login keychain, prints the public key
"$bin/generate_keys" -x sparkle-key.txt  # exports the private key for CI
```

Put the printed public key into `SUPublicEDKey` in `Archipel/Info.plist`. The
workflow refuses to publish to the appcast while it is still the placeholder.
Then store the private key as a secret and delete the file:

```sh
gh secret set SPARKLE_PRIVATE_KEY < sparkle-key.txt && rm sparkle-key.txt
```

### 5. GitHub Pages

Set Pages to deploy from GitHub Actions:

```sh
gh api -X PUT "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pages" -f build_type=workflow
```

Or use Settings > Pages > Source > GitHub Actions.

Release runs deploy from the tag, not from `main`, so the `github-pages`
environment also has to allow tags:

```sh
gh api -X POST "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/environments/github-pages/deployment-branch-policies" \
  -f name='v*' -f type=tag
```

Or add a `v*` tag rule under Settings > Environments > github-pages.

### Forks

`SUFeedURL` and `SUPublicEDKey` in `Archipel/Info.plist` point at this repo's
appcast. If you ship releases from a fork, change both to your own, or your
builds will update to the ones from this repo.

## Runner

The workflow runs on the `xcode-27` image (macOS 27, Xcode 27), which GitHub
still lists as a preview. The `macos-26` images only have Xcode 26, which
can't build for the macOS 27 deployment target. Once a `macos-27` image is
generally available, switch `runs-on` to it.

## Debug builds

Sparkle is not started in Debug builds. They carry build number 1, so every
release would look newer and Sparkle would offer to replace the build you are
working on. Build a DMG with `scripts/build-dmg.sh` to try updating locally.
