# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY include.txt /include.txt
COPY system_files /system_files

# Bazzite's NVIDIA-open variant supports Turing and newer GPUs, including every
# GeForce RTX generation. Keep this digest synchronized with the stable tag.
FROM ghcr.io/ublue-os/bazzite-nvidia-open:stable@sha256:23ee832c0eb9e0ff79bc10f2958b2f3bede290841b258ee45826604228964e0d

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /usr/bin/bash /ctx/build.sh

# DNF's countme telemetry is disposable build cache, not deployment state.
RUN rm -rf /var/lib/dnf/repos

# Validate both the bootc contract and this image's workstation contract. Treat
# warnings as failures so mutable-state mistakes cannot quietly reach a release.
RUN bootc container lint --fatal-warnings
