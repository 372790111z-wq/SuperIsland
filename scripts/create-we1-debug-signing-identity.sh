#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY_NAME="SuperIsland WE1 Debug Local Code Signing"
KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"
CONFIG_PATH="${ROOT_DIR}/scripts/we1-debug-signing-cert.conf"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/superisland-we1-signing.XXXXXX")"
PRIVATE_KEY_PATH="${TEMP_DIR}/identity.key"
CERTIFICATE_PATH="${TEMP_DIR}/identity.crt"
PKCS12_PATH="${TEMP_DIR}/identity.p12"
PKCS12_PASSWORD="$(/usr/bin/openssl rand -hex 32)"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

if security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | \
  grep -Fq "\"${IDENTITY_NAME}\""; then
  echo "Identity already exists: ${IDENTITY_NAME}"
  exit 0
fi

if security find-certificate \
  -c "${IDENTITY_NAME}" \
  -p \
  "${KEYCHAIN_PATH}" > "${CERTIFICATE_PATH}" && \
  [ -s "${CERTIFICATE_PATH}" ]; then
  echo "==> Found the imported certificate; repairing its current-user trust..."
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "${KEYCHAIN_PATH}" \
    "${CERTIFICATE_PATH}"

  if security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | \
    grep -Fq "\"${IDENTITY_NAME}\""; then
    echo "SUCCESS: ${IDENTITY_NAME}"
    echo "Use with: WE1_CODE_SIGN_IDENTITY='${IDENTITY_NAME}' ./scripts/package-we1-debug.sh"
    exit 0
  fi

  echo "ERROR: The existing certificate was trusted but no matching private-key identity is available." >&2
  exit 1
fi

if [ ! -f "${CONFIG_PATH}" ]; then
  echo "ERROR: OpenSSL configuration not found: ${CONFIG_PATH}" >&2
  exit 1
fi

echo "==> Creating a 10-year local-only code-signing certificate..."
/usr/bin/openssl req \
  -newkey rsa:2048 \
  -x509 \
  -days 3650 \
  -nodes \
  -config "${CONFIG_PATH}" \
  -keyout "${PRIVATE_KEY_PATH}" \
  -out "${CERTIFICATE_PATH}"

echo "==> Wrapping the identity for a non-extractable Keychain import..."
/usr/bin/openssl pkcs12 \
  -export \
  -name "${IDENTITY_NAME}" \
  -inkey "${PRIVATE_KEY_PATH}" \
  -in "${CERTIFICATE_PATH}" \
  -out "${PKCS12_PATH}" \
  -passout "pass:${PKCS12_PASSWORD}"

echo "==> Importing into the login Keychain with codesign-only access..."
security import "${PKCS12_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -f pkcs12 \
  -P "${PKCS12_PASSWORD}" \
  -x \
  -T /usr/bin/codesign

echo "==> Trusting this self-signed certificate only in the current user's domain..."
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "${KEYCHAIN_PATH}" \
  "${CERTIFICATE_PATH}"

if ! security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | \
  grep -Fq "\"${IDENTITY_NAME}\""; then
  echo "ERROR: Keychain import completed but no valid code-signing identity was found." >&2
  exit 1
fi

echo "SUCCESS: ${IDENTITY_NAME}"
echo "Use with: WE1_CODE_SIGN_IDENTITY='${IDENTITY_NAME}' ./scripts/package-we1-debug.sh"
