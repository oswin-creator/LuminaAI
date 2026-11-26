#!/bin/zsh
set -euo pipefail

CERT_NAME="LuminaAI Local Signer"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "==> Persistent certificate '${CERT_NAME}' already exists in your login keychain."
    exit 0
fi

echo "==> Creating self-signed local Code Signing certificate '${CERT_NAME}'..."
TMP_DIR="$(mktemp -d /tmp/lumina_cert.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat > "${TMP_DIR}/cert.cfg" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
x509_extensions    = v3_codesign
prompt             = no

[ req_dn ]
CN = ${CERT_NAME}

[ v3_codesign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TMP_DIR}/key.pem" \
    -out "${TMP_DIR}/cert.pem" \
    -days 3650 \
    -config "${TMP_DIR}/cert.cfg" 2>/dev/null

if openssl version | grep -qi "OpenSSL 3"; then
    openssl pkcs12 -legacy -export \
        -out "${TMP_DIR}/cert.p12" \
        -inkey "${TMP_DIR}/key.pem" \
        -in "${TMP_DIR}/cert.pem" \
        -passout pass:lumina123
else
    openssl pkcs12 -export \
        -out "${TMP_DIR}/cert.p12" \
        -inkey "${TMP_DIR}/key.pem" \
        -in "${TMP_DIR}/cert.pem" \
        -passout pass:lumina123
fi

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
security import "${TMP_DIR}/cert.p12" -k "${KEYCHAIN}" -P lumina123 -T /usr/bin/codesign
security add-trusted-cert -d -r trustRoot -p codeSign -k "${KEYCHAIN}" "${TMP_DIR}/cert.pem" || true

echo "==> Done! '${CERT_NAME}' is ready. Future rebuilds & GitHub updates will keep macOS permissions intact."
