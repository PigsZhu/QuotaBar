#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="QuotaBar"
BUNDLE_ID="com.zhuxc02.quotabar"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
APP_BUILD_NUMBER="${QUOTABAR_BUILD_NUMBER:-1}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid app version or build number" >&2
  exit 1
fi
DIST_DIR="$ROOT_DIR/dist"
BUILD_OPTIONS=(-c release)
PACKAGE_STAGING_DIR=""
cleanup() {
  if [[ -n "$PACKAGE_STAGING_DIR" ]]; then
    rm -rf -- "$PACKAGE_STAGING_DIR"
  fi
}
trap cleanup EXIT
if [[ "$MODE" == "--package-universal" ]]; then
  # Stage outside the project to avoid leaving another app in Launchpad.
  PACKAGE_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-package.XXXXXX")"
  DIST_DIR="$PACKAGE_STAGING_DIR"
  BUILD_OPTIONS+=(--arch arm64 --arch x86_64 --scratch-path "$ROOT_DIR/.build/universal")
fi
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

# Finder and Codex may inherit the standalone Command Line Tools selection.
# Prefer an installed Xcode SDK locally, without changing xcode-select globally.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
  for XCODE_APP in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$XCODE_APP/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
      break
    fi
  done
fi

if [[ "$MODE" != "--package-universal" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
swift build "${BUILD_OPTIONS[@]}"
BUILD_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp -R "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP_RESOURCES/"
cp "$ROOT_DIR/AppResources/$APP_NAME.icns" "$APP_RESOURCES/"
cp "$ROOT_DIR/AppResources/Font-Copyright.txt" "$APP_RESOURCES/"
cp "$ROOT_DIR/AppResources/Authors.txt" "$APP_RESOURCES/"
cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES/LICENSE.txt"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 pigs</string>
  <key>CFBundleIconFile</key>
  <string>$APP_NAME.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

if [[ "$MODE" == "--package-universal" ]]; then
  # Public releases never redistribute optional commercial font files.
  /usr/bin/find "$APP_RESOURCES" -type f \( -iname '*.otf' -o -iname '*.ttf' -o -iname '*.woff' -o -iname '*.woff2' \) -delete
  # Strip development symbols and inherited filesystem metadata from this copy.
  /usr/bin/strip -S "$APP_BINARY"
  /usr/bin/xattr -cr "$APP_BUNDLE"
fi

# Sign the completed bundle so the copied resources and Info.plist are sealed.
# This local ad-hoc signature is not Developer ID signing or notarization.
/usr/bin/codesign --force --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --package-universal)
    ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BINARY")"
    for ARCHITECTURE in arm64 x86_64; do
      if [[ " $ARCHITECTURES " != *" $ARCHITECTURE "* ]]; then
        echo "Missing required architecture: $ARCHITECTURE" >&2
        exit 1
      fi
    done
    mkdir -p "$ROOT_DIR/dist"
    ARCHIVE="$ROOT_DIR/dist/$APP_NAME-$APP_VERSION-Universal.zip"
    /usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_BUNDLE" "$ARCHIVE"
    echo "Shareable ZIP: $ARCHIVE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --preview-anger)
    /usr/bin/open -n "$APP_BUNDLE" --args --preview-eye-anger --preview-delay 12
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--preview-anger|--package-universal]" >&2
    exit 2
    ;;
esac
