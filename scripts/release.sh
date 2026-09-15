#!/bin/bash
# Build, package, and publish a Carryover release to GitHub.
#
# Usage: scripts/release.sh <version>        e.g. scripts/release.sh 1.0.0
#
# Produces an ad-hoc signed (not notarized) app zip and creates a GitHub
# release tagged v<version> with auto-generated notes. Requires the `gh` CLI
# authenticated against the repo.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."

BUILD_DIR=build
APP="$BUILD_DIR/Build/Products/Release/Carryover.app"
ZIP="Carryover-$VERSION.zip"

xcodebuild -project Carryover.xcodeproj \
    -scheme Carryover \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY=- \
    MARKETING_VERSION="$VERSION" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    clean build

# ditto preserves the app bundle structure and resource forks, unlike zip.
ditto -c -k --keepParent "$APP" "$ZIP"

gh release create "v$VERSION" "$ZIP" \
    --title "Carryover $VERSION" \
    --generate-notes

echo "Released v$VERSION"
