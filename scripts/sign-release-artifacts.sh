#!/usr/bin/env bash

set -Eeuo pipefail

readonly expected_fingerprint="7D6EF134D851C8DA0862D97494F31AF374E2EE3C"
readonly release_dir="${1:?usage: sign-release-artifacts.sh RELEASE_DIR [asc|sig]}"
readonly signature_extension="${2:-asc}"

case "${signature_extension}" in
  asc) readonly -a signature_format=(--armor) ;;
  sig) readonly -a signature_format=() ;;
  *)
    echo "error: signature extension must be asc or sig" >&2
    exit 2
    ;;
esac

: "${GPG_KEY_B64:?configure the GPG_KEY_B64 repository secret}"
: "${GPG_KEY_PASSWORD:?configure the GPG_KEY_PASSWORD repository secret}"

[[ -d "${release_dir}" ]] || {
  echo "error: release directory does not exist: ${release_dir}" >&2
  exit 1
}

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
readonly key_file="${GNUPGHOME}/private-key.gpg"

cleanup() {
  rm -rf -- "${GNUPGHOME}"
}
trap cleanup EXIT

chmod 0700 "${GNUPGHOME}"
printf '%s\n' 'allow-loopback-pinentry' > "${GNUPGHOME}/gpg-agent.conf"
printf '%s' "${GPG_KEY_B64}" | base64 --decode > "${key_file}"
chmod 0600 "${key_file}"

gpg --batch --no-tty --import "${key_file}"
rm -f -- "${key_file}"

mapfile -t primary_fingerprints < <(
  gpg --batch --with-colons --list-secret-keys --fingerprint |
    awk -F: '
      $1 == "sec" { want_primary_fingerprint = 1; next }
      want_primary_fingerprint && $1 == "fpr" {
        print toupper($10)
        want_primary_fingerprint = 0
      }
    '
)

if [[ "${#primary_fingerprints[@]}" -ne 1 ]] || \
  [[ "${primary_fingerprints[0]:-}" != "${expected_fingerprint}" ]]; then
  echo "error: GPG_KEY_B64 must contain exactly the expected primary signing key" >&2
  echo "error: expected fingerprint ${expected_fingerprint}" >&2
  exit 1
fi

mapfile -d '' -t artifacts < <(
  find "${release_dir}" -maxdepth 1 -type f \
    ! -name '*.asc' ! -name '*.sig' -print0 | sort -z
)
[[ "${#artifacts[@]}" -gt 0 ]] || {
  echo "error: no release artifacts found in ${release_dir}" >&2
  exit 1
}

for artifact in "${artifacts[@]}"; do
  signature="${artifact}.${signature_extension}"
  rm -f -- "${signature}"
  printf '%s' "${GPG_KEY_PASSWORD}" | gpg \
    --batch \
    --no-tty \
    --yes \
    --pinentry-mode loopback \
    --passphrase-fd 0 \
    --local-user "${expected_fingerprint}" \
    "${signature_format[@]}" \
    --detach-sign \
    --output "${signature}" \
    "${artifact}"
  gpg --batch --no-tty --verify "${signature}" "${artifact}"
done

for artifact in "${artifacts[@]}"; do
  [[ -s "${artifact}.${signature_extension}" ]] || {
    echo "error: missing detached signature for ${artifact}" >&2
    exit 1
  }
done

echo "Created and verified ${#artifacts[@]} detached OpenPGP signatures."
