#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Opt-in integration test of a BUILT image. No host GPU or host libvirt socket
# is exposed. This is not a bootc upgrade test or a physical handoff test.
set -Eeuo pipefail

image="${1:-localhost/bazzite-firebadnofire:vfio-test}"
if [[ $# -gt 1 ]]; then
    echo 'usage: scripts/test-vfio-container.sh [IMAGE]' >&2
    exit 3
fi
container_id=''
cleanup() {
    local result=$?
    if [[ -n ${container_id} ]]; then
        if ! podman rm --force --time 0 "${container_id}" >/dev/null; then
            echo "error: could not remove test container ${container_id}" >&2
            exit 1
        fi
    fi
    exit "${result}"
}
trap cleanup EXIT

devices=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    devices+=(--device /dev/kvm)
fi
container_id="$(podman run --detach --init "${devices[@]}" \
    --entrypoint /usr/bin/sleep "${image}" infinity)"
podman exec --interactive "${container_id}" /usr/bin/bash <<'SETUP'
set -Eeuo pipefail
# Reproduce just the boot-created state needed by libvirt. PID 1 is a subreaper
# (--init) so QEMU capability probes cannot leave zombies and stall startup.
dbus-uuidgen > /etc/machine-id
mkdir -p /run/dbus /run/libvirt /var/log/libvirt
systemd-tmpfiles --create --prefix=/var/run --prefix=/var/lib/libvirt
cat > /etc/libvirt/hooks/qemu.d/10-existing-test-hook <<'HOOK'
#!/usr/bin/bash
printf '%s\n' "$1" >> /run/vfio-existing-hook-seen
HOOK
chmod 0755 /etc/libvirt/hooks/qemu.d/10-existing-test-hook
dbus-daemon --system --fork
virtlogd -d
virtqemud -d
SETUP

ready=false
for ((attempt = 0; attempt < 30; attempt++)); do
    if podman exec "${container_id}" timeout 5 virsh -c qemu:///system uri >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done
if [[ ${ready} != true ]]; then
    echo 'error: isolated libvirt did not become ready' >&2
    exit 1
fi
podman exec "${container_id}" vfio-host-check
podman exec "${container_id}" grep -q '^vfio-hook-probe-' /run/vfio-existing-hook-seen
podman exec "${container_id}" /usr/bin/bash -c \
    'printf "\n# preserved local comment\n" >> /etc/libvirt/hooks/qemu.d/90-bazzite-firebadnofire-vfio'
podman exec "${container_id}" vfio-host-check
[[ -z "$(podman exec "${container_id}" virsh -c qemu:///system list --all --uuid)" ]]
echo 'isolated libvirt activation and hook coexistence passed (not bootc or physical validation)'
