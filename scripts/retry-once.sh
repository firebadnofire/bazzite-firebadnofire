#!/usr/bin/bash

set -Eeuo pipefail

retry_once() {
    (("$#" > 0)) || {
        echo "error: retry_once requires a command or function name" >&2
        return 2
    }

    local attempt
    local status=1
    for attempt in 1 2; do
        if "$@"; then
            return 0
        else
            status="$?"
        fi

        if [[ "${attempt}" -eq 1 ]]; then
            echo "warning: operation failed on attempt 1 of 2; retrying once" >&2
        else
            echo "error: operation failed after attempt 2 of 2" >&2
        fi
    done

    return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "error: source scripts/retry-once.sh before calling retry_once" >&2
    exit 2
fi
