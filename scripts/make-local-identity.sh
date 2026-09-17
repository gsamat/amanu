#!/usr/bin/env bash
# Create a local, self-signed code-signing identity for amanu.
#
# Why: an ad-hoc signature's identity *is* the binary hash, so every rebuild
# looks like a brand-new app to macOS and every TCC grant — microphone,
# Screen Recording, notifications — is left behind on the old build. A
# certificate gives the bundle a stable designated requirement, and the
# grants then survive rebuilds.
#
# This is a development-machine convenience, not a release identity: nothing
# trusts this certificate but this Mac, and it cannot be notarized.
set -euo pipefail

NAME="Amanu Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
P12PASS="amanu-local-temporary"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${NAME}"; then
    echo "identity already present: ${NAME}"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/amanu-identity.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "generating key and self-signed certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
    -subj "/CN=${NAME}" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

echo "packaging…"
openssl pkcs12 -export -out "${WORK}/identity.p12" \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -passout "pass:${P12PASS}" -name "${NAME}" 2>/dev/null

echo "importing into the login keychain…"
if ! security import "${WORK}/identity.p12" -k "${KEYCHAIN}" -P "${P12PASS}" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign 2>/dev/null; then
    echo "import refused the PKCS#12 (modern PBES2?) — re-exporting with legacy algorithms"
    openssl pkcs12 -export -out "${WORK}/identity.p12" \
        -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
        -passout "pass:${P12PASS}" -name "${NAME}" \
        -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null
    security import "${WORK}/identity.p12" -k "${KEYCHAIN}" -P "${P12PASS}" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign
fi

echo "trusting it for code signing (user domain)…"
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem" \
    || echo "  (trust step declined — codesign may still work; if not, trust it in Keychain Access)"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${NAME}"; then
    echo "OK — signing identity ready: ${NAME}"
else
    echo "FAILED — no usable identity named ${NAME}" >&2
    exit 1
fi
