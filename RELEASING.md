# Releasing

StupidMirror releases are built locally on macOS. GitHub Actions only runs CI;
it does not hold signing certificates or Apple credentials.

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
the commit, pushes the branch and tag, then uploads the zip to GitHub Release.
Set `COMMIT_RELEASE=false` or `PUSH_RELEASE=false` to disable those steps.

Public releases are intentionally locked to bundle ID
`com.gaojiua.StupidMirror` and Apple Team `L95PYLFT86`. Do not override either
identity: keeping both stable preserves the app's macOS privacy identity across
updates.

Before an artifact is uploaded, the release script asserts:

- the fixed bundle ID and signing Team ID;
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
- `COMMIT_RELEASE=false`: Do not auto-commit `VERSION` after a bump.
- `PUSH_RELEASE=false`: Do not push the branch and tag before uploading.
