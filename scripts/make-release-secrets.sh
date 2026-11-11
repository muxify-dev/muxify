#!/usr/bin/env bash
# Makes the release secrets once, in a fresh folder that it names: the "Muxify Release Signing" certificate
# and key as a base64 .p12 with its random password, and the Sparkle EdDSA key pair. It writes the public key
# into scripts/sparkle-public-key.env, which packaging stamps as SUPublicEDKey, and prints the gh secret set
# commands. It sets no secret, and changes no keychain except the muxify-release entry that generate_keys adds
# to the login keychain.
#
# If the public-key file already holds a key it refuses, because installed copies trust only that key.
# --force replaces it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="$ROOT/scripts/sparkle-public-key.env"
ACCOUNT=muxify-release
NAME="Muxify Release Signing"
REPO=muxify-dev/muxify

FORCE=false
case "${1:-}" in
  "") ;;
  --force) FORCE=true ;;
  *) echo "Usage: $0 [--force]" >&2; exit 1 ;;
esac

# shellcheck source=sparkle-public-key.env
source "$KEY_FILE"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ] && [ "$FORCE" != true ]; then
  echo "scripts/sparkle-public-key.env already holds the release public key $SPARKLE_PUBLIC_ED_KEY." >&2
  echo "Every installed copy trusts only that key: a new one would stop them updating. Pass --force to replace it." >&2
  exit 1
fi
[ "$(grep -c '^SPARKLE_PUBLIC_ED_KEY=' "$KEY_FILE")" = 1 ] || {
  echo "scripts/sparkle-public-key.env must hold exactly one SPARKLE_PUBLIC_ED_KEY= line." >&2; exit 1;
}

if command -v generate_keys >/dev/null; then
  GENERATE_KEYS=generate_keys
else
  GENERATE_KEYS="$("$ROOT/scripts/setup-sparkle.sh")/bin/generate_keys"
fi

OUT="$(mktemp -d "${TMPDIR:-/tmp}/muxify-release-secrets.XXXXXX")"
OUT="$(cd "$OUT" && pwd -P)"
chmod 700 "$OUT"
umask 077
P12="$OUT/muxify-release-signing.p12.base64"
PASSWORD="$OUT/muxify-release-signing.p12.password"
ED_KEY="$OUT/sparkle-ed-private-key"

# The certificate, made as sign-local.sh makes its own. macOS LibreSSL writes PKCS#12 that
# `security import` reads; Homebrew's OpenSSL 3 may not.
password="$(/usr/bin/openssl rand -base64 24)"
cat > "$OUT/openssl.cnf" <<EOF
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
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$OUT/openssl.cnf" \
  -keyout "$OUT/key.pem" -out "$OUT/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -name "$NAME" \
  -out "$OUT/identity.p12" -passout "pass:$password"
base64 < "$OUT/identity.p12" | tr -d '\n' > "$P12"
printf '%s' "$password" > "$PASSWORD"
# The .p12 holds the key; keep no second copy of it.
rm -f "$OUT/key.pem" "$OUT/identity.p12" "$OUT/openssl.cnf"
mv "$OUT/cert.pem" "$OUT/muxify-release-signing.cert.pem"

# Makes the pair in the login keychain under the account, or finds the one already there.
"$GENERATE_KEYS" --account "$ACCOUNT" >&2
public_key="$("$GENERATE_KEYS" --account "$ACCOUNT" -p)"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  echo "generate_keys gave no base64 Ed25519 public key: $public_key" >&2; exit 1;
}
"$GENERATE_KEYS" --account "$ACCOUNT" -x "$ED_KEY" >&2
[ -s "$ED_KEY" ] || { echo "generate_keys exported no private key to $ED_KEY." >&2; exit 1; }

# Only the key line changes; the file's comments stay.
umask 022
sed "s|^SPARKLE_PUBLIC_ED_KEY=.*\$|SPARKLE_PUBLIC_ED_KEY=$public_key|" "$KEY_FILE" > "$KEY_FILE.tmp"
mv "$KEY_FILE.tmp" "$KEY_FILE"

cat <<EOF
The release secrets are in $OUT:
  $(basename "$ED_KEY")    the Sparkle EdDSA private key
  $(basename "$P12")    the "$NAME" certificate and key
  $(basename "$PASSWORD")    the .p12's password

scripts/sparkle-public-key.env now holds the public key $public_key. Commit it.

Set the three secrets on $REPO (this script sets none):
  gh secret set SPARKLE_ED_PRIVATE_KEY --repo $REPO < "$ED_KEY"
  gh secret set MUXIFY_RELEASE_CERTIFICATE_P12 --repo $REPO < "$P12"
  gh secret set MUXIFY_RELEASE_CERTIFICATE_PASSWORD --repo $REPO < "$PASSWORD"

WARNING: back up the EdDSA private key, and the .p12 with its password, somewhere safe off this Mac, such as a
password manager, then delete $OUT. Losing the private key ends every update: installed copies trust
only this key and can never update again. The login keychain also holds it, under the account $ACCOUNT.
EOF
