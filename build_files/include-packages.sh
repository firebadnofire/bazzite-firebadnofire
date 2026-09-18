#!/usr/bin/bash

set -Eeuo pipefail

usage() {
    echo "usage: $0 {install|verify} INCLUDE_FILE" >&2
    exit 2
}

[[ "$#" -eq 2 ]] || usage

readonly action="$1"
readonly include_file="$2"

[[ "${action}" == "install" || "${action}" == "verify" ]] || usage
[[ -f "${include_file}" ]] || {
    echo "error: additional-package manifest does not exist: ${include_file}" >&2
    exit 1
}

packages=()
line_number=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))

    # Strip leading and trailing whitespace without invoking external tools.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue

    if [[ ! "${line}" =~ ^[[:alnum:]_+][[:alnum:]_.+-]*$ ]]; then
        echo "error: ${include_file}:${line_number}: expected one RPM package name" >&2
        exit 1
    fi
    packages+=("${line}")
done < "${include_file}"

# An empty manifest intentionally performs no package-manager operation.
if (( ${#packages[@]} == 0 )); then
    exit 0
fi

if [[ "${action}" == "install" ]]; then
    dnf5 -y install "${packages[@]}"
fi

# Verify both the build-time transaction and later inspection of the final OCI
# image against the exact manifest copied from the source repository. Query
# installed providers because DNF may correctly resolve a name such as `vim`
# to a package whose RPM name differs (for Fedora, `vim-enhanced`).
for package in "${packages[@]}"; do
    rpm -q --whatprovides "${package}"
done
