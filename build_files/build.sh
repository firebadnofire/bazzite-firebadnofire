#!/usr/bin/bash

set -Eeuo pipefail

readonly HYPRLAND_COPR="lionheartp/Hyprland"

desktop_packages=(
    blueman brightnessctl cliphist foot fuzzel grim network-manager-applet
    pavucontrol playerctl qt5-qtwayland qt6-qtwayland slurp
    SwayNotificationCenter waybar wl-clipboard xdg-desktop-portal-gtk
)

admin_packages=(
    bat dmidecode fd-find gh git-lfs hwinfo iperf3 iotop lsscsi minicom
    mosh ncdu nmap-ncat pv ripgrep screen strace sysstat tree wget
    wireshark-cli
)

development_packages=(
    cmake gcc gcc-c++ make meson ninja-build pkgconf-pkg-config python3-pip
)

virtualization_packages=(
    libguestfs-tools libvirt libvirt-client libvirt-daemon-kvm
    qemu-kvm spice-gtk swtpm swtpm-tools virt-install virt-manager virt-viewer
)

looking_glass_build_packages=(
    binutils-devel cmake dejavu-sans-mono-fonts fontconfig-devel
    libdecor-devel libglvnd-devel libsamplerate-devel libXcursor-devel
    libXi-devel libXinerama-devel libXpresent-devel libXrandr-devel
    libXScrnSaver-devel libxkbcommon-x11-devel make nettle-devel
    pipewire-devel pkgconf-pkg-config pulseaudio-libs-devel spice-protocol wayland-devel
    wayland-protocols-devel
)

# Fedora does not currently ship Hyprland for Fedora 44. Enable this narrowly
# scoped, GPG-checked COPR only for the packages Bazzite needs, then disable it
# so installed systems do not receive unreviewed packages from it implicitly.
dnf5 -y copr enable "${HYPRLAND_COPR}"
dnf5 -y install \
    hypridle \
    hyprland \
    hyprland-guiutils \
    hyprlock \
    hyprpaper \
    hyprpolkitagent \
    xdg-desktop-portal-hyprland
dnf5 -y copr disable "${HYPRLAND_COPR}"

dnf5 -y install \
    "${desktop_packages[@]}" \
    "${admin_packages[@]}" \
    "${development_packages[@]}" \
    "${virtualization_packages[@]}" \
    "${looking_glass_build_packages[@]}"

# Keep repository-root include.txt as the single source of truth for optional
# base-image RPMs. This is a normal image-build transaction: resolver or install
# failures are fatal, and an empty manifest is a valid no-op.
install -D -m 0644 \
    /ctx/include.txt \
    /usr/share/bazzite-firebadnofire/include.txt
install -D -m 0755 \
    /ctx/include-packages.sh \
    /usr/libexec/bazzite-firebadnofire-include-packages
/usr/libexec/bazzite-firebadnofire-include-packages install \
    /usr/share/bazzite-firebadnofire/include.txt

# Fedora 44 has no maintained Looking Glass client package. Build the current
# stable upstream source archive (which includes its submodules) after checking
# its pinned digest. Do not install the optional kvmfr kernel module: IVSHMEM,
# SELinux policy, PCI binding, and guest/host pairing are machine-specific.
readonly LOOKING_GLASS_VERSION="B7"
readonly LOOKING_GLASS_SHA256="09e506660ccc1b9691d06caa70179b52ffb4393299895cff3c2f0e74fcd69985"
readonly looking_glass_archive="/tmp/looking-glass-${LOOKING_GLASS_VERSION}.tar.gz"

curl --fail --location --silent --show-error \
    --output "${looking_glass_archive}" \
    https://looking-glass.io/artifact/stable/source
printf '%s  %s\n' "${LOOKING_GLASS_SHA256}" "${looking_glass_archive}" |
    sha256sum --check --strict
tar --extract --gzip --file "${looking_glass_archive}" --directory /tmp
cmake \
    -S "/tmp/looking-glass-${LOOKING_GLASS_VERSION}/client" \
    -B "/tmp/looking-glass-${LOOKING_GLASS_VERSION}/client/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-Wno-error=maybe-uninitialized" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DENABLE_BACKTRACE=OFF \
    -DENABLE_LIBDECOR=ON \
    -DOPTIMIZE_FOR_NATIVE=OFF
cmake --build "/tmp/looking-glass-${LOOKING_GLASS_VERSION}/client/build" \
    --parallel "$(nproc)"
cmake --install "/tmp/looking-glass-${LOOKING_GLASS_VERSION}/client/build"
install -D -m 0644 \
    "/tmp/looking-glass-${LOOKING_GLASS_VERSION}/LICENSE" \
    /usr/share/licenses/looking-glass-client/LICENSE

# Copy after package installation so intentional session and system defaults in
# the repository win over package defaults.
cp -avf /ctx/system_files/. /

# Customize the human-facing image name in the authoritative os-release file.
# Preserve ID, ID_LIKE, VARIANT_ID, and upstream release/support metadata so
# software continues to recognize the image as Bazzite/Fedora compatible.
sed -i \
    -e 's/^NAME=.*/NAME="firebadnofire-bazzite"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="firebadnofire-bazzite"/' \
    /usr/lib/os-release

chmod 0755 \
    /usr/libexec/bazzite-firebadnofire-rotate-wallpaper \
    /usr/libexec/bazzite-firebadnofire-screenshot \
    /usr/libexec/bazzite-firebadnofire-start-hyprland

# Package scriptlets may create deployment-time state while building the image.
# /boot and /run must be clean in a bootc container; persistent /var directory
# ownership is declared in the tmpfiles overlay copied above.
rm -rf \
    /boot/extlinux \
    /run/dnf \
    /run/gluster \
    /run/screen \
    /run/selinux-policy

systemctl enable libvirtd.service podman.socket

# Fail the image build if the user-facing workstation contract is incomplete.
rpm -q \
    foot \
    hyprland \
    hyprland-guiutils \
    hypridle \
    hyprlock \
    hyprpaper \
    hyprpolkitagent \
    libvirt-daemon-kvm \
    plasma-login-manager \
    qemu-kvm \
    virt-manager \
    xdg-desktop-portal-hyprland
/usr/libexec/bazzite-firebadnofire-include-packages verify \
    /usr/share/bazzite-firebadnofire/include.txt
test -x /usr/libexec/bazzite-firebadnofire-start-hyprland
test -x /usr/bin/foot
test -x /usr/bin/start-hyprland
test -x /usr/bin/hyprland-dialog
test -x /usr/libexec/bazzite-firebadnofire-screenshot
test -x /usr/libexec/bazzite-firebadnofire-rotate-wallpaper
test -x /usr/bin/looking-glass-client
test -x /usr/libexec/xdg-desktop-portal-hyprland
test -x /usr/libexec/hyprpolkitagent
test -L /etc/os-release
test "$(readlink /etc/os-release)" = ../usr/lib/os-release
grep -Fqx 'NAME="firebadnofire-bazzite"' /etc/os-release
grep -Fqx 'PRETTY_NAME="firebadnofire-bazzite"' /etc/os-release
grep -Fqx 'ID=bazzite' /etc/os-release
grep -Fqx 'ID_LIKE="fedora"' /etc/os-release
test -f /usr/share/wayland-sessions/hyprland.desktop
test -f /usr/share/bazzite-firebadnofire/hyprland.lua
test -f /usr/share/bazzite-firebadnofire/hypridle.conf
test -f /usr/share/bazzite-firebadnofire/hyprlock.conf
test -f /usr/share/bazzite-firebadnofire/hyprpaper.conf
test -f /usr/share/bazzite-firebadnofire/waybar/config.jsonc
test -f /usr/lib/tmpfiles.d/bazzite-firebadnofire.conf
test -f /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
grep -Fqx 'prefix = "pubcode.archuser.org/universalblue/bazzite-firebadnofire"' \
    /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
grep -Fqx 'location = "ghcr.io/firebadnofire/bazzite-firebadnofire"' \
    /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
grep -Fqx 'location = "pubcode.archuser.org/universalblue/bazzite-firebadnofire"' \
    /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
grep -qx 'Exec=/usr/libexec/bazzite-firebadnofire-start-hyprland' \
    /usr/share/wayland-sessions/hyprland.desktop
grep -qx 'DesktopNames=Hyprland' \
    /usr/share/wayland-sessions/hyprland.desktop
test "$(systemctl is-enabled libvirtd.service)" = "enabled"
test "$(systemctl is-enabled podman.socket)" = "enabled"
test "$(systemctl is-enabled plasmalogin.service)" = "enabled"
test "$(readlink -f /etc/systemd/system/display-manager.service)" = \
    /usr/lib/systemd/system/plasmalogin.service

# Run after all RPM transactions and overlays so package updates cannot undo
# the solver-compatible URLs. Keep the packaged public keys in the image.
bash /ctx/fix-terra-mesa-keys.sh
python3 /ctx/validate-repo-keys.py

dnf5 clean all
