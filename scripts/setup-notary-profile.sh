#!/usr/bin/env bash
set -euo pipefail

profile="${NOTARY_PROFILE:-stupidmirror-notary}"

if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_SPECIFIC_PASSWORD:-}" ]; then
  cat >&2 <<'MSG'
Usage:
  APPLE_ID="name@example.com" \
  TEAM_ID="TEAMID" \
  APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
  scripts/setup-notary-profile.sh

Optional:
  NOTARY_PROFILE=stupidmirror-notary

This stores credentials in your local keychain for xcrun notarytool.
Do not commit these values.
MSG
  exit 2
fi

xcrun notarytool store-credentials "$profile" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD"

echo "Stored notarytool profile: $profile"
