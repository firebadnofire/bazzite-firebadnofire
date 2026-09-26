set dotenv-filename := "bazzite-firebadnofire.env"
set dotenv-load := true

image_name := env_var("IMAGE_NAME")
image_registry := env_var("IMAGE_REGISTRY")
repo_organization := env_var("REPO_ORGANIZATION")
repo_url := env_var("REPO_URL")
image_desc := env_var("IMAGE_DESC")
image_keywords := env_var("IMAGE_KEYWORDS")
default_tag := env_var("DEFAULT_TAG")
bib_image := env_var("BIB_IMAGE")
engine := env_var_or_default("CONTAINER_ENGINE", "podman")
published_image := image_registry + "/" + repo_organization + "/" + image_name

[private]
default:
    @just --list

validate:
    bash scripts/validate-static.sh

build target=("localhost/" + image_name) tag=default_tag:
    #!/usr/bin/env bash
    set -Eeuo pipefail

    created="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
    revision="$(git -c safe.directory="${PWD}" rev-parse HEAD)"
    version="{{ tag }}.$(date --utc +%Y%m%d)-${revision:0:12}"

    {{ engine }} build \
      --pull \
      --platform linux/amd64 \
      --build-arg "IMAGE_BUILD_DATE=${created}" \
      --label "org.opencontainers.image.created=${created}" \
      --label "org.opencontainers.image.description={{ image_desc }}" \
      --label "org.opencontainers.image.documentation={{ repo_url }}" \
      --label "org.opencontainers.image.revision=${revision}" \
      --label "org.opencontainers.image.source={{ repo_url }}" \
      --label "org.opencontainers.image.title={{ image_name }}" \
      --label "org.opencontainers.image.url={{ repo_url }}" \
      --label "org.opencontainers.image.vendor={{ repo_organization }}" \
      --label "org.opencontainers.image.version=${version}" \
      --label "io.artifacthub.package.keywords={{ image_keywords }}" \
      --tag "{{ target }}:{{ tag }}" \
      --file Containerfile \
      .

inspect target=("localhost/" + image_name) tag=default_tag:
    #!/usr/bin/env bash
    set -Eeuo pipefail
    {{ engine }} run --rm --entrypoint /usr/bin/bash "{{ target }}:{{ tag }}" -c '
      set -Eeuo pipefail
      bootc container lint --fatal-warnings
      export XDG_RUNTIME_DIR=/tmp/hyprland-verify
      install -d -m 0700 "${XDG_RUNTIME_DIR}"
      rpm -q dolphin foot hyprland hyprland-guiutils hypridle hyprlock hyprpolkitagent \
        xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
        xdg-user-dirs libvirt-daemon-kvm qemu-kvm \
        virt-manager plasma-login-manager bootc
      /usr/libexec/bazzite-firebadnofire-include-packages verify \
        /usr/share/bazzite-firebadnofire/include.txt
      test -s /usr/share/bazzite-firebadnofire/hyprland.lua
      test -s /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
      grep -Fqx "prefix = \"pubcode.archuser.org/universalblue/bazzite-firebadnofire\"" /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
      grep -Fqx "location = \"ghcr.io/firebadnofire/bazzite-firebadnofire\"" /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
      grep -A4 -F "[[registry]]" /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf | \
        grep -Fqx "location = \"pubcode.archuser.org/universalblue/bazzite-firebadnofire\""
      grep -A4 -F "[[registry.mirror]]" /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf | \
        grep -Fqx "location = \"ghcr.io/firebadnofire/bazzite-firebadnofire\""
      Hyprland --verify-config --i-am-really-stupid \
        --config /usr/share/bazzite-firebadnofire/hyprland.lua
      test -x /usr/bin/looking-glass-client
      test -x /usr/bin/vfio-host-recover
      test -x /usr/bin/vfio-host-check
      /usr/libexec/bazzite-firebadnofire-vfio-run check-deployment
      test "$(systemctl is-enabled bazzite-firebadnofire-vfio-reconcile.timer)" = enabled
      test -s /usr/share/licenses/bazzite-firebadnofire-vfio/COPYING
      test -x /usr/libexec/xdg-desktop-portal-hyprland
      test -x /usr/libexec/xdg-desktop-portal-gtk
      test -x /usr/libexec/xdg-desktop-portal
      test -x /usr/libexec/hyprpolkitagent
      test -x /usr/bin/foot
      test -x /usr/bin/start-hyprland
      test -x /usr/bin/hyprland-dialog
      test -x /usr/libexec/bazzite-firebadnofire-start-hyprland
      test -x /usr/libexec/bazzite-firebadnofire-screenshot
      test -x /usr/bin/xdg-user-dirs-update
      test -x /usr/bin/dolphin
      test -L /etc/os-release
      test "$(readlink /etc/os-release)" = ../usr/lib/os-release
      grep -Fqx "NAME=\"firebadnofire-bazzite\"" /etc/os-release
      grep -Fqx "PRETTY_NAME=\"firebadnofire-bazzite\"" /etc/os-release
      grep -Fqx "ID=bazzite" /etc/os-release
      grep -Fqx "ID_LIKE=\"fedora\"" /etc/os-release
      test -f /usr/share/wayland-sessions/hyprland.desktop
      grep -qx "Exec=/usr/libexec/bazzite-firebadnofire-start-hyprland" \
        /usr/share/wayland-sessions/hyprland.desktop
      grep -qx "TryExec=/usr/bin/start-hyprland" \
        /usr/share/wayland-sessions/hyprland.desktop
      grep -qx "DesktopNames=Hyprland" \
        /usr/share/wayland-sessions/hyprland.desktop
      test -f /usr/lib/systemd/user/hyprland-session.target
      test -f /usr/lib/systemd/user/graphical-session.target
      test -f /usr/lib/systemd/user/xdg-desktop-portal.service
      test -f /usr/lib/systemd/user/xdg-desktop-portal-hyprland.service
      test -f /usr/lib/systemd/user/plasma-dolphin.service
      grep -Fqx "BindsTo=graphical-session.target" \
        /usr/lib/systemd/user/hyprland-session.target
      grep -Fqx "After=graphical-session-pre.target graphical-session.target" \
        /usr/lib/systemd/user/hyprland-session.target
      ! grep -Fq "PropagatesStopTo=graphical-session.target" \
        /usr/lib/systemd/user/hyprland-session.target
      grep -Fqx "StopWhenUnneeded=yes" \
        /usr/lib/systemd/user/graphical-session.target
      grep -Fqx "Requisite=graphical-session.target" \
        /usr/lib/systemd/user/xdg-desktop-portal.service
      grep -Fqx "After=graphical-session.target" \
        /usr/lib/systemd/user/xdg-desktop-portal.service
      test -f /usr/share/xdg-desktop-portal/hyprland-portals.conf
      test -f /usr/share/xdg-desktop-portal/portals/hyprland.portal
      test -f /usr/share/dbus-1/services/org.kde.dolphin.FileManager1.service
      grep -Fqx "default=hyprland;gtk" \
        /usr/share/xdg-desktop-portal/hyprland-portals.conf
      grep -Fqx "org.freedesktop.impl.portal.FileChooser=gtk" \
        /usr/share/xdg-desktop-portal/hyprland-portals.conf
      grep -Fq "org.freedesktop.impl.portal.ScreenCast" \
        /usr/share/xdg-desktop-portal/portals/hyprland.portal
      grep -Fqx "Name=org.freedesktop.FileManager1" \
        /usr/share/dbus-1/services/org.kde.dolphin.FileManager1.service
      grep -Fqx "DOWNLOAD=Downloads" /etc/xdg/user-dirs.defaults
      test "$(systemctl is-enabled virtqemud.service)" = enabled
      test "$(systemctl is-enabled podman.socket)" = enabled
      test "$(systemctl is-enabled plasmalogin.service)" = enabled
      test "$(readlink -f /etc/systemd/system/display-manager.service)" = \
        /usr/lib/systemd/system/plasmalogin.service
      ! ldd /usr/bin/looking-glass-client | grep -q "not found"
    '

image-ref tag=default_tag:
    @echo "{{ published_image }}:{{ tag }}"

[private]
build-disk image type config:
    #!/usr/bin/env bash
    set -Eeuo pipefail

    command -v podman >/dev/null || {
      echo "error: bootc-image-builder requires rootful Podman" >&2
      exit 1
    }

    mkdir -p output
    sudo podman run --rm --privileged --pull=newer --net=host \
      --security-opt label=type:unconfined_t \
      --volume "${PWD}/{{ config }}:/config.toml:ro,Z" \
      --volume "${PWD}/output:/output:Z" \
      "{{ bib_image }}" \
      --type "{{ type }}" \
      --rootfs btrfs \
      --use-librepo=true \
      "{{ image }}"
    sudo chown -R "$(id -u):$(id -g)" output

build-qcow2 image=(published_image + ":" + default_tag): (build-disk image "qcow2" "disk_config/disk.toml")

build-iso image=(published_image + ":" + default_tag): (build-disk image "anaconda-iso" "disk_config/iso.toml")
