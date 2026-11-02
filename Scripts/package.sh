#!/bin/bash
# Builds, signs, tests, notarizes and packages agent-browser into
#   dist/AgentBrowser-<version>.dmg                (Agent Browser.app: the menu bar item plus the command-line tool)
#   dist/agent-browser-<version>-macos.tar.gz      (the bare universal arm64 + x86_64 binary)
# SKIP_DMG=1 stops after the tarball.
#
# Signing uses a "Developer ID Application" identity from the keychain, restricted to team
# TEAM_ID when set; pin a specific one with SIGN_IDENTITY=<sha-1 hash>.
# SKIP_SIGNING=1 ad-hoc signs instead, for a local build on a Mac without the certificate.
#
# The signed binary is run through Tests/integration.sh before it is packaged (SKIP_TESTS=1 to skip),
# so what ships is what was tested.
#
# Notarization runs when credentials are available, otherwise it is skipped with a warning (an error when
# REQUIRE_NOTARIZATION=1, which the release workflow sets):
#   - CI: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (App Store Connect API key), or
#   - local: a keychain profile, stored once with
#       xcrun notarytool store-credentials "AgentBrowser-Notary" \
#         --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#     (override the profile name with NOTARY_PROFILE).
# The app and the DMG are notarized and stapled (the ticket travels with the app when it is dragged out of
# the DMG). A bare command-line binary cannot be stapled; Gatekeeper checks its ticket online the first
# time a downloaded copy runs. The DMG window gets its background and icon layout through Finder
# (AppleScript); without a GUI session it falls back to a plain DMG with a warning, or fails when
# REQUIRE_DMG_STYLE=1 (the release workflow sets it).
#
# Personal settings (TEAM_ID, SIGN_IDENTITY, NOTARY_PROFILE) live in a git-ignored .signing.local
# (shell syntax, sourced first).
#
# Usage: Scripts/package.sh

set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .signing.local ] && . ./.signing.local

NAME="agent-browser"
BUNDLE_ID="${BUNDLE_ID:-dev.appler.agent-browser}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AgentBrowser-Notary}"
VERSION="$(tr -d '[:space:]' < VERSION)"
DIST="dist"
STAGE="$DIST/$NAME-$VERSION-macos"
ARCHIVE="$DIST/$NAME-$VERSION-macos.tar.gz"
SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64)

# The version is compiled in (Version.swift); it must match the VERSION file the release is tagged from.
if ! grep -q "\"$VERSION\"" Sources/agent-browser/Version.swift; then
  echo "error: VERSION ($VERSION) does not match Sources/agent-browser/Version.swift" >&2
  exit 1
fi

echo "==> Building $NAME $VERSION"
swift build "${SWIFT_FLAGS[@]}"
# Ask SwiftPM for the product directory: its layout depends on the toolchain's build system.
BINARY="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/$NAME"
[ -x "$BINARY" ] || { echo "error: no executable at $BINARY" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$STAGE"
cp "$BINARY" "$STAGE/$NAME"
BIN="$STAGE/$NAME"
lipo -archs "$BIN" | grep -q arm64 && lipo -archs "$BIN" | grep -q x86_64 \
  || { echo "error: $BIN is not a universal binary ($(lipo -archs "$BIN"))" >&2; exit 1; }

if [ -n "${SKIP_SIGNING:-}" ]; then
  echo "==> Ad-hoc signing (SKIP_SIGNING set; not distributable)"
  codesign --force --identifier "$BUNDLE_ID" --sign - "$BIN"
else
  SIGN_ID="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | grep -F "Developer ID Application:" | grep -F "(${TEAM_ID}" | head -1 | awk '{print $2}')}"
  if [ -z "$SIGN_ID" ]; then
    echo "error: no 'Developer ID Application' identity${TEAM_ID:+ for team $TEAM_ID} in the keychain." >&2
    echo "       Check: security find-identity -v -p codesigning  (or SKIP_SIGNING=1 for a local build)" >&2
    exit 1
  fi
  echo "==> Signing as $SIGN_ID ($BUNDLE_ID) with Hardened Runtime"
  # No entitlements: the page JIT runs in Apple's WebContent process, and Developer ID
  # distribution does not require the App Sandbox.
  codesign --force --options runtime --timestamp --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$BIN"
  codesign --verify --strict --verbose=2 "$BIN"
fi

# --- the app bundle: the same binary, started from Finder as the menu bar item ---------------------
APP_NAME="Agent Browser"
DMG_NAME="AgentBrowser"
APP_DIR="$DIST/app"
APP="$APP_DIR/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
sed "s/__VERSION__/$VERSION/g" Packaging/Info.plist > "$APP/Contents/Info.plist"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${SKIP_SIGNING:-}" ]; then
  codesign --force --identifier "$BUNDLE_ID" --sign - "$APP"
else
  codesign --force --options runtime --timestamp --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

if [ -z "${SKIP_TESTS:-}" ]; then
  echo "==> Testing the signed binary (the one inside the app)"
  Tests/integration.sh "$PWD/$APP/Contents/MacOS/$NAME"
fi

NOTARY_AUTH=()
if [ -z "${SKIP_SIGNING:-}" ]; then
  if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ]; then
    NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "${REQUIRE_NOTARIZATION:-}" ]; then
    echo "error: no notarization credentials (keychain profile '$NOTARY_PROFILE' or ASC_* env) and REQUIRE_NOTARIZATION is set" >&2
    exit 1
  else
    echo "warning: no notarization credentials (keychain profile '$NOTARY_PROFILE' or ASC_* env);"
    echo "         the app, the DMG and the binary are signed but not notarized. See the header of this script."
  fi
fi

# Submits a file or a zip and waits; prints Apple's log and fails when it is not accepted.
notarize() {
  local out sub
  out="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
  echo "$out"
  if ! echo "$out" | grep -q "status: Accepted"; then
    sub="$(echo "$out" | awk '/^ *id:/ {print $2; exit}')"
    [ -n "$sub" ] && xcrun notarytool log "$sub" "${NOTARY_AUTH[@]}" || true
    echo "error: notarization was not accepted" >&2
    exit 1
  fi
}

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  echo "==> Notarizing the app and the bare binary (one submission)"
  SUBMIT="$(mktemp -d)"
  cp -R "$APP" "$SUBMIT/"
  cp "$BIN" "$SUBMIT/$NAME"
  ZIP="$(mktemp -d)/notarize.zip"
  ditto -c -k --sequesterRsrc "$SUBMIT" "$ZIP"
  notarize "$ZIP"
  rm -rf "$ZIP" "$SUBMIT"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

echo "==> Packaging the binary"
tar -C "$DIST" -czf "$ARCHIVE" "$(basename "$STAGE")"

# --- the DMG ----------------------------------------------------------------------------------------
if [ -z "${SKIP_DMG:-}" ]; then
  DMG="$DIST/$DMG_NAME-$VERSION.dmg"
  WIN_W=660; WIN_H=400; TITLE_BAR=28   # shared with Scripts/make-dmg-background.swift (icon centres 170,200 / 490,200)

  # Runs a command, killing it after $1 seconds (Finder scripting can hang without a GUI session).
  run_with_timeout() {
    local secs="$1"; shift
    "$@" & local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local watchdog=$!
    local status=0
    wait "$pid" 2>/dev/null || status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
  }

  style_dmg_window() {
    osascript <<OSA
tell application "Finder"
  tell disk "$1"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + TITLE_BAR))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 200}
    set position of item "Applications" of container window to {490, 200}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
  }

  echo "==> Creating the DMG"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  STAGING="$WORK/staging"
  mkdir -p "$STAGING/.background"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  swift Scripts/make-dmg-background.swift "$WORK/bg1.png" 1
  swift Scripts/make-dmg-background.swift "$WORK/bg2.png" 2
  tiffutil -cathidpicheck "$WORK/bg1.png" "$WORK/bg2.png" -out "$STAGING/.background/background.tiff" 2>/dev/null

  RW_DMG="$WORK/rw.dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ -quiet "$RW_DMG"
  # A volume with the same name already mounted would make Finder address the wrong disk.
  [ -d "/Volumes/$APP_NAME" ] && hdiutil detach -quiet -force "/Volumes/$APP_NAME" || true
  MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | head -1)"
  [ -n "$MOUNT" ] || { echo "error: could not mount the temporary DMG" >&2; exit 1; }
  if run_with_timeout 90 style_dmg_window "$(basename "$MOUNT")" >/dev/null 2>&1; then
    echo "    styled the DMG window"
  elif [ -n "${REQUIRE_DMG_STYLE:-}" ]; then
    echo "error: could not style the DMG window through Finder (REQUIRE_DMG_STYLE is set)" >&2
    exit 1
  else
    echo "warning: could not style the DMG window through Finder; the DMG will open unstyled."
  fi
  sync
  for _ in 1 2 3 4 5; do hdiutil detach -quiet "$MOUNT" 2>/dev/null && break || sleep 2; done
  [ -d "$MOUNT" ] && hdiutil detach -quiet -force "$MOUNT"

  rm -f "$DMG"
  hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
  if [ -z "${SKIP_SIGNING:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
      echo "==> Notarizing and stapling the DMG"
      notarize "$DMG"
      xcrun stapler staple "$DMG"
      spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    fi
  fi
fi

(cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" ${DMG:+"$(basename "$DMG")"} > SHA256SUMS.txt)
echo "==> Done"
ls -l "$DIST"
cat "$DIST/SHA256SUMS.txt"
