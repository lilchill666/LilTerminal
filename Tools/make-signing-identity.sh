#!/usr/bin/env bash
# Creates the local code-signing identity that make.sh looks for.
#
# Why this exists: an ad-hoc signature gives the bundle a designated requirement
# of `cdhash H"..."` — the exact bytes of that build. macOS keys every
# permission it remembers (Screen Recording, Microphone, Accessibility, Full
# Disk Access) to that requirement, so every rebuild looks like a different
# application: the switch stays on in System Settings while the new binary is
# denied. Signing with a certificate instead pins the requirement to the
# certificate, which does not change when the code does:
#
#   ad-hoc      designated => cdhash H"52d1e498..."
#   signed      designated => identifier "app.lilterminal" and certificate leaf = H"b47b15cb..."
#
# The certificate is self-signed and local to this machine. It is not trusted
# for anything — not TLS, not Gatekeeper — and it does not need to be: signing
# works with an untrusted certificate, and the requirement only needs to name
# it. The private key lives in your login keychain; deleting it means the next
# build gets a new identity and permissions have to be granted once more.
set -euo pipefail

NAME="LilTerminal Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity \"$NAME\" already exists — nothing to do."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no

[ dn ]
CN = LilTerminal Local Signing

[ codesign ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null

# `security import` wants a traditional RSA key, not the PKCS#8 openssl writes.
openssl rsa -in "$WORK/key.pem" -out "$WORK/key-trad.pem" 2>/dev/null

security import "$WORK/cert.pem" -k "$KEYCHAIN" -f openssl \
    -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
security import "$WORK/key-trad.pem" -k "$KEYCHAIN" -f openssl \
    -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

echo "Created \"$NAME\":"
security find-identity -p codesigning 2>/dev/null | grep "$NAME" || true
echo
echo "CSSMERR_TP_NOT_TRUSTED next to it is expected and harmless — the"
echo "certificate is self-signed, and signing does not require trust."
echo "make.sh picks it up automatically from here on."
