#!/usr/bin/env bash

set -Eeuo pipefail

readonly action="${1:-}"
readonly lock_volume="bazzite-firebadnofire-ci-gc-lock-v1"
readonly lock_image="${CI_GC_LOCK_IMAGE:-docker.io/library/alpine:3.22@sha256:9db2934886712d877c932e07249c75a59e6ca27adfbccc05261987a17bef2d63}"
readonly run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
readonly lease="bazzite-ci-lease-${GITHUB_RUN_ID:-local}-${run_attempt}"
readonly ready_file="/lock/${lease}.ready"

acquire() {
    docker volume create \
        --label io.firebadnofire.ci.protected=true \
        --label io.firebadnofire.ci.role=gc-lock \
        "${lock_volume}" >/dev/null
    [[ "$(docker volume inspect --format \
        '{{index .Labels "io.firebadnofire.ci.role"}}' "${lock_volume}")" == gc-lock ]]

    docker rm -f "${lease}" >/dev/null 2>&1 || true
    docker run --detach --name "${lease}" \
        --label io.firebadnofire.ci.project=bazzite-firebadnofire \
        --label io.firebadnofire.ci.role=gc-lease \
        --label "io.firebadnofire.ci.run=${GITHUB_RUN_ID:-local}" \
        --label "io.firebadnofire.ci.created=$(date +%s)" \
        --volume "${lock_volume}:/lock" \
        --entrypoint /bin/sh "${lock_image}" -c \
        "rm -f '${ready_file}'; exec flock -s /lock/gc.lock -c 'touch ${ready_file}; exec sleep 86400'" \
        >/dev/null

    for _ in $(seq 1 120); do
        if docker exec "${lease}" test -e "${ready_file}"; then
            echo "Acquired shared CI cleanup lease: ${lease}"
            echo "CI_GC_LEASE_CONTAINER=${lease}" >> "${GITHUB_ENV:-/dev/null}"
            return 0
        fi
        if ! docker container inspect "${lease}" >/dev/null 2>&1; then
            echo "error: CI cleanup lease container disappeared before acquiring the lock" >&2
            return 1
        fi
        sleep 1
    done
    echo "error: timed out waiting for the shared CI cleanup lease" >&2
    docker logs "${lease}" >&2 || true
    return 1
}

release() {
    if ! command -v docker >/dev/null; then
        echo "Docker is unavailable; no CI cleanup lease can be released"
        return 0
    fi
    if docker container inspect "${lease}" >/dev/null 2>&1; then
        docker rm -f "${lease}" >/dev/null
        echo "Released shared CI cleanup lease: ${lease}"
    else
        echo "CI cleanup lease is already absent: ${lease}"
    fi
}

case "${action}" in
    acquire) acquire ;;
    release) release ;;
    *) echo "usage: $0 {acquire|release}" >&2; exit 2 ;;
esac
