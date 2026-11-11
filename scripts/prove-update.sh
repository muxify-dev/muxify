#!/usr/bin/env bash
# Proves that Sparkle's own installer updates a self-signed Muxify.app from a feed on localhost, and that it
# refuses a zip signed with another EdDSA key. Everything lives in one run directory: a throwaway keychain with
# a throwaway self-signed certificate, throwaway EdDSA keys, the two builds and the feeds. It never touches the
# login keychain, the keychain search list or the user's Sparkle keys, and it never launches Muxify.
# Prints PASS, or FAIL and the step that failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUILD_N=100
BUILD_NEXT=101

STEP="fetch Sparkle's tools"
RUN=""
SERVER_PID=""
KEYCHAIN=""
BUNDLE_ID=""
SEARCH_LIST="$(security list-keychains -d user)"
DEFAULT_KEYCHAIN="$(security default-keychain -d user)"

step() {
  STEP="$1"
  echo "== $STEP"
}

fail() {
  echo "$*" >&2
  exit 1
}

# Every process that names the run directory: the feed server and whatever Sparkle's installer left.
run_processes() {
  pgrep -f -- "$RUN" || true
  [ -z "$BUNDLE_ID" ] || pgrep -f -- "$BUNDLE_ID" || true
}

cleanup() {
  local status=$? pids
  trap - EXIT
  set +e
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  if [ -n "$RUN" ]; then
    pids="$(run_processes | sort -u)"
    [ -z "$pids" ] || kill $pids 2>/dev/null
    for _ in $(seq 50); do [ -z "$(run_processes)" ] && break; sleep 0.1; done
    pids="$(run_processes | sort -u)"
    if [ -n "$pids" ]; then
      echo "Processes of the run still run: $pids" >&2
      status=1
    fi
    [ -z "$KEYCHAIN" ] || security delete-keychain "$KEYCHAIN" 2>/dev/null
    if [ -n "$BUNDLE_ID" ]; then
      # Sparkle keeps its check times in the host's defaults and its installer in the host's caches.
      defaults delete "$BUNDLE_ID" >/dev/null 2>&1
      rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
      rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    fi
    # The vendored sparkle-cli's own URL cache, which only these runs make.
    rm -rf "$HOME/Library/Caches/org.sparkle-project.sparkle-cli" "$HOME/Library/HTTPStorages/org.sparkle-project.sparkle-cli"
    find "$RUN" -maxdepth 3 -name Muxify.app -type d -exec "$LSREGISTER" -u {} \; 2>/dev/null
    rm -rf "$RUN"
  fi
  if [ "$(security list-keychains -d user)" != "$SEARCH_LIST" ] ||
     [ "$(security default-keychain -d user)" != "$DEFAULT_KEYCHAIN" ]; then
    echo "The keychain search list or the default keychain changed during the run." >&2
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    echo PASS
  else
    echo "FAIL: $STEP" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

SPARKLE="$("$ROOT/scripts/setup-sparkle.sh")"
SIGN_UPDATE="$SPARKLE/bin/sign_update"
SPARKLE_CLI="$SPARKLE/sparkle.app/Contents/MacOS/sparkle"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/muxify-update-proof.XXXXXX")"
RUN="$(cd "$RUN" && pwd -P)"
# A bundle id of this run only, so Sparkle's defaults and caches never mix with an installed Muxify's.
BUNDLE_ID="dev.muxify.update-proof.$(basename "$RUN" | tr -cd 'A-Za-z0-9')"

step "make a throwaway signing certificate in a throwaway keychain"
KEYCHAIN="$RUN/signing.keychain-db"
password="$(/usr/bin/openssl rand -base64 24)"
cat > "$RUN/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Muxify Update Proof
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
# macOS LibreSSL writes PKCS#12 that `security import` reads; Homebrew's OpenSSL 3 may not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$RUN/openssl.cnf" \
  -keyout "$RUN/key.pem" -out "$RUN/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$RUN/key.pem" -in "$RUN/cert.pem" \
  -out "$RUN/identity.p12" -passout "pass:$password"
# create-keychain does not add the keychain to the search list, and codesign gets it by --keychain.
security create-keychain -p "$password" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$password" "$KEYCHAIN"
security import "$RUN/identity.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$KEYCHAIN" >/dev/null
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" |
  awk '/"Muxify Update Proof"/ { print $2; exit }')"
[ -n "$IDENTITY" ] || fail "$KEYCHAIN holds no signing identity"

step "make two throwaway EdDSA key pairs"
# CryptoKit's Curve25519 signing key is Ed25519, and its raw form is the 32-byte seed that sign_update reads.
cat > "$RUN/keygen.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
xcrun swiftc -module-cache-path "$RUN/swift-cache" -o "$RUN/keygen" "$RUN/keygen.swift"
PUBLIC_KEY="$("$RUN/keygen" "$RUN/eddsa.key")"
"$RUN/keygen" "$RUN/other-eddsa.key" >/dev/null

step "build the Release app"
make -C "$ROOT" project >"$RUN/build.log" 2>&1 || fail "make project failed: $(tail -20 "$RUN/build.log")"
xcodebuild -project "$ROOT/Muxify.xcodeproj" -scheme Muxify -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ROOT/build" -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
  diagnostic_message_length=0 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO \
  -quiet build >>"$RUN/build.log" 2>&1 || fail "xcodebuild failed: $(grep -E 'error:' "$RUN/build.log" | head -20)"
APP="$ROOT/build/Build/Products/Release/Muxify.app"

# Copies the Release app to $1 as build $2, with the public key unless $3 is "no-key", signed with the
# throwaway certificate.
make_build() {
  local plist="$1/Contents/Info.plist"
  mkdir -p "$(dirname "$1")"
  ditto "$APP" "$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $2" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$plist"
  if [ "${3:-}" != no-key ]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$plist"
  fi
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --preserve-metadata=entitlements "$1" 2>/dev/null
  codesign --verify --deep --strict "$1"
}

build_of() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist"
}

requirement_of() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

step "make build $BUILD_N and build $BUILD_NEXT, signed with the throwaway certificate"
make_build "$RUN/builds/$BUILD_N/Muxify.app" "$BUILD_N"
make_build "$RUN/builds/$BUILD_NEXT/Muxify.app" "$BUILD_NEXT"
make_build "$RUN/builds/no-key/Muxify.app" "$BUILD_N" no-key
REQUIREMENT="$(requirement_of "$RUN/builds/$BUILD_N/Muxify.app")"
[[ "$REQUIREMENT" == *'certificate leaf = H"'* ]] ||
  fail "Build $BUILD_N's designated requirement does not name the certificate: $REQUIREMENT"

step "zip build $BUILD_NEXT as a release does and sign the zip"
mkdir -p "$RUN/feed/good" "$RUN/feed/other-key"
# ditto preserves the app's symlinks, executable permissions, and signature.
ditto -c -k --sequesterRsrc --keepParent "$RUN/builds/$BUILD_NEXT/Muxify.app" "$RUN/feed/good/Muxify.zip"
cp "$RUN/feed/good/Muxify.zip" "$RUN/feed/other-key/Muxify.zip"
GOOD_SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$RUN/eddsa.key" "$RUN/feed/good/Muxify.zip")"
OTHER_SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$RUN/other-eddsa.key" "$RUN/feed/other-key/Muxify.zip")"

step "serve the feeds over http on localhost"
python3 -I - "$RUN/feed" "$RUN/port" >"$RUN/server.log" 2>&1 <<'PY' &
import functools, http.server, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
with open(sys.argv[2] + ".tmp", "w") as f:
    f.write(str(server.server_port))
import os
os.rename(sys.argv[2] + ".tmp", sys.argv[2])
server.serve_forever()
PY
SERVER_PID=$!
for _ in $(seq 100); do [ -s "$RUN/port" ] && break; sleep 0.1; done
[ -s "$RUN/port" ] || fail "The feed server did not start: $(cat "$RUN/server.log")"
FEED="http://127.0.0.1:$(cat "$RUN/port")"

# Writes a one-item feed $1.xml whose item is $1/Muxify.zip with the sign_update attributes $2.
write_feed() {
  cat > "$RUN/feed/$1.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Muxify</title>
    <item>
      <title>Build $BUILD_NEXT</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NEXT</sparkle:version>
      <sparkle:shortVersionString>$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$FEED/$1/Muxify.zip" type="application/octet-stream" $2/>
    </item>
  </channel>
</rss>
XML
}
write_feed good "$GOOD_SIGNATURE"
write_feed other-key "$OTHER_SIGNATURE"

# Runs Sparkle's command-line updater on the bundle $1 with the feed $2, then the options after it.
sparkle() {
  local bundle="$1" feed="$2"
  shift 2
  "$SPARKLE_CLI" "$bundle" --feed-url "$FEED/$feed.xml" --user-agent-name "Muxify update proof" "$@"
}

step "check that Sparkle's updater refuses to start without SUPublicEDKey on an http feed"
if output="$(sparkle "$RUN/builds/no-key/Muxify.app" good --probe 2>&1)"; then
  fail "Sparkle's updater started without SUPublicEDKey: $output"
fi
[[ "$output" == *"Failed to initialize updater"*"signed with an EdDSA key"* ]] ||
  fail "Sparkle failed without SUPublicEDKey for another reason: $output"
echo "Without SUPublicEDKey: $output"

step "update build $BUILD_N to build $BUILD_NEXT with Sparkle's installer"
INSTALLED="$RUN/installed/Muxify.app"
mkdir -p "$RUN/installed"
ditto "$RUN/builds/$BUILD_N/Muxify.app" "$INSTALLED"
output="$(sparkle "$INSTALLED" good --check-immediately --verbose 2>&1)" || fail "Sparkle did not install the update: $output"
# The installer may finish after the tool exits.
for _ in $(seq 100); do [ "$(build_of "$INSTALLED")" = "$BUILD_NEXT" ] && break; sleep 0.1; done
[ "$(build_of "$INSTALLED")" = "$BUILD_NEXT" ] ||
  fail "The installed copy reports build $(build_of "$INSTALLED"), not $BUILD_NEXT. Sparkle said: $output"

step "check the updated copy's signature and designated requirement"
codesign --verify --deep --strict "$INSTALLED"
[ "$(requirement_of "$INSTALLED")" = "$REQUIREMENT" ] ||
  fail "The designated requirement changed: $(requirement_of "$INSTALLED"), not $REQUIREMENT"

step "check that Sparkle refuses a zip signed with another EdDSA key"
KEPT="$RUN/kept/Muxify.app"
mkdir -p "$RUN/kept"
ditto "$RUN/builds/$BUILD_N/Muxify.app" "$KEPT"
if output="$(sparkle "$KEPT" other-key --check-immediately --verbose 2>&1)"; then
  fail "Sparkle accepted a zip signed with another key: $output"
fi
echo "Refused: $(grep -i error <<<"$output" | tail -1)"
sleep 1
[ "$(build_of "$KEPT")" = "$BUILD_N" ] || fail "The refused copy reports build $(build_of "$KEPT"), not $BUILD_N"
codesign --verify --deep --strict "$KEPT"

STEP="clean up"
