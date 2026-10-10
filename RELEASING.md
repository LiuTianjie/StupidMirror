# Releasing

StupidMirror releases are built locally on macOS. GitHub Actions only runs CI;
it does not hold signing certificates or Apple credentials.

The source repository is published under the PolyForm Noncommercial License.
Every signed distribution build is created, notarized, and uploaded from the
release Mac. Personal and other noncommercial use is licensed by `LICENSE`;
commercial distribution or use requires a separate written commercial license.

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

## Prepare a release

Final publication is a manual maintainer action. The script defaults to a local
signed/notarized artifact and tag. It never publishes a GitHub Release. The
website deploys automatically from `main/docs`, so prepare changes on a release
branch and open a PR; do not push main during preparation.

1. Update `VERSION`, `CHANGELOG.md`, both READMEs, and website copy/translations.
2. Rebuild and test the widget, test both Go sidecars, and run Swift tests.
3. Commit all release source on a `codex/` release branch.
4. Build and notarize (the existing version must match the tag):

   ```sh
   NOTARY_PROFILE=stupidmirror-notary COMMIT_RELEASE=false PUSH_RELEASE=false \
     bash scripts/build-and-upload-release.sh v0.3.0
   ```

5. Push the release branch and exact tag, create a PR, wait for CI, then create
   a **draft** Release and upload the zip and SHA-256 checksums. Alternatively,
   `PUSH_RELEASE=true` on the release branch prepares a draft; published releases
   are protected from artifact replacement. Use a notes file with `gh --notes-file`.
6. Verify uploaded asset size/digest and complete real-host/device acceptance.
7. The maintainer personally merges the PR (deploying Pages) and publishes the
   draft Release. Preparation does not count as either of these actions.

Apple notarization is mandatory for distribution. Without `NOTARY_PROFILE`, the
script refuses to continue unless `ALLOW_UNNOTARIZED=true` is explicitly used
for a private test build. Do not publish that build. After upload verification,
clean this run's duplicate artifacts and temporary build data; retain source,
installed apps, shared caches, and remote artifacts.

Public releases are intentionally locked to bundle ID
`com.gaojiua.StupidMirror` and Apple Team `L95PYLFT86`. Do not override either
identity: keeping both stable preserves the app's macOS privacy identity across
updates.

Before an artifact is uploaded, the release script asserts:

- the fixed bundle ID and signing Team ID;
- the fixed HTTPS license endpoint and non-secret Supabase publishable key;
- a non-empty Camera usage description in the base, English, and Simplified
  Chinese resources;
- the Camera entitlement on the app;
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
- `DRAFT=true`: Default and required for uploads; publishing is always manual.
- `PRERELEASE=true`: Mark the GitHub Release as a prerelease.
- `ALLOW_DIRTY=true`: Allow release with uncommitted working tree changes.
- `COMMIT_RELEASE=false`: Allowed only without `BUMP`; `BUMP` must commit the
  updated `VERSION` before tagging.
- `PUSH_RELEASE=false`: Default. Keep the artifact and tag local; skip all pushes and
  GitHub Release creation or upload.
