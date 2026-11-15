# Releasing

Publishing a GitHub release runs `.github/workflows/release.yml`, which builds
Archipel and attaches `Archipel-<version>.dmg` to the release. Prereleases and
releases work the same way. There is no auto-update, so people install a new
version by downloading the DMG again.

## Cutting a release

1. Create a release with a tag like `v0.2.0`, or `v0.2.0-beta.1` for a
   prerelease. The version in the app comes from the tag.
2. Publish it. The DMG shows up on the release once the workflow finishes.
   The first run takes longer, because GhosttyKit has to be built once before
   it is cached.

To try the pipeline without a release, run the workflow by hand from the
Actions tab (`gh workflow run release.yml`). The DMG is then a workflow
artifact named `Archipel-0.0.0-dev.<run>`.

The build number (`CFBundleVersion`) is the workflow run number.

To build the same DMG locally:

```sh
./scripts/build-dmg.sh 0.2.0      # writes .build/dmg/Archipel-0.2.0.dmg
```

## Signing

The workflow runs without any secrets. The DMG is then signed ad-hoc, and
macOS refuses to open it on first launch. To open it anyway, go to System
Settings > Privacy & Security and click Open Anyway, or remove the quarantine
flag:

```sh
xattr -dr com.apple.quarantine /Applications/Archipel.app
```

For a DMG that opens without a warning, the workflow needs a Developer ID
certificate and a notarization key. It uses them as soon as they are set.

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
Gatekeeper blocks it the same way as an ad-hoc one.

## Runner

The workflow runs on the `xcode-27` image (macOS 27, Xcode 27), which GitHub
still lists as a preview. The `macos-26` images only have Xcode 26, which
can't build for the macOS 27 deployment target. Once a `macos-27` image is
generally available, switch `runs-on` to it.
