#!/usr/bin/bash

set -Eeuo pipefail

report_publish_failure() {
    local operation="$1"
    local reference="$2"
    local endpoint_status

    : "${IMAGE_REGISTRY:?IMAGE_REGISTRY is required for publication diagnostics}"
    echo "error: ${operation} failed for ${reference}" >&2
    echo "Publication failure diagnostics at $(date --utc +%Y-%m-%dT%H:%M:%SZ):" >&2
    if ! docker info --format \
        'Docker daemon reachable: ID={{.ID}} driver={{.Driver}} root={{.DockerRootDir}} containers={{.Containers}} images={{.Images}}' >&2; then
        echo "error: Docker daemon is not reachable from the job" >&2
    fi
    df -hT / >&2
    df -ih / >&2
    free -h >&2
    if [[ -r /sys/fs/cgroup/memory.events ]]; then
        echo "Job cgroup memory events:" >&2
        cat /sys/fs/cgroup/memory.events >&2
    fi
    if ! getent ahosts "${IMAGE_REGISTRY}" >&2; then
        echo "error: registry DNS lookup failed for ${IMAGE_REGISTRY}" >&2
    fi
    if endpoint_status="$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --connect-timeout 10 --max-time 30 \
        "https://${IMAGE_REGISTRY}/v2/")"; then
        echo "Registry /v2/ unauthenticated HTTP status: ${endpoint_status}" >&2
    else
        echo "error: registry /v2/ connectivity check failed" >&2
    fi
}

push_reference() {
    local reference="$1"
    local status

    echo "Pushing ${reference} at $(date --utc +%Y-%m-%dT%H:%M:%SZ)"
    if docker push "${reference}"; then
        return 0
    else
        status="$?"
    fi
    echo "error: docker push returned status ${status}" >&2
    report_publish_failure "docker push" "${reference}"
    return "${status}"
}

resolve_digest() {
    local reference="$1"
    local manifest_json
    local status

    if manifest_json="$(docker buildx imagetools inspect \
        "${reference}" --format '{{json .Manifest}}')"; then
        python3 -c \
            'import json, sys; print(json.load(sys.stdin)["digest"])' \
            <<<"${manifest_json}"
        return 0
    else
        status="$?"
    fi
    echo "error: registry digest resolution returned status ${status}" >&2
    report_publish_failure "registry digest resolution" "${reference}"
    return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "error: source scripts/oci-publication.sh before calling its functions" >&2
    exit 2
fi
