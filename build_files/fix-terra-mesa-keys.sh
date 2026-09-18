#!/usr/bin/bash
set -Eeuo pipefail

# osbuild's metadata verifier resolves file:// keys in the builder root, not
# the source image root. Use Terra's HTTPS endpoint without changing trust:
# require its contents to match the key shipped in the pinned source image.
releasever="$(rpm --eval '%{fedora}')"
readonly releasever
readonly repo=/etc/yum.repos.d/terra-mesa.repo
test -s "${repo}"
test "$(grep -c '^gpgcheck=1$' "${repo}")" = 2
test "$(grep -c '^repo_gpgcheck=1$' "${repo}")" = 2
temporary_key="$(mktemp)"
trap 'rm -f "${temporary_key}"' EXIT
for suffix in mesa mesa-source; do
    key="/etc/pki/rpm-gpg/RPM-GPG-KEY-terra${releasever}-${suffix}"
    url="https://repos.fyralabs.com/terra${releasever}-${suffix}/key.asc"
    test -s "${key}" || { echo "error: missing packaged Terra key: ${key}" >&2; exit 1; }
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 30 --max-time 120 --retry 3 \
        --output "${temporary_key}" "${url}"
    cmp "${key}" "${temporary_key}" || {
        echo "error: ${url} differs from packaged ${key}; review Terra key rotation" >&2
        exit 1
    }
    # Literal $releasever remains in the repo so DNF expands it as usual.
    old="gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-terra\$releasever-${suffix}"
    new="gpgkey=https://repos.fyralabs.com/terra\$releasever-${suffix}/key.asc"
    if grep -Fxq "${old}" "${repo}"; then
        sed -i "s|^${old}$|${new}|" "${repo}"
    fi
    grep -Fxq "${new}" "${repo}" || {
        echo "error: unexpected Terra key configuration in ${repo}" >&2; exit 1;
    }
done
