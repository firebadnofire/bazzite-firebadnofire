#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf -- "${workdir}"' EXIT
log="${workdir}/docker.log"

cat > "${workdir}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG}"
if [[ "$*" == "container inspect forgejo-runner-dind" ]]; then exit 0; fi
if [[ "$*" == *"volume inspect"*"bazzite-firebadnofire-ci-gc-lock-v1"* ]]; then
    [[ "$*" == *"--format"* ]] && echo gc-lock
    exit 0
fi
if [[ "$*" == *" ps --format "* ]]; then exit 0; fi
if [[ "$*" == *" system df"* ]]; then echo "fake docker usage"; exit 0; fi
if [[ "$*" == *" ps -a "* ]]; then echo stale-container; exit 0; fi
if [[ "$*" == *"container inspect --format"*"io.firebadnofire.ci.created"* ]]; then echo 1; exit 0; fi
if [[ "$*" == *" volume ls "* ]]; then echo stale-volume; exit 0; fi
if [[ "$*" == *"volume inspect --format"*"io.firebadnofire.ci.created"* ]]; then echo 1; exit 0; fi
echo "unexpected fake docker invocation: $*" >&2
exit 1
EOF
chmod 0755 "${workdir}/docker"

output="$(PATH="${workdir}:${PATH}" FAKE_DOCKER_LOG="${log}" CI_GC_NOW=999999 \
    bash "${root}/ops/forgejo-runner/bazzite-firebadnofire-ci-gc" --dry-run)"
grep -Fq "Would remove stale CI container: stale-container" <<<"${output}"
grep -Fq "Would remove stale CI volume: stale-volume" <<<"${output}"
grep -Fq "Would prune unused BuildKit cache" <<<"${output}"
if grep -Eq ' exec forgejo-runner-dind docker (rm|volume rm|image prune|builder prune)' "${log}"; then
    echo "error: dry-run issued a destructive Docker command" >&2
    exit 1
fi
echo "CI garbage-collection dry-run test passed"
