#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo "Build this release on Apple silicon." >&2; exit 1; }
./script/build_and_run.sh build
bin="${SWIFTPM_BUILD_DIR:-.build}/artifacts/sparkle/Sparkle/bin"
app="dist/Bliss Studio.app"
plist="$app/Contents/Info.plist"
value() { /usr/bin/plutil -extract "$1" raw "$plist"; }
account="$(value CFBundleIdentifier)"
[[ "$("$bin/generate_keys" --account "$account" -p)" == "$(value SUPublicEDKey)" ]] || {
    echo "The release key in Keychain must match SUPublicEDKey." >&2
    exit 1
}
version="$(value CFBundleShortVersionString)"
archive="Bliss-Studio-macOS-arm64.zip"
url="https://github.com/itsasheruwu/bliss-studio/releases/download/v$version/$archive"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$archive"
signature="$("$bin/sign_update" --account "$account" -p "$stage/$archive")"
"$bin/sign_update" --account "$account" --verify "$stage/$archive" "$signature"
cat > "$stage/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Bliss Studio</title>
    <sparkle:bundleIdentifier>$account</sparkle:bundleIdentifier>
    <item>
      <title>Bliss Studio $version</title>
      <sparkle:version>$(value CFBundleVersion)</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(value LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      <enclosure url="$url" type="application/octet-stream" length="$(stat -f %z "$stage/$archive")" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
"$bin/sign_update" --account "$account" "$stage/appcast.xml"
"$bin/sign_update" --account "$account" --verify "$stage/appcast.xml"
mv "$stage/$archive" "$stage/appcast.xml" dist/
