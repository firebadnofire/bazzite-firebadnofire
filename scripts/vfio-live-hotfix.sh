#!/usr/bin/bash
# Temporary implementation override for an already booted image.
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo 'Run this script as root (sudo bash scripts/vfio-live-hotfix.sh).' >&2
    exit 1
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${root}/system_files/usr/libexec/bazzite-firebadnofire-vfio/v1/vfio.py"
target=/usr/libexec/bazzite-firebadnofire-vfio/v1/vfio.py
state=/var/lib/bazzite-firebadnofire/vfio
install -d -m 0700 /run/bazzite-firebadnofire-vfio
exec 9>/run/bazzite-firebadnofire-vfio/lock
flock -n 9
if [[ -e ${state}/owner.json ]] || compgen -G "${state}/claim-*.json" >/dev/null; then
    echo 'Outstanding VFIO ownership/recovery state; inspect with vfio-host-recover --status first.' >&2
    exit 1
fi
[[ -f ${target} && -f ${source_file} ]]
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "${source_file}"
if grep -q 'GPU device held by PID' "${source_file}"; then
    echo 'Source still contains the obsolete GPU-holder veto.' >&2
    exit 1
fi
# Unique root-owned copy; never bind a writable checkout into a privileged hook.
temporary="$(mktemp -d /run/vfio-live-hotfix.XXXXXX)"
installed=0
cleanup() {
    if (( installed == 0 )); then rm -rf -- "${temporary}"; fi
}
trap cleanup EXIT
install -m 0644 "${source_file}" "${temporary}/vfio.py"
if selinuxenabled; then
    chcon --reference="${target}" "${temporary}/vfio.py"
fi
mount --bind "${temporary}/vfio.py" "${target}"
installed=1
cmp "${temporary}/vfio.py" "${target}"
echo 'Corrected VFIO helper is active. No daemon restart or GPU operation was performed.'
echo 'This override disappears on reboot. Deploy the updated bootc image for a permanent fix.'
