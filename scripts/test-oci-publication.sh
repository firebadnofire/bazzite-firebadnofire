#!/usr/bin/bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
fake_bin="$(mktemp -d)"
readonly fake_bin
trap 'rm -rf -- "${fake_bin}"' EXIT

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/bash
set -Eeuo pipefail
case "${1:-}" in
    push)
        exit "${FAKE_PUSH_STATUS:-0}"
        ;;
    info)
        echo "Docker daemon reachable: ID=fake"
        ;;
    buildx)
        if [[ "${FAKE_RESOLVE_STATUS:-0}" -ne 0 ]]; then
            exit "${FAKE_RESOLVE_STATUS}"
        fi
        printf '{"digest":"sha256:%064d"}\n' 0
        ;;
    *)
        echo "unexpected fake docker invocation: $*" >&2
        exit 99
        ;;
esac
SH
cat >"${fake_bin}/curl" <<'SH'
#!/usr/bin/bash
printf '401'
SH
cat >"${fake_bin}/getent" <<'SH'
#!/usr/bin/bash
printf '127.0.0.1 STREAM registry.invalid\n'
SH
chmod 0755 "${fake_bin}/docker" "${fake_bin}/curl" "${fake_bin}/getent"

export PATH="${fake_bin}:${PATH}"
export IMAGE_REGISTRY=registry.invalid
source "${root}/scripts/oci-publication.sh"

log_file="$(mktemp)"
readonly log_file

export FAKE_PUSH_STATUS=42
status=0
push_reference registry.invalid/example:test >"${log_file}" 2>&1 || status="$?"
[[ "${status}" -eq 42 ]] || {
    echo "error: push_reference did not preserve docker push status 42" >&2
    exit 1
}
for expected in \
    "docker push returned status 42" \
    "Docker daemon reachable" \
    "Registry /v2/ unauthenticated HTTP status: 401"; do
    grep -Fq "${expected}" "${log_file}" || {
        echo "error: publication diagnostics omitted: ${expected}" >&2
        exit 1
    }
done
if [[ -r /sys/fs/cgroup/memory.events ]]; then
    grep -Fq "Job cgroup memory events" "${log_file}" || {
        echo "error: publication diagnostics omitted available cgroup memory events" >&2
        exit 1
    }
fi

export FAKE_RESOLVE_STATUS=0
digest="$(resolve_digest registry.invalid/example:test)"
[[ "${digest}" == "sha256:$(printf '%064d' 0)" ]] || {
    echo "error: resolve_digest did not return the registry descriptor digest" >&2
    exit 1
}

export FAKE_RESOLVE_STATUS=17
status=0
resolve_digest registry.invalid/example:test >"${log_file}" 2>&1 || status="$?"
[[ "${status}" -eq 17 ]] || {
    echo "error: resolve_digest did not preserve imagetools status 17" >&2
    exit 1
}
grep -Fq "registry digest resolution returned status 17" "${log_file}" || {
    echo "error: digest-resolution failure status was not diagnosed" >&2
    exit 1
}

rm -f -- "${log_file}"
echo "OCI publication helper tests passed"
