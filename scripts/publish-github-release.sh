#!/usr/bin/bash
# Mirror one fully assembled release to GitHub and verify every uploaded asset.
set -Eeuo pipefail
trap 'echo "error: GitHub release mirroring failed at line ${LINENO}; inspect the API response above" >&2' ERR

: "${GITHUB_RELEASE_TOKEN:?configure the GITHUB_RELEASE_TOKEN Forgejo secret}"
: "${GITHUB_RELEASE_REPOSITORY:?set owner/repository for the GitHub mirror}"
: "${GITHUB_RELEASE_TAG:?set the GitHub release tag}"
: "${GITHUB_RELEASE_TITLE:?set the GitHub release title}"
: "${GITHUB_RELEASE_TARGET:?set the mirrored Git commit SHA}"

readonly release_dir="${1:-release}"
readonly notes_file="${2:-release-notes.md}"
readonly api_root="https://api.github.com"

[[ "${GITHUB_RELEASE_REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
[[ "${GITHUB_RELEASE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "${GITHUB_RELEASE_TARGET}" =~ ^[0-9a-f]{40}$ ]]
[[ -d "${release_dir}" && -s "${notes_file}" ]]
command -v curl >/dev/null
command -v jq >/dev/null
command -v sha256sum >/dev/null

mapfile -d '' -t assets < <(find "${release_dir}" -maxdepth 1 -type f -print0 | sort -z)
[[ "${#assets[@]}" -eq 4 ]] || {
    echo "error: GitHub mirror requires exactly four release assets" >&2
    find "${release_dir}" -maxdepth 1 -type f -print >&2
    exit 1
}

api_request() {
    local method="$1"
    local url="$2"
    local output="$3"
    shift 3
    curl --fail-with-body --silent --show-error --location \
        --request "${method}" \
        --header 'Accept: application/vnd.github+json' \
        --header "Authorization: Bearer ${GITHUB_RELEASE_TOKEN}" \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --output "${output}" \
        "$@" "${url}"
}

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT

# A GitHub release tag must identify the same source revision as Forgejo.
api_request GET \
    "${api_root}/repos/${GITHUB_RELEASE_REPOSITORY}/git/commits/${GITHUB_RELEASE_TARGET}" \
    "${work_dir}/commit.json"
[[ "$(jq -r '.sha' "${work_dir}/commit.json")" == "${GITHUB_RELEASE_TARGET}" ]]

notes="$(cat -- "${notes_file}")"
release_payload="$(jq -n \
    --arg tag "${GITHUB_RELEASE_TAG}" \
    --arg target "${GITHUB_RELEASE_TARGET}" \
    --arg title "${GITHUB_RELEASE_TITLE}" \
    --arg body "${notes}" \
    '{tag_name:$tag,target_commitish:$target,name:$title,body:$body,draft:true,prerelease:false}')"

status="$(curl --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer ${GITHUB_RELEASE_TOKEN}" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "${work_dir}/release.json" --write-out '%{http_code}' \
    "${api_root}/repos/${GITHUB_RELEASE_REPOSITORY}/releases/tags/${GITHUB_RELEASE_TAG}")"
case "${status}" in
    200)
        release_id="$(jq -r '.id' "${work_dir}/release.json")"
        api_request PATCH \
            "${api_root}/repos/${GITHUB_RELEASE_REPOSITORY}/releases/${release_id}" \
            "${work_dir}/release.json" \
            --header 'Content-Type: application/json' --data "${release_payload}"
        ;;
    404)
        api_request POST \
            "${api_root}/repos/${GITHUB_RELEASE_REPOSITORY}/releases" \
            "${work_dir}/release.json" \
            --header 'Content-Type: application/json' --data "${release_payload}"
        release_id="$(jq -r '.id' "${work_dir}/release.json")"
        ;;
    *)
        echo "error: GitHub release lookup returned HTTP ${status}" >&2
        jq -r '.message // .' "${work_dir}/release.json" >&2 || true
        exit 1
        ;;
esac
[[ "${release_id}" =~ ^[0-9]+$ ]]

# The release stays draft while its previous assets are reconciled. This is a
# dedicated netiso tag, so retaining stale or unexpected files is never valid.
jq -r '.assets[].id' "${work_dir}/release.json" | while IFS= read -r asset_id; do
    [[ "${asset_id}" =~ ^[0-9]+$ ]]
    api_request DELETE \
        "${api_root}/repos/${GITHUB_RELEASE_REPOSITORY}/releases/assets/${asset_id}" \
        /dev/null
done

for asset in "${assets[@]}"; do
    name="$(basename -- "${asset}")"
    bytes="$(stat --format='%s' -- "${asset}")"
    digest="sha256:$(sha256sum -- "${asset}" | cut -d ' ' -f 1)"
    [[ "${bytes}" =~ ^[1-9][0-9]*$ ]]
    ((bytes < 2147483648)) || {
        echo "error: ${name} is not below GitHub's 2 GiB per-asset limit" >&2
        exit 1
    }
    encoded_name="$(jq -rn --arg value "${name}" '$value | @uri')"
    api_request POST \
        "https://uploads.github.com/repos/${GITHUB_RELEASE_REPOSITORY}/releases/${release_id}/assets?name=${encoded_name}" \
        "${work_dir}/asset.json" \
        --header 'Content-Type: application/octet-stream' --data-binary "@${asset}"
    [[ "$(jq -r '.name' "${work_dir}/asset.json")" == "${name}" ]]
    [[ "$(jq -r '.state' "${work_dir}/asset.json")" == uploaded ]]
    [[ "$(jq -r '.size' "${work_dir}/asset.json")" == "${bytes}" ]]
    [[ "$(jq -r '.digest' "${work_dir}/asset.json")" == "${digest}" ]]
    echo "Verified GitHub release asset: ${name} (${bytes} bytes; ${digest})"
done

api_request GET \
    "${api_root}/repos/${GITHUB_RELEASE_REPOSITORY}/releases/${release_id}" \
    "${work_dir}/release.json"
[[ "$(jq -r '.assets | length' "${work_dir}/release.json")" == 4 ]]
for asset in "${assets[@]}"; do
    name="$(basename -- "${asset}")"
    bytes="$(stat --format='%s' -- "${asset}")"
    digest="sha256:$(sha256sum -- "${asset}" | cut -d ' ' -f 1)"
    [[ "$(jq --arg name "${name}" '[.assets[] | select(.name == $name)] | length' \
        "${work_dir}/release.json")" == 1 ]]
    [[ "$(jq -r --arg name "${name}" '.assets[] | select(.name == $name) | .size' \
        "${work_dir}/release.json")" == "${bytes}" ]]
    [[ "$(jq -r --arg name "${name}" '.assets[] | select(.name == $name) | .digest' \
        "${work_dir}/release.json")" == "${digest}" ]]
done

publish_payload="$(jq -n \
    --arg tag "${GITHUB_RELEASE_TAG}" \
    --arg target "${GITHUB_RELEASE_TARGET}" \
    --arg title "${GITHUB_RELEASE_TITLE}" \
    --arg body "${notes}" \
    '{tag_name:$tag,target_commitish:$target,name:$title,body:$body,draft:false,prerelease:false}')"
api_request PATCH \
    "${api_root}/repos/${GITHUB_RELEASE_REPOSITORY}/releases/${release_id}" \
    "${work_dir}/published.json" \
    --header 'Content-Type: application/json' --data "${publish_payload}"
[[ "$(jq -r '.draft' "${work_dir}/published.json")" == false ]]
[[ "$(jq -r '.tag_name' "${work_dir}/published.json")" == "${GITHUB_RELEASE_TAG}" ]]
echo "Published and verified GitHub mirror: $(jq -r '.html_url' "${work_dir}/published.json")"
