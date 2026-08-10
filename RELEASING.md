# Releasing

StupidMirror releases are built locally on macOS. GitHub Actions only runs CI;
it does not hold signing certificates or Apple credentials.

The source repository may remain private. That does not prevent GitHub Actions
from running CI, but every signed distribution build is still created,
notarized, and uploaded from the release Mac. A Release in a private repository
is downloadable only by GitHub users who have read access. If customer downloads
must be public later, publish the notarized zip to a separate binary-only public
repository or download host; do not make the source repository public.

## One-Time Setup

1. Install and authenticate GitHub CLI:

   ```sh
   gh auth login
   ```

2. Make sure a Developer ID Application certificate is installed in Keychain:

   ```sh
   security find-identity -v -p codesigning
   ```

3. Store Apple notarization credentials in Keychain:

   ```sh
   APPLE_ID="name@example.com" \
   TEAM_ID="L95PYLFT86" \
   APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
   scripts/setup-notary-profile.sh
   ```

## Release

Patch release:

```sh
NOTARY_PROFILE=stupidmirror-notary make release-local BUMP=patch
```

Specific version:

```sh
NOTARY_PROFILE=stupidmirror-notary make release-local BUMP=0.2.0
```

Public GitHub releases must be notarized. Without `NOTARY_PROFILE`, the release
script refuses to upload because downloaded, quarantined apps can be blocked by
Gatekeeper even when they are Developer ID signed. For private/local test builds
only, set `ALLOW_UNNOTARIZED=true`.

When `BUMP` is set, the script updates `VERSION`, commits `Release vX.Y.Z`, tags
the commit, pushes the branch and tag, verifies that the tag on `origin` points
to the packaged commit, then uploads the zip to GitHub Release.

`BUMP` requires `COMMIT_RELEASE=true`; otherwise the tag would not record the
version packaged in the artifact, so the script rejects that combination.
Set `PUSH_RELEASE=false` for a local-only run: the signed artifact and local tag
are created, but nothing is pushed and no GitHub Release is created or updated.

Public releases are intentionally locked to bundle ID
`com.gaojiua.StupidMirror` and Apple Team `L95PYLFT86`. Do not override either
identity: keeping both stable preserves the app's macOS privacy identity across
updates.

Before an artifact is uploaded, the release script asserts:

- the fixed bundle ID and signing Team ID;
- the fixed HTTPS license endpoint and non-secret Supabase publishable key;
- non-empty Camera and Microphone usage descriptions in the base, English, and
  Simplified Chinese resources;
- Camera and audio-input entitlements on the app;
- explicit valid signatures on bundled Node and native helpers, plus Node JIT
  entitlements;
- sealed resources, notarization and stapling, Gatekeeper assessment, and
  `syspolicy_check distribution`.

## Useful Environment Variables

- `SIGN_IDENTITY`: Developer ID Application certificate for Team `L95PYLFT86`.
  Auto-detected if omitted.
- `ENTITLEMENTS`: Entitlements plist for signing. Defaults to `StupidMirror.entitlements`.
- `NODE_ENTITLEMENTS`: Entitlements for bundled Node. Defaults to
  `NodeRuntime.entitlements`; it must retain the required JIT permissions.
- `VERSION`: Override version without editing `VERSION`.
- `BUILD_NUMBER`: Override build number. Defaults to a timestamp.
- `NOTARY_PROFILE`: Keychain profile for `xcrun notarytool`.
- `ALLOW_UNNOTARIZED=true`: Allow uploading a non-notarized build. Use only for
  private testing.
- `DRAFT=true`: Create a draft GitHub Release.
- `PRERELEASE=true`: Mark the GitHub Release as a prerelease.
- `ALLOW_DIRTY=true`: Allow release with uncommitted working tree changes.
- `COMMIT_RELEASE=false`: Allowed only without `BUMP`; `BUMP` must commit the
  updated `VERSION` before tagging.
- `PUSH_RELEASE=false`: Keep the artifact and tag local; skip all pushes and
  GitHub Release creation or upload.
