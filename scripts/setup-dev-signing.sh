#!/bin/bash
# One-time: create a self-signed "CaptureDeck Dev" code-signing certificate in the login keychain.
# Signing every build with the same identity lets macOS keep the Screen Recording permission
# across rebuilds (ad-hoc signatures change on every build and reset it).
# Local development only; release builds use a real Developer ID (see the release phase).
set -euo pipefail

NAME="CaptureDeck Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
  echo "'$NAME' already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="capturedeck-dev"

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/dev.p12" -passout "pass:$PASS" 2>/dev/null
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created '$NAME'."
security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME" || true
