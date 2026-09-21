#!/usr/bin/bash
# Optional integration test: uses only small fixtures and run-scoped volumes.
# Requires a reachable Docker daemon and an already pulled BIB_IMAGE.
set -Eeuo pipefail
: "${BIB_IMAGE:?Set BIB_IMAGE to an already pulled helper image}"
script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/disk-handoff.sh"
readonly script
temporary_workspace="$(mktemp -d)"
export GITHUB_REPOSITORY=local/disk-handoff-test
export GITHUB_RUN_ID="${RANDOM}${RANDOM}"
export GITHUB_RUN_ATTEMPT=1
export GITHUB_SHA=1111111111111111111111111111111111111111
export IMAGE_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
HANDOFF_DAEMON_ID="$(docker info --format '{{.ID}}')"
export HANDOFF_DAEMON_ID
cleanup() {
    bash "${script}" cleanup
    rm -rf "${temporary_workspace}"
}
trap cleanup EXIT
cd "${temporary_workspace}"
mkdir release-input
prefix=bazzite-firebadnofire-111111111111-222222222222
for format in qcow2 iso; do
    printf 'fixture %s\n' "${format}" > "release-input/${prefix}.${format}"
    bash "${script}" stage "${format}"
    bash "${script}" stage "${format}"
done
bash "${script}" collect
cmp "release-input/${prefix}.qcow2" "release/${prefix}.qcow2"
cmp "release-input/${prefix}.iso" "release/${prefix}.iso"
if HANDOFF_DAEMON_ID=wrong-daemon bash "${script}" check; then
    echo 'error: accepted the wrong daemon' >&2; exit 1
fi
if GITHUB_RUN_ATTEMPT=2 bash "${script}" collect; then
    echo 'error: accepted outputs from a different attempt' >&2; exit 1
fi

# Corrupt one staged payload without changing its checksum, using a stopped
# helper. Collection must fail before any signing step could use it.
repository_hash="$(printf '%s' "${GITHUB_REPOSITORY}" | sha256sum)"
volume="disk-handoff-${repository_hash:0:16}-${GITHUB_RUN_ID}-1-qcow2"
helper="${volume}-copy"
docker create --name "${helper}" \
    --label "handoff.scope=${repository_hash:0:16}-${GITHUB_RUN_ID}-1" \
    --volume "${volume}:/handoff" --entrypoint /usr/bin/true "${BIB_IMAGE}" >/dev/null
printf 'corrupt fixture\n' > bad-payload
docker cp bad-payload "${helper}:/handoff/${prefix}.qcow2"
docker rm "${helper}" >/dev/null
if bash "${script}" collect; then
    echo 'error: accepted a corrupted payload' >&2; exit 1
fi
bash "${script}" cleanup
bash "${script}" cleanup

# ISO-only workflows must be able to collect and clean a single format without
# requiring a QCOW2 volume from the same run.
export GITHUB_RUN_ID="${RANDOM}${RANDOM}"
export HANDOFF_FORMATS=iso
rm -rf release release-input
mkdir release-input
printf 'iso-only fixture\n' > "release-input/${prefix}.iso"
bash "${script}" stage iso
bash "${script}" collect
cmp "release-input/${prefix}.iso" "release/${prefix}.iso"
bash "${script}" cleanup

# The network installer uses a distinct handoff format and a .net.iso suffix so
# it cannot be confused with the offline installer from the same revision.
export GITHUB_RUN_ID="${RANDOM}${RANDOM}"
export HANDOFF_FORMATS=netiso
rm -rf release release-input
mkdir release-input
printf 'network iso fixture\n' > "release-input/${prefix}.net.iso"
bash "${script}" stage netiso
bash "${script}" collect
cmp "release-input/${prefix}.net.iso" "release/${prefix}.net.iso"
bash "${script}" cleanup
echo 'disk handoff integration tests passed'
