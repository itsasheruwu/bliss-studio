#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-run}"
sdk="$(xcrun --sdk macosx --show-sdk-version)"
build="${SWIFTPM_BUILD_DIR:-.build}"
args=(--scratch-path "$build" -Xlinker -rpath -Xlinker @executable_path/../Frameworks -c release -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$sdk")
swift build "${args[@]}" --product BlissStudio
bin="$(swift build "${args[@]}" --show-bin-path)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Bliss Studio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" dist
cp "$bin/BlissStudio" "$app/Contents/MacOS/"
ditto --norsrc --noextattr "$bin/BlissStudio_BlissStudio.bundle" "$app/Contents/Resources/BlissStudio_BlissStudio.bundle"
sparkle="$build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto --norsrc --noextattr "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/"
ditto --norsrc --noextattr Notices "$app/Contents/Resources/Notices"
cp "$build/checkouts/Sparkle/LICENSE" "$app/Contents/Resources/Notices/SPARKLE-LICENSE"
codesign --force --sign - --entitlements Packaging/BlissStudio.entitlements "$app"
codesign --verify --deep --strict "$app"
if [[ "$mode" != build ]]; then
    pkill -TERM -x BlissStudio || true
fi
ditto --norsrc --noextattr "$app" "dist/Bliss Studio.app"
if [[ "$mode" != build ]]; then
    open -n "dist/Bliss Studio.app"
fi
