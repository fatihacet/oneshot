#!/usr/bin/env bash
# Creates a self-signed code signing certificate in the login keychain.
# Signing every local build with the same identity keeps macOS privacy permissions
# (Screen Recording) across rebuilds; ad-hoc signatures change on every build.
set -euo pipefail

NAME="${1:-OneShot Local Signing}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout pass:oneshot >/dev/null 2>&1

security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P oneshot -T /usr/bin/codesign >/dev/null

echo "Created code signing certificate \"$NAME\"."
echo "Build with: make app  (it picks up this identity automatically)"
