#!/bin/zsh
# Creates a self-signed code-signing identity "ClaudeSniper Local" in your
# login keychain. build.sh signs with it when it exists, so macOS keeps
# permissions (like Screen Recording) across rebuilds instead of asking again.
#
# Run it once yourself:  zsh tools/make_signing_cert.sh
# Remove it later in Keychain Access (search "ClaudeSniper Local").
set -e
NAME="ClaudeSniper Local"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
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
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=claudesniper
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:$PASS 2>/dev/null
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P $PASS -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with ./build.sh, then allow Screen Recording once."
