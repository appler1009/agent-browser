#!/bin/bash
# Builds, signs, tests, notarizes and packages agent-browser into
# dist/agent-browser-<version>-macos.tar.gz (a universal arm64 + x86_64 binary).
#
# Signing uses a "Developer ID Application" identity from the keychain, restricted to team
# TEAM_ID when set; pin a specific one with SIGN_IDENTITY=<sha-1 hash>.
# SKIP_SIGNING=1 ad-hoc signs instead, for a local build on a Mac without the certificate.
#
# The signed binary is run through Tests/integration.sh before it is packaged (SKIP_TESTS=1 to skip),
# so what ships is what was tested.
#
# Notarization runs when credentials are available, otherwise it is skipped with a warning:
#   - CI: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (App Store Connect API key), or
#   - local: a keychain profile, stored once with
#       xcrun notarytool store-credentials "AgentBrowser-Notary" \
#         --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#     (override the profile name with NOTARY_PROFILE).
# A bare command-line binary cannot be stapled; Gatekeeper checks its notarization ticket online
# the first time a downloaded copy runs.
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

if [ -z "${SKIP_TESTS:-}" ]; then
  echo "==> Testing the signed binary"
  Tests/integration.sh "$PWD/$BIN"
fi

NOTARY_AUTH=()
if [ -z "${SKIP_SIGNING:-}" ]; then
  if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ]; then
    NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  else
    echo "warning: no notarization credentials (keychain profile '$NOTARY_PROFILE' or ASC_* env);"
    echo "         the binary is signed but not notarized. See the header of this script."
  fi
fi

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  echo "==> Notarizing"
  ZIP="$(mktemp -d)/$NAME.zip"
  ditto -c -k --keepParent "$BIN" "$ZIP"
  OUT="$(xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
  echo "$OUT"
  if ! echo "$OUT" | grep -q "status: Accepted"; then
    SUB_ID="$(echo "$OUT" | awk '/^ *id:/ {print $2; exit}')"
    [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" "${NOTARY_AUTH[@]}" || true
    echo "error: notarization was not accepted" >&2
    exit 1
  fi
  rm -f "$ZIP"
fi

echo "==> Packaging"
tar -C "$DIST" -czf "$ARCHIVE" "$(basename "$STAGE")"
(cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt)
echo "==> Done: $ARCHIVE"
cat "$DIST/SHA256SUMS.txt"
