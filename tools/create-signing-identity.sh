#!/bin/bash
# One-time setup: creates a self-signed "code signing" certificate called "Switchmypanes Local Dev"
# in your login keychain, so rebuilt copies of the app keep their macOS permissions.
# It stays on this Mac. Nothing is uploaded. Delete it any time in Keychain Access.
#
# macOS will ask for your login password once or twice (to store the key and to trust the certificate).
set -euo pipefail
NAME="${1:-Switchmypanes Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists. Nothing to do."; exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS="$(uuidgen)"

cat > "$WORK/openssl.cnf" <<CNF
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

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$PASS" -name "$NAME"

security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust it for code signing only (this is the step that asks for your password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" || { echo "Something went wrong: identity not listed."; exit 1; }
echo "✓ Done. Now run ./build.sh"
