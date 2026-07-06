#!/bin/bash
# Packages a RoverGauge.app bundle for macOS from an existing build/ directory.
#
# Usage:
#   cmake -B build -DCMAKE_PREFIX_PATH=$(brew --prefix qt@5)
#   cmake --build build
#   package/build-macos-app.sh
#
# Produces package/rovergauge-<version>-macOS-<arch>.zip: a self-contained
# app bundle with Qt and libcomm14cux embedded.
#
# By default the bundle is ad-hoc signed only, so recipients will see a
# Gatekeeper warning on first launch (right-click -> Open, or
# `xattr -cr RoverGauge.app`).
#
# To sign with a real Developer ID (removes the Gatekeeper warning), set:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
# To also notarize and staple the ticket (recipients get zero warnings, even
# offline), additionally set:
#   NOTARY_PROFILE="<profile name>"
# where the profile was created beforehand via:
#   xcrun notarytool store-credentials "<profile name>" \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
# (run that command yourself, not through an agent, so the password is never
# exposed outside your own keychain)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
PACKAGE_DIR="$REPO_ROOT/package"
QT5_PREFIX="${QT5_PREFIX:-$(brew --prefix qt@5 2>/dev/null || true)}"

if [ ! -x "$BUILD_DIR/rovergauge" ]; then
  echo "error: $BUILD_DIR/rovergauge not found or not executable." >&2
  echo "Build the project first, e.g.:" >&2
  echo "  cmake -B build -DCMAKE_PREFIX_PATH=\$(brew --prefix qt@5)" >&2
  echo "  cmake --build build" >&2
  exit 1
fi

if [ -z "$QT5_PREFIX" ] || [ ! -x "$QT5_PREFIX/bin/macdeployqt" ]; then
  echo "error: could not find macdeployqt (looked in QT5_PREFIX=$QT5_PREFIX)." >&2
  echo "Install Qt5 (brew install qt@5) or set QT5_PREFIX explicitly." >&2
  exit 1
fi

VER_MAJOR=$(grep -m1 ROVERGAUGE_VER_MAJOR "$REPO_ROOT/CMakeLists.txt" | grep -oE '[0-9]+')
VER_MINOR=$(grep -m1 ROVERGAUGE_VER_MINOR "$REPO_ROOT/CMakeLists.txt" | grep -oE '[0-9]+')
VER_PATCH=$(grep -m1 ROVERGAUGE_VER_PATCH "$REPO_ROOT/CMakeLists.txt" | grep -oE '[0-9]+')
VERSION="$VER_MAJOR.$VER_MINOR.$VER_PATCH"
ARCH=$(uname -m)

APP="$PACKAGE_DIR/RoverGauge.app"
ZIPNAME="rovergauge-$VERSION-macOS-$ARCH.zip"

if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
  echo "error: NOTARY_PROFILE is set but SIGN_IDENTITY is not. Notarization requires a Developer ID signature; ad-hoc signatures cannot be notarized." >&2
  exit 1
fi

echo "==> Packaging RoverGauge $VERSION ($ARCH)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/rovergauge" "$APP/Contents/MacOS/RoverGauge"

echo "==> Building icon"
ICONSET="$PACKAGE_DIR/icon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
SRC_ICON="$REPO_ROOT/icon/rovergauge_256x256.png"
sips -z 16 16     "$SRC_ICON" --out "$ICONSET/icon_16x16.png"      > /dev/null
sips -z 32 32     "$SRC_ICON" --out "$ICONSET/icon_16x16@2x.png"   > /dev/null
sips -z 32 32     "$SRC_ICON" --out "$ICONSET/icon_32x32.png"      > /dev/null
sips -z 64 64     "$SRC_ICON" --out "$ICONSET/icon_32x32@2x.png"   > /dev/null
sips -z 128 128   "$SRC_ICON" --out "$ICONSET/icon_128x128.png"    > /dev/null
sips -z 256 256   "$SRC_ICON" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$SRC_ICON" --out "$ICONSET/icon_256x256.png"    > /dev/null
sips -z 512 512   "$SRC_ICON" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
iconutil -c icns "$ICONSET" -o "$PACKAGE_DIR/RoverGauge.icns"
cp "$PACKAGE_DIR/RoverGauge.icns" "$APP/Contents/Resources/"
rm -rf "$ICONSET"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>RoverGauge</string>
  <key>CFBundleIconFile</key>
  <string>RoverGauge.icns</string>
  <key>CFBundleIdentifier</key>
  <string>com.github.kingrody.rovergauge</string>
  <key>CFBundleName</key>
  <string>RoverGauge</string>
  <key>CFBundleDisplayName</key>
  <string>RoverGauge</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>GPL v3</string>
</dict>
</plist>
PLIST

echo "==> Running macdeployqt (bundles Qt frameworks, plugins, and libcomm14cux)"
"$QT5_PREFIX/bin/macdeployqt" "$APP"

# macdeployqt rewrites load commands (rpaths/install names), which
# invalidates any signature applied before this point. Apple Silicon refuses
# to execute an unsigned/invalidly-signed binary at all (silent SIGKILL), so
# (re-)signing here is required, not optional, even for local/unsigned use.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Signing with Developer ID: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Submitting for notarization (profile: $NOTARY_PROFILE)"
    NOTARIZE_ZIP="$PACKAGE_DIR/notarize-submission.zip"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$NOTARIZE_ZIP"

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$APP"

    echo "==> Verifying with spctl"
    spctl -a -vvv -t install "$APP"
  fi
else
  echo "==> Re-signing (ad-hoc)"
  codesign --force --deep --sign - "$APP"
fi

echo "==> Zipping"
cd "$PACKAGE_DIR"
rm -f "$ZIPNAME"
# --norsrc: --sequesterRsrc embeds resource-fork/HFS metadata as separate
# "._*" AppleDouble entries inside the zip. On extraction these land as
# loose, unsigned files in each Qt framework's root directory, which Gatekeeper
# rejects as "unsealed contents present in the root directory of an embedded
# framework" -- regardless of a valid notarization ticket.
ditto -c -k --norsrc --keepParent "RoverGauge.app" "$ZIPNAME"

echo "==> Done: package/$ZIPNAME"
du -sh "$ZIPNAME"
