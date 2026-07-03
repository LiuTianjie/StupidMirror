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
   TEAM_ID="TEAMID" \
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

Without `NOTARY_PROFILE`, the script still builds, signs, zips, and uploads, but
skips Apple notarization.

When `BUMP` is set, the script updates `VERSION`, commits `Release vX.Y.Z`, tags
the commit, pushes the branch and tag, then uploads the zip to GitHub Release.
Set `COMMIT_RELEASE=false` or `PUSH_RELEASE=false` to disable those steps.

## Useful Environment Variables

- `SIGN_IDENTITY`: Developer ID Application certificate name. Auto-detected if omitted.
- `BUNDLE_ID`: Bundle identifier. Defaults to `dev.stupidmirror.app`.
- `VERSION`: Override version without editing `VERSION`.
- `BUILD_NUMBER`: Override build number. Defaults to a timestamp.
- `NOTARY_PROFILE`: Keychain profile for `xcrun notarytool`.
- `DRAFT=true`: Create a draft GitHub Release.
- `PRERELEASE=true`: Mark the GitHub Release as a prerelease.
- `ALLOW_DIRTY=true`: Allow release with uncommitted working tree changes.
- `COMMIT_RELEASE=false`: Do not auto-commit `VERSION` after a bump.
- `PUSH_RELEASE=false`: Do not push the branch and tag before uploading.
