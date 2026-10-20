#!/bin/bash
# Builds Tangerine with Swift Package Manager and wraps the binary in a
# proper Tangerine.app bundle. We need a real bundle (stable
# CFBundleIdentifier + a code signature) because:
#   - Accessibility permission (System Settings > Privacy & Security) is
#     granted per bundle identity, not per binary path. A raw `swift run`
#     binary gets re-prompted (or mis-attributed to the wrong process) on
#     every rebuild.
#   - UNUserNotificationCenter (Milestone 7) refuses to register a
#     notification source that isn't inside a bundle.
#   - SMAppService "Launch at Login" needs a bundle to register.
#
# Usage: Scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/Tangerine"
APP_DIR="$ROOT_DIR/Tangerine.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/Tangerine"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Ad-hoc signing (`codesign -s -`) folds a hash of the binary itself into
# the signature, so it's a *different* identity on every rebuild — macOS's
# TCC then treats each rebuild as a brand new, never-before-seen app and
# silently drops any previously granted Accessibility permission. Signing
# with a real certificate instead keeps the same identity across rebuilds
# (only the certificate matters to TCC, not the binary's hash), so the
# Accessibility grant survives. Prefer a real Apple Development identity if
# Xcode has one installed; otherwise create (once) and reuse a local
# self-signed "Tangerine Local Dev" code-signing certificate. It doesn't
# need to be trusted by Gatekeeper for `codesign` to sign with it — only
# for *other* machines to verify it, which doesn't matter for local use.
CERT_NAME="Tangerine Local Dev"
SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)"

if [[ -z "$SIGN_IDENTITY" ]]; then
    if ! security find-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
        echo "==> No code-signing identity found; creating local certificate '$CERT_NAME'"
        TMP_CONF="$(mktemp)"; TMP_KEY="$(mktemp)"; TMP_CERT="$(mktemp)"; TMP_P12="$(mktemp)"
        cat > "$TMP_CONF" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $CERT_NAME

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
        openssl req -x509 -newkey rsa:2048 -keyout "$TMP_KEY" -out "$TMP_CERT" -days 3650 -nodes -config "$TMP_CONF" >/dev/null 2>&1
        openssl pkcs12 -export -out "$TMP_P12" -inkey "$TMP_KEY" -in "$TMP_CERT" -passout pass:tangerine >/dev/null 2>&1
        security import "$TMP_P12" -k "$HOME/Library/Keychains/login.keychain-db" -P tangerine -T /usr/bin/codesign -A >/dev/null
        rm -f "$TMP_CONF" "$TMP_KEY" "$TMP_CERT" "$TMP_P12"
    fi
    SIGN_IDENTITY="$CERT_NAME"
fi

echo "==> Codesigning with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Built $APP_DIR"
echo ""
echo "Run it with:"
echo "  open \"$APP_DIR\"                              # normal launch (recommended)"
echo "  \"$MACOS_DIR/Tangerine\"                        # launch with logs in this terminal"
