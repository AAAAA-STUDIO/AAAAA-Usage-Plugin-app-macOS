#!/bin/bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$SOURCE_DIR/build"
ARTWORK="$SOURCE_DIR/Resources/installer-background.png"
APP_NAME="用量监控"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
STAGE_DIR="$BUILD_DIR/release-stage"
MOUNT_POINT=""
MOUNTED=0

usage() {
  cat <<'USAGE'
Usage: ./Scripts/publish-release.sh <version> [release-notes.md]

The version must match CFBundleShortVersionString in Info.plist. Run from a
clean main branch after committing the changes that should be published.
USAGE
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ "$MOUNTED" -eq 1 && -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
}
trap cleanup EXIT INT TERM

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  usage >&2
  exit 2
fi

VERSION="$1"
NOTES_SOURCE="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  fail "Version must look like 0.1.3 or 0.2.0-beta.1."
fi

for tool in xcodebuild hdiutil swift gh shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required command not found: $tool"
done

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_DIR/Info.plist")"
[[ "$VERSION" == "$PLIST_VERSION" ]] || fail "Requested version $VERSION does not match Info.plist version $PLIST_VERSION."
[[ -f "$ARTWORK" ]] || fail "Installer artwork is missing: $ARTWORK"
if [[ -n "$NOTES_SOURCE" && ! -f "$NOTES_SOURCE" ]]; then
  fail "Release notes file not found: $NOTES_SOURCE"
fi

cd "$SOURCE_DIR"
BRANCH="$(git branch --show-current)"
[[ "$BRANCH" == "main" ]] || fail "Publish from main; current branch is $BRANCH."
git diff --quiet && git diff --cached --quiet || fail "Commit tracked changes before publishing. Untracked local files are ignored and will not be included."
gh auth status --hostname github.com >/dev/null 2>&1 || fail "Authenticate GitHub CLI first with: gh auth login"

git fetch origin main --tags
git rev-parse --verify origin/main >/dev/null 2>&1 || fail "origin/main is unavailable."
git merge-base --is-ancestor origin/main HEAD || fail "Local main is behind or has diverged from origin/main; synchronize it before publishing."

TAG="v$VERSION"
if git show-ref --verify --quiet "refs/tags/$TAG" || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  fail "Tag $TAG already exists; choose a new version."
fi

mkdir -p "$BUILD_DIR"
"$SOURCE_DIR/build-app.sh"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "Built app version $APP_VERSION does not match $VERSION."

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/.background"
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

BACKGROUND="$STAGE_DIR/.background/installer-background.png"
if [[ "$VERSION" == "0.1.2" ]]; then
  ditto "$ARTWORK" "$BACKGROUND"
else
  mkdir -p "$BUILD_DIR/SwiftModuleCache"
  CLANG_MODULE_CACHE_PATH="$BUILD_DIR/SwiftModuleCache" \
    swift "$SOURCE_DIR/Scripts/stamp-installer-version.swift" "$ARTWORK" "$VERSION" "$BACKGROUND"
fi

VOL_NAME="$APP_NAME $VERSION"
RW_DMG="$BUILD_DIR/.UsageMonitor-$VERSION-rw.dmg"
DMG_PATH="$BUILD_DIR/UsageMonitor-$VERSION-macOS.dmg"
CHECKSUM_PATH="$BUILD_DIR/UsageMonitor-$VERSION-macOS.dmg.sha256"
NOTES_PATH="$BUILD_DIR/.release-notes-$VERSION.md"
MOUNT_POINT="$BUILD_DIR/.mount-$VERSION"
rm -f "$RW_DMG" "$DMG_PATH" "$CHECKSUM_PATH" "$NOTES_PATH"
mkdir -p "$MOUNT_POINT"

hdiutil create -quiet -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -fs HFS+ -format UDRW "$RW_DMG"
hdiutil attach -quiet -readwrite -noverify -nobrowse -mountpoint "$MOUNT_POINT" "$RW_DMG"
MOUNTED=1

osascript - "$MOUNT_POINT" "$VOL_NAME" <<'APPLESCRIPT'
on run argv
  set mountPoint to item 1 of argv
  set volumeName to item 2 of argv
  tell application "Finder"
    set installerDisk to disk volumeName
    open installerDisk
    delay 1
    set installerWindow to container window of installerDisk
    set current view of installerWindow to icon view
    set toolbar visible of installerWindow to false
    set statusbar visible of installerWindow to false
    set bounds of installerWindow to {100, 100, 1000, 650}
    set iconOptions to icon view options of installerWindow
    set arrangement of iconOptions to not arranged
    set icon size of iconOptions to 96
    set background picture of iconOptions to (POSIX file (mountPoint & "/.background/installer-background.png") as alias)
    set position of item "用量监控.app" of installerDisk to {270, 320}
    set position of item "Applications" of installerDisk to {630, 320}
    delay 1
    close installerWindow saving yes
  end tell
end run
APPLESCRIPT

hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0
rmdir "$MOUNT_POINT"
hdiutil convert "$RW_DMG" -quiet -format UDZO -o "$DMG_PATH"
hdiutil verify "$DMG_PATH" -quiet
rm -f "$RW_DMG"

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$DMG_PATH")" > "$CHECKSUM_PATH"

if [[ -n "$NOTES_SOURCE" ]]; then
  cp "$NOTES_SOURCE" "$NOTES_PATH"
else
  cat > "$NOTES_PATH" <<EOF
## 安装

下载 DMG，将“用量监控”拖入 Applications。需要 macOS 13 或更高版本，支持 Intel 和 Apple 芯片。本安装包使用 ad hoc 签名，尚未经过 Apple 公证。
EOF
fi
cat >> "$NOTES_PATH" <<EOF

SHA-256：\`$SHA256\`
EOF

git push origin main
git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG_PATH" "$CHECKSUM_PATH" \
  --title "$APP_NAME $VERSION" \
  --notes-file "$NOTES_PATH" \
  --verify-tag

printf '\nPublished %s\nDMG: %s\nSHA-256: %s\n' "$TAG" "$DMG_PATH" "$SHA256"
