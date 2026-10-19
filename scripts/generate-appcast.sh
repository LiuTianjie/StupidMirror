#!/usr/bin/env bash
# Writes the Sparkle appcast for a notarized release archive.
#
# Usage: scripts/generate-appcast.sh <tag> <archive.zip> [output.xml]
#
# The archive is signed with the EdDSA key stored in the login keychain under
# the Sparkle account "stupidmirror" (created once with
# `.build/sparkle-tools/<version>/bin/generate_keys --account stupidmirror`).
# The feed points at the GitHub Release asset, so publish it only after that
# release is public: docs/updates/appcast.xml is what installed apps read.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tag="${1:?usage: scripts/generate-appcast.sh <tag> <archive.zip> [output.xml]}"
archive="${2:?usage: scripts/generate-appcast.sh <tag> <archive.zip> [output.xml]}"
output="${3:-dist/releases/appcast-${tag}.xml}"
keychain_account="${SPARKLE_KEYCHAIN_ACCOUNT:-stupidmirror}"
repository="${GITHUB_REPOSITORY:-LiuTianjie/StupidMirror}"

[ -f "$archive" ] || { echo "Archive not found: $archive" >&2; exit 1; }
version="${tag#v}"

tools="$(bash scripts/sparkle-tools.sh)"

# Read the bundle's own version numbers: Sparkle compares CFBundleVersion.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$archive" "$work"
info="${work}/StupidMirror.app/Contents/Info.plist"
[ -f "$info" ] || { echo "The archive does not contain StupidMirror.app" >&2; exit 1; }
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info" 2>/dev/null || true)"
if [ "$short_version" != "$version" ]; then
  echo "Archive version ${short_version} does not match tag ${tag}." >&2
  exit 1
fi
if [ -z "$public_key" ]; then
  echo "The archived app has no SUPublicEDKey; it was not built for updates." >&2
  exit 1
fi

# `sign_update` prints: sparkle:edSignature="..." length="..."
signature_attributes="$("${tools}/bin/sign_update" --account "$keychain_account" "$archive")"
case "$signature_attributes" in
  *'sparkle:edSignature="'*'length="'*) ;;
  *) echo "sign_update did not return a signature: ${signature_attributes}" >&2; exit 1 ;;
esac
# The signing key must belong to the public key the app trusts.
if ! "${tools}/bin/sign_update" --account "$keychain_account" --verify "$archive" \
  "$(printf '%s' "$signature_attributes" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')" \
  >/dev/null 2>&1; then
  echo "The archive signature does not verify with the keychain key." >&2
  exit 1
fi
keychain_public_key="$("${tools}/bin/generate_keys" --account "$keychain_account" -p)"
if [ "$keychain_public_key" != "$public_key" ]; then
  echo "Keychain key ${keychain_account} does not match the app's SUPublicEDKey." >&2
  exit 1
fi

download_url="https://github.com/${repository}/releases/download/${tag}/$(basename "$archive")"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
notes_script="${work}/release-notes.py"
cat > "$notes_script" <<'PY'
import html, re, sys
version = sys.argv[1]
text = open("CHANGELOG.md", encoding="utf-8").read()
match = re.search(r"^## " + re.escape(version) + r"\b.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
if not match:
    sys.exit(f"CHANGELOG.md has no section for {version}")
items, current = [], None
for line in match.group(1).splitlines():
    if line.startswith("- "):
        current = [line[2:].strip()]
        items.append(current)
    elif line.strip() and current is not None:
        current.append(line.strip())
def render(parts):
    escaped = html.escape(" ".join(parts))
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
print("<ul>" + "".join(f"<li>{render(item)}</li>" for item in items) + "</ul>")
PY
release_notes="$(/usr/bin/python3 "$notes_script" "$version")"

mkdir -p "$(dirname "$output")"
cat > "$output" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>StupidMirror</title>
    <link>https://liutianjie.github.io/StupidMirror/updates/appcast.xml</link>
    <description>StupidMirror updates</description>
    <language>en</language>
    <item>
      <title>StupidMirror ${short_version}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${build_version}</sparkle:version>
      <sparkle:shortVersionString>${short_version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${minimum_system}</sparkle:minimumSystemVersion>
      <description><![CDATA[${release_notes}]]></description>
      <enclosure url="${download_url}" type="application/octet-stream" ${signature_attributes} />
    </item>
  </channel>
</rss>
XML
/usr/bin/xmllint --noout "$output"
echo "$output"
