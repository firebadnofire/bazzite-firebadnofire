#!/usr/bin/bash
# Transfer disk payloads through the dedicated runner's Docker daemon, not
# Actions blob storage. Never put credentials in these volumes or helpers.
set -Eeuo pipefail
trap 'echo "error: disk handoff failed at line ${LINENO} (${1:-unknown}); inspect daemon access, volume labels, and available storage" >&2' ERR

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_RUN_ID:?}"
: "${GITHUB_RUN_ATTEMPT:?}"
: "${GITHUB_SHA:?}"
: "${IMAGE_DIGEST:?}"
: "${HANDOFF_DAEMON_ID:?}"
: "${BIB_IMAGE:?}"
[[ "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "${GITHUB_RUN_ID}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT}" =~ ^[0-9]+$ ]]
[[ "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]]
[[ "$(docker info --format '{{.ID}}')" == "${HANDOFF_DAEMON_ID}" ]] || {
    echo "error: handoff requires the same dedicated Docker daemon in every job; check runner scheduling" >&2
    exit 1
}
repository_hash="$(printf '%s' "${GITHUB_REPOSITORY}" | sha256sum)"
scope="${repository_hash:0:16}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
digest_hex="${IMAGE_DIGEST#sha256:}"

select_volume() {
    local format="$1"
    [[ "${format}" == qcow2 || "${format}" == iso ]]
    volume="disk-handoff-${scope}-${format}"
    helper="${volume}-copy"
    filename="bazzite-firebadnofire-${GITHUB_SHA:0:12}-${digest_hex:0:12}.${format}"
}

verify_volume() {
    [[ "$(docker volume inspect --format '{{index .Labels "handoff.scope"}}' "${volume}")" == "${scope}" ]]
    [[ "$(docker volume inspect --format '{{index .Labels "handoff.revision"}}' "${volume}")" == "${GITHUB_SHA}" ]]
    [[ "$(docker volume inspect --format '{{index .Labels "handoff.digest"}}' "${volume}")" == "${IMAGE_DIGEST}" ]]
}

remove_helper() {
    if docker container inspect "${helper}" >/dev/null 2>&1; then
        [[ "$(docker container inspect --format '{{index .Config.Labels "handoff.scope"}}' "${helper}")" == "${scope}" ]]
        docker rm -f "${helper}" >/dev/null
    fi
}

case "${1:-}" in
    check)
        echo "Disk handoff daemon identity verified"
        ;;
    stage)
        select_volume "${2:?format required}"
        [[ -s "release-input/${filename}" && ! -L "release-input/${filename}" ]]
        # A retry in the same attempt may replace only its own validated volume.
        if docker volume inspect "${volume}" >/dev/null 2>&1; then
            verify_volume
            remove_helper
            docker volume rm "${volume}" >/dev/null
        fi
        docker volume create --label "handoff.scope=${scope}" \
            --label "handoff.revision=${GITHUB_SHA}" \
            --label "handoff.digest=${IMAGE_DIGEST}" "${volume}" >/dev/null
        (cd release-input; sha256sum "${filename}" > SHA256SUMS)
        trap remove_helper EXIT
        # A stopped helper only: no code from the builder image is executed.
        docker create --name "${helper}" --label "handoff.scope=${scope}" \
            --volume "${volume}:/handoff" --entrypoint /usr/bin/true "${BIB_IMAGE}" >/dev/null
        docker cp "release-input/${filename}" "${helper}:/handoff/${filename}"
        docker cp release-input/SHA256SUMS "${helper}:/handoff/SHA256SUMS"
        echo "Staged ${filename} in ${volume}"
        ;;
    collect)
        mkdir -p release
        for format in qcow2 iso; do
            select_volume "${format}"
            verify_volume
            temporary_dir="$(mktemp -d)"
            trap 'remove_helper; rm -rf "${temporary_dir}"' EXIT
            docker create --name "${helper}" --label "handoff.scope=${scope}" \
                --volume "${volume}:/handoff:ro" --entrypoint /usr/bin/true "${BIB_IMAGE}" >/dev/null
            docker cp "${helper}:/handoff/." "${temporary_dir}/"
            [[ -f "${temporary_dir}/${filename}" && ! -L "${temporary_dir}/${filename}" ]]
            [[ -f "${temporary_dir}/SHA256SUMS" && ! -L "${temporary_dir}/SHA256SUMS" ]]
            [[ "$(find "${temporary_dir}" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]]
            # Compare the complete expected checksum line, never interpret paths
            # supplied by an untrusted checksum file.
            actual="$(cd "${temporary_dir}"; sha256sum "${filename}")"
            [[ "$(cat "${temporary_dir}/SHA256SUMS")" == "${actual}" ]] || {
                echo "error: handoff checksum mismatch for ${filename}" >&2; exit 1;
            }
            mv "${temporary_dir}/${filename}" "release/${filename}"
            remove_helper
            rm -rf "${temporary_dir}"
            trap - EXIT
            echo "Verified handoff: ${filename}"
        done
        ;;
    cleanup)
        for format in qcow2 iso; do
            select_volume "${format}"
            if docker volume inspect "${volume}" >/dev/null 2>&1; then
                verify_volume
                remove_helper
                docker volume rm "${volume}" >/dev/null
                echo "Removed run-scoped handoff volume ${volume}"
            fi
        done
        ;;
    *) echo "usage: $0 check | stage {qcow2|iso} | collect | cleanup" >&2; exit 2 ;;
esac
