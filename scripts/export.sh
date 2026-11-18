#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) Release Clarion.app and zips it for sharing.
# Signed ad hoc unless you set a team in Xcode; see README for Developer ID notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

# Archive in a temp folder so the only Clarion.app left behind is export/Clarion.app.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/Clarion.xcarchive"
xcodebuild -project Clarion.xcodeproj -scheme Clarion -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$WORK/dd" archive -quiet

mkdir -p export
rm -rf export/Clarion.app export/Clarion.zip
ditto "$ARCHIVE/Products/Applications/Clarion.app" export/Clarion.app
# The shareable zip: a "Clarion" folder with the app and the friend-facing guide.
mkdir -p "$WORK/Clarion"
ditto export/Clarion.app "$WORK/Clarion/Clarion.app"
cp "packaging/How to open Clarion.txt" "$WORK/Clarion/"
ditto -c -k --keepParent "$WORK/Clarion" export/Clarion.zip

echo "App:  export/Clarion.app ($(lipo -archs export/Clarion.app/Contents/MacOS/Clarion))"
echo "Zip:  export/Clarion.zip ($(du -h export/Clarion.zip | cut -f1))"
