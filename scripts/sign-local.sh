#!/usr/bin/env bash
# Signs an app with a self-signed certificate kept in its own keychain, and creates both on first use.
# An ad-hoc signature changes with every build, so macOS drops Local Network, Accessibility and
# Input Monitoring grants. The certificate gives every build the same designated requirement.
set -euo pipefail

APP="$1"
KEYCHAIN="${MUXIFY_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/muxify-local-signing.keychain-db}"
NAME="Muxify Local Signing"

user_keychains() {
  security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/'
}

broken() {
  echo "sign-local.sh: $1. Delete the keychain, then run make install again:" >&2
  echo "  security delete-keychain \"$KEYCHAIN\"" >&2
  exit 1
}

if [ ! -f "$KEYCHAIN" ]; then
  # A random password, kept in the login keychain, guards the key. A copy of this keychain, as in
  # a backup, is then as safe as the login keychain, and make still uses it without a prompt.
  password="$(/usr/bin/openssl rand -base64 24)"
  security add-generic-password -U -s "$NAME" -a "$KEYCHAIN" -w "$password" login.keychain
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/openssl.cnf" <<EOF
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
EOF
  # macOS LibreSSL writes PKCS#12 that `security import` reads; Homebrew's OpenSSL 3 may not.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/identity.p12" -passout "pass:$password"
  security create-keychain -p "$password" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$password" "$KEYCHAIN"
  security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
  # Lets codesign use the key without asking.
  security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$KEYCHAIN" >/dev/null
else
  password="$(security find-generic-password -s "$NAME" -a "$KEYCHAIN" -w 2>/dev/null)" ||
    broken "the login keychain holds no password for $KEYCHAIN"
fi

# codesign finds an identity only in a keychain on the search list.
current="$(user_keychains)"
if ! grep -qxF "$KEYCHAIN" <<<"$current"; then
  keychains=()
  while IFS= read -r keychain; do keychains+=("$keychain"); done <<<"$current"
  security list-keychains -d user -s "${keychains[@]}" "$KEYCHAIN"
fi

security unlock-keychain -p "$password" "$KEYCHAIN" 2>/dev/null ||
  broken "the password in the login keychain does not unlock $KEYCHAIN"
# A first run that stopped part way can leave the keychain without the certificate or its key.
identity="$(security find-identity -p codesigning "$KEYCHAIN" |
  awk -v name="\"$NAME\"" 'index($0, name) { print $2; exit }')"
[ -n "$identity" ] || broken "$KEYCHAIN holds no \"$NAME\" signing identity"
codesign --force --sign "$identity" --keychain "$KEYCHAIN" --preserve-metadata=entitlements "$APP"
