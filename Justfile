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
      rpm -q hyprland hypridle hyprlock hyprpolkitagent \
        xdg-desktop-portal-hyprland libvirt-daemon-kvm qemu-kvm \
        virt-manager plasma-login-manager bootc
      /usr/libexec/bazzite-firebadnofire-include-packages verify \
        /usr/share/bazzite-firebadnofire/include.txt
      test -s /usr/share/bazzite-firebadnofire/hyprland.conf
      Hyprland --verify-config --i-am-really-stupid \
        --config /usr/share/bazzite-firebadnofire/hyprland.conf
      test -x /usr/bin/looking-glass-client
      test -x /usr/libexec/xdg-desktop-portal-hyprland
      test -x /usr/libexec/hyprpolkitagent
      test -x /usr/libexec/bazzite-firebadnofire-start-hyprland
      test -x /usr/libexec/bazzite-firebadnofire-screenshot
      test -f /usr/share/wayland-sessions/hyprland.desktop
      grep -qx "Exec=/usr/libexec/bazzite-firebadnofire-start-hyprland" \
        /usr/share/wayland-sessions/hyprland.desktop
      grep -qx "DesktopNames=Hyprland" \
        /usr/share/wayland-sessions/hyprland.desktop
      test "$(systemctl is-enabled libvirtd.service)" = enabled
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
