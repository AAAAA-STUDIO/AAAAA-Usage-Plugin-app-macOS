#!/bin/bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SOURCE_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$BUILD_DIR/用量监控.app"
PRODUCT_PATH="$DERIVED_DATA/Build/Products/Release/用量监控.app"

xcodebuild \
  -quiet \
  -project "$SOURCE_DIR/AAAAAUsage.xcodeproj" \
  -scheme "用量监控" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  build

rm -rf "$APP_PATH"
ditto "$PRODUCT_PATH" "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
