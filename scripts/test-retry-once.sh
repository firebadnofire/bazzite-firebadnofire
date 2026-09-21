#!/usr/bin/bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
source "${root}/scripts/retry-once.sh"

attempts=0
succeed_on_second_attempt() {
    ((attempts += 1))
    [[ "${attempts}" -eq 2 ]]
}

retry_once succeed_on_second_attempt 2>/dev/null
[[ "${attempts}" -eq 2 ]] || {
    echo "error: retry_once did not retry exactly once before success" >&2
    exit 1
}

attempts=0
always_fail() {
    ((attempts += 1))
    return 23
}

error_log="$(mktemp)"
readonly error_log
trap 'rm -f -- "${error_log}"' EXIT

status=0
retry_once always_fail 2>"${error_log}" || status="$?"
[[ "${status}" -eq 23 ]] || {
    echo "error: retry_once did not preserve the final failure status" >&2
    exit 1
}
[[ "${attempts}" -eq 2 ]] || {
    echo "error: retry_once performed ${attempts} attempts instead of 2" >&2
    exit 1
}
[[ "$(grep -Fc 'retrying once' "${error_log}")" -eq 1 ]] || {
    echo "error: retry_once did not report exactly one retry" >&2
    exit 1
}
[[ "$(grep -Fc 'failed after attempt 2 of 2' "${error_log}")" -eq 1 ]] || {
    echo "error: retry_once did not report final failure" >&2
    exit 1
}

echo "retry-once tests passed"
