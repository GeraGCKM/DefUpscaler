#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Packaging requires macOS and Xcode command line tools.' >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "This package targets Apple Silicon; build on an arm64 Mac." >&2
    exit 1
fi
swift build -c release
APP="$PWD/build/DefUpscaler.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DefUpscaler "$APP/Contents/MacOS/"
cp packaging/Info.plist "$APP/Contents/Info.plist"
xcrun coremlcompiler compile build/models/Anime4x.mlpackage "$APP/Contents/Resources"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp build/models/model-provenance.json "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" build/DefUpscaler-macOS-AppleSilicon.zip
shasum -a 256 build/DefUpscaler-macOS-AppleSilicon.zip > build/SHA256SUMS.txt
