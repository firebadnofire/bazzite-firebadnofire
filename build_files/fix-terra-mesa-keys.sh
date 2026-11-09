#!/usr/bin/bash
set -Eeuo pipefail

# osbuild's metadata verifier resolves file:// keys in the builder root, not
# the source image root. Use Terra's HTTPS endpoint without changing trust:
# require its contents to match the key shipped in the pinned source image.
releasever="$(rpm --eval '%{fedora}')"
readonly releasever
readonly override=/etc/dnf/repos.override.d/90-bazzite-firebadnofire-terra-mesa.repo

# Fedora 45 moved distribution-owned repository definitions out of /etc.
# Require exactly one supported upstream location so a future layout change
# fails closed instead of leaving an ineffective override behind.
repo_candidates=(
    /etc/yum.repos.d/terra-mesa.repo
    /usr/share/dnf5/repos.d/terra-mesa.repo
)
repos=()
for candidate in "${repo_candidates[@]}"; do
    [[ -s "${candidate}" ]] && repos+=("${candidate}")
done
if (( ${#repos[@]} != 1 )); then
    printf 'error: expected one Terra Mesa repository definition, found %d\n' \
        "${#repos[@]}" >&2
    exit 1
fi
repo="${repos[0]}"
readonly repo
test "$(grep -c '^gpgcheck=1$' "${repo}")" = 2
test "$(grep -Ec '^repo_gpgcheck=[01]$' "${repo}")" = 2
test -s "${override}"
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
    # Literal $releasever remains in the override so DNF expands it as usual.
    new="gpgkey=https://repos.fyralabs.com/terra\$releasever-${suffix}/key.asc"
    test "$(grep -Fxc "${new}" "${override}")" = 1 || {
        echo "error: unexpected Terra key override in ${override}" >&2; exit 1;
    }
    dnf5 --dump-repo-config="terra-${suffix}" | grep -Fxq \
        "gpgkey = https://repos.fyralabs.com/terra${releasever}-${suffix}/key.asc" || {
        echo "error: DNF5 did not apply the Terra key override for terra-${suffix}" >&2
        exit 1
    }
done
