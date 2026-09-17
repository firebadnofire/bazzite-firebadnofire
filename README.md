# bazzite-firebadnofire

`bazzite-firebadnofire` is a personal x86_64 Universal Blue/bootc workstation
image. It layers a complete Hyprland session, administration and development
tools, and a libvirt/QEMU foundation over Bazzite's NVIDIA-open image while
retaining Bazzite's gaming and Steam/Gamescope integration.

The published image identity is:

```text
pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable
```

This is a personal image, not an official Bazzite or Universal Blue edition.
Read the [risk and validation status](#validation-status-and-known-risks) before
installing it on a workstation.

## Implemented product contract

| Area | Current implementation |
| --- | --- |
| Architecture | x86_64 only |
| Base | Digest-pinned `ghcr.io/ublue-os/bazzite-nvidia-open:stable` |
| GPU target | NVIDIA Turing and newer, including GeForce RTX; other hardware inherits the upstream Bazzite behavior |
| Desktop | Hyprland 0.56-compatible Lua configuration with XWayland |
| Gaming | Inherited Bazzite Steam, Gamescope, codecs, controller support, and gaming tools |
| Audio/video | Inherited PipeWire/WirePlumber plus pavucontrol and playerctl |
| Desktop plumbing | Waybar, Fuzzel, SwayNotificationCenter, NetworkManager and Bluetooth applets, portals, polkit agent, clipboard history, screenshots, idle locking |
| Administration | SSH and inherited networking/storage tools plus mosh, nmap, Wireshark CLI, iperf3, strace, ripgrep, fd, sysstat, hardware inspection, and serial-console utilities |
| Development | Podman/toolbox support from Bazzite plus GitHub CLI, Git LFS, GCC/C++, CMake, Meson, Ninja, pkg-config, and Python pip |
| Virtualization | QEMU/KVM, libvirt, virt-manager, virt-install, virt-viewer, swtpm, SPICE, libguestfs, and the Looking Glass B7 client |
| CI | Forgejo Actions on the global `ubuntu-22.04` runner label |
| Publication | Forgejo container registry on `pubcode.archuser.org` |
| Signing | Key-based Cosign signature over the immutable published digest |

The upstream image is KDE-derived. KDE libraries and useful applications such
as Dolphin remain installed because Bazzite does not publish a desktop-neutral
NVIDIA gaming base and removing the Plasma stack would create a fragile fork.
Hyprland is the configured workstation session; Plasma is retained as an
upstream recovery option, not customized or supported here as the primary
desktop.

## Repository layout

- `Containerfile` pins the reviewed Bazzite base and runs image construction.
- `build_files/build.sh` installs packages, copies the system overlay, enables
  services, and asserts the built image contract.
- `system_files/` contains the Hyprland session launcher and immutable defaults.
- `bazzite-firebadnofire.env` is the single image/registry/build identity file.
- `.forgejo/workflows/` contains image and disk-artifact workflows.
- `disk_config/` contains bootc-image-builder configuration.
- `scripts/validate-static.sh` is the local and CI repository gate.
- `Justfile` provides local build, inspection, and disk-artifact commands.
- `VISION.MD` describes the longer-term product direction. It is not a list of
  features that are automatically implemented.

## Hyprland environment

The display-manager entry launches
`/usr/libexec/bazzite-firebadnofire-start-hyprland`. On first launch it copies
the immutable defaults into `~/.config/hypr/` only when the corresponding user
file does not already exist. Image updates never replace user configuration.

The default session starts:

- Waybar and SwayNotificationCenter;
- `nm-applet` and `blueman-applet`;
- `hyprpolkitagent` through its user service;
- `hypridle`/`hyprlock`;
- text and image clipboard-history watchers.

The portal permission policy allows screen capture only to the exact `grim` and
Hyprland portal executables. Other clients retain Hyprland's permission prompt.
The configuration does not use deprecated NVIDIA workarounds such as
`WLR_NO_HARDWARE_CURSORS` and does not force a Wayland-only SDL backend, which
would be hostile to games that still need XWayland.

Useful default bindings:

| Binding | Action |
| --- | --- |
| `Super+Enter` | Kitty terminal |
| `Super+D` | Fuzzel launcher |
| `Super+E` | Dolphin file manager |
| `Super+C` | Close the focused window |
| `Super+F` | Toggle fullscreen |
| `Super+Shift+V` | Toggle floating |
| `Super+V` | Select clipboard history |
| `Super+N` | Toggle notification center |
| `Super+L` | Lock the session |
| `Print` | Full-screen capture to `~/Pictures/Screenshots` and clipboard |
| `Super+Print` | Region capture |
| `Super+1` through `Super+0` | Select workspace 1 through 10 |
| `Super+Shift+1` through `Super+Shift+0` | Move a window to a workspace |

Audio, microphone, media, and brightness keys are also configured. The idle
policy requests a lock after five minutes and powers displays off after ten.

## Package sources and security boundary

Most additions come from Fedora, RPM Fusion, Terra, or repositories already
configured by Bazzite. Fedora 44 does not currently publish Hyprland itself, so
the build temporarily enables the GPG-checked `lionheartp/Hyprland` COPR for
only these packages:

- `hyprland`
- `xdg-desktop-portal-hyprland`
- `hypridle`
- `hyprlock`
- `hyprpolkitagent`

The COPR is disabled immediately afterward and is not left enabled on installed
systems. This is still a third-party supply-chain dependency. The RPM versions
and Fedora repositories are mutable, so pinning the base-image digest alone does
not make builds bit-for-bit reproducible. Review COPR ownership, package diffs,
and current build status before accepting an automated rebuild.

Fedora 44 does not provide a maintained Looking Glass client RPM. The build
therefore compiles the official stable B7 source archive after checking its
pinned SHA-256 digest and installs the client under `/usr`. This is the narrow
exception to the distro-package preference. A targeted
`-Wno-error=maybe-uninitialized` compiler flag works around a GCC 16 warning in
the bundled NanoSVG code; all other upstream warnings remain errors. The
optional `kvmfr` kernel module
is intentionally excluded: its kernel ABI, SELinux device policy, memory size,
and libvirt access are host-specific. The client can use a correctly configured
IVSHMEM file without baking those risky choices into every machine.

The image retains upstream NVIDIA kernel modules, secure-boot behavior, SELinux,
TLS verification, bootc linting, and Bazzite's update model. The implementation
does not add unsigned kernel modules, weaken certificate checks, or hard-code
credentials.

## Local validation and container build

Run Linux commands from a Fedora/Bazzite host or WSL/Linux environment. Bash
syntax should not be run through PowerShell. Required fast-check tools are:

- Bash, Python 3, PyYAML, and a TOML module (`tomllib`, `tomli`, or `toml`);
- `ripgrep` and ShellCheck;
- `just` for the documented recipes.

Run the static gate first:

```bash
just validate
```

To build with Podman (the default):

```bash
just build
just inspect
```

Docker can be selected for the OCI build and inspection:

```bash
CONTAINER_ENGINE=docker just build
CONTAINER_ENGINE=docker just inspect
```

The build requires network access to GHCR, Fedora/Bazzite repositories, RPM
Fusion/Terra, and the Hyprland COPR. Plan for tens of gigabytes of container
storage. The build itself runs `bootc container lint`, RPM assertions, file
assertions, and systemd enablement checks. Lint warnings are fatal, and
package-created mutable directories are declared with systemd-tmpfiles instead
of depending on image-build side effects in `/var`. `just inspect` repeats the
essential contract in a fresh container.

Passing these commands proves source checks and an OCI build. It does not prove
registry publication, signature discovery, graphical boot, suspend/resume,
NVIDIA display behavior, gaming performance, VM boot, or physical hardware.

### Updating the pinned bases

Treat both digest changes as supply-chain updates:

1. Read the upstream Bazzite or bootc-image-builder release notes.
2. Inspect the current manifest with Skopeo or another registry client:

   ```bash
   skopeo inspect docker://ghcr.io/ublue-os/bazzite-nvidia-open:stable
   skopeo inspect docker://quay.io/centos-bootc/bootc-image-builder:latest
   ```

3. Update the digest in `Containerfile` or `bazzite-firebadnofire.env` and
   `.forgejo/workflows/build-disk.yml` together.
4. Run static validation, a complete OCI build, image inspection, and VM tests.
5. Review the complete diff before merging to `main`.

## Forgejo Actions

### Runner prerequisites

Both workflows select the existing global `ubuntu-22.04` label, currently
served by the `opensuse-server` runner. The image workflow fails early unless
the job is x86_64 and can reach a working Docker daemon and Docker Buildx.

That label launches a minimal `ubuntu:22.04` job container, not a preloaded
GitHub-hosted-runner image. Each workflow therefore installs the Jammy Docker
CLI/Buildx and performs an exact-ref shell checkout of this public repository.
The disk job also installs checksum-pinned Node.js 24 LTS because Forgejo's
artifact uploader is a Node action. This avoids assuming that `node`, `git`, or
`docker` already exists inside the job container. Docker operations still
require the runner administrator to expose a dedicated external DinD daemon.

The Alpine `forgejo-runner` container and the per-job Ubuntu container are
separate environments. Installing `docker-cli` interactively with `apk` in the
runner container does not install it in a job, does not repair job access to a
Docker daemon, and is lost when that runner container is replaced unless it is
part of its image. Likewise, seeing `/var/run/docker.sock` inside a job is not
proof of access; the preflight requires `docker info` to succeed.

Use a dedicated Docker-in-Docker daemon for Actions, or place the runner in a
dedicated VM with no unrelated workloads. Do not grant Actions access to the
Docker socket of a server that also runs production services, and never make a
Docker socket world-writable. Socket access is effectively root access to the
daemon's host. Forgejo documents the supported `runner.envs.DOCKER_HOST` and
`container.docker_host` configurations in its
[Docker access guide](https://forgejo.org/docs/latest/admin/actions/docker-access/).
The exact endpoint, network, TLS, and certificate mounts belong in the runner's
deployment configuration and depend on that deployment; they are not guessed
in this repository. Prefer a TLS-protected DinD endpoint when it crosses a
container or host trust boundary.

The runner must provide:

- an x86_64 Linux job environment;
- Docker-in-Docker or equivalent Docker-daemon access exposed to the job;
- permission for the root job container to install Jammy packages;
- outbound HTTPS and valid CA trust for all package and registry endpoints;
- enough storage for the Bazzite base, build layers, and artifacts (at least
  60 GiB free is a practical starting point; disk builds can require more);
- `apt-get` plus root or `sudo` for small validation dependencies.

The disk workflow additionally runs bootc-image-builder with `--privileged`.
The runner's Docker policy must allow privileged containers and named volumes.
It does not require host Podman and does not bind the job workspace into the
DinD daemon; configuration and outputs are transferred with `docker cp`.

The workflows deliberately do not select the macOS runner or the currently
offline FreeBSD and Windows runners.

### Required secrets

Configure these in the repository's Forgejo **Settings → Actions → Secrets**.
Do not put their values in files, workflow logs, commits, or issue text.

| Secret | Purpose | Required for |
| --- | --- | --- |
| `REGISTRY_USERNAME` | Forgejo account permitted to publish packages for `universalblue` | Publication |
| `REGISTRY_TOKEN` | Sensitive Forgejo access token with repository/package write access | Publication |
| `COSIGN_PRIVATE_KEY` | Entire contents of the local `cosign.key` | Signing |
| `COSIGN_PASSWORD` | Password used when the Cosign key was generated | Signing |

`cosign.pub` is public verification material and is intentionally committed.
`cosign.key` is intentionally ignored. This repository never reads it during
normal builds; only the Forgejo secret is exposed to the signing step.

If a replacement key is ever required, back up the current key securely first,
generate the replacement with Cosign, replace `cosign.pub`, and update both
Cosign secrets in one controlled change. Previously signed images remain tied
to the old public key, so archive that key for historical verification. Never
commit a private key.

### Image workflow triggers and outputs

`.forgejo/workflows/build.yml` behaves as follows:

- a pull request targeting `main` runs validation, builds the complete image,
  and inspects it, but never logs in, pushes, or signs;
- a push to `main` performs those checks, publishes, signs, and verifies;
- a manual dispatch builds the selected ref and publishes only when the ref is
  `main`.

Markdown-only pushes to `main` are ignored. There is no scheduled publication.

A successful production run publishes these tags:

- `stable` — mutable stream tag;
- `stable-YYYYMMDD-<12-character-commit>` — dated traceability tag;
- `sha-<12-character-commit>` — commit traceability tag.

The workflow verifies that every tag resolves to one `sha256:` manifest digest,
then signs exactly `pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:…`.
If signing or immediate public-key verification fails, the workflow fails. A
failed signing step may leave pushed but unsigned tags in the registry; do not
trust a build until its complete workflow is green and independent verification
succeeds.

Verify a published digest locally:

```bash
cosign verify \
  --key cosign.pub \
  pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:<digest>
```

Resolve the current `stable` digest before installation with Skopeo:

```bash
skopeo inspect \
  docker://pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable \
  --format '{{.Digest}}'
```

If the registry package is private, authenticate with a least-privilege token;
do not embed credentials in the image reference or shell history.

### Disk-artifact workflow

After a signed `stable` image exists, manually dispatch
`.forgejo/workflows/build-disk.yml`. Its x86_64 matrix produces:

- a QCOW2 disk under bootc-image-builder's `output/qcow2/` layout;
- an Anaconda installer ISO under `output/bootiso/install.iso`;
- `SHA256SUMS` covering every uploaded file.

Each matrix job uploads an uncompressed Forgejo artifact retained for 30 days.
The installer is configured to track this repository's `stable` image.

The Anaconda ISO type is a compatibility path in bootc-image-builder and is
being superseded upstream. A future migration should evaluate the unified
image-builder and container-based `bootc-installer` flow; this repository does
not preemptively change formats without a boot-tested replacement.

For a local artifact build, install rootful Podman and run:

```bash
just build-qcow2
just build-iso
```

These commands consume the published `stable` image by default and write to
`output/`. They require privileged containers and can materially consume disk
space. They do not modify a physical disk.

## VM smoke testing

Do not install on hardware before booting the QCOW2 in a UEFI QEMU/KVM VM.
Exact firmware paths differ by distribution. A representative Fedora/Bazzite
test uses `qemu-system-x86_64`, KVM, host CPU passthrough, 8 GiB RAM, and an OVMF
firmware pair supplied by `edk2-ovmf`.

In the VM, verify at minimum:

```bash
sudo bootc status
systemctl is-enabled libvirtd.service
rpm -q hyprland xdg-desktop-portal-hyprland qemu-kvm virt-manager
```

Then exercise the actual graphical path:

1. Select the Hyprland session in the display manager and log in.
2. Open Kitty, Dolphin, Fuzzel, Waybar, and the notification center.
3. Test audio controls, locking/unlocking, clipboard history, full and region
   screenshots, and a PipeWire screen-share portal request.
4. Launch an XWayland application and a native Wayland application.
5. Reboot, update, and roll back once before considering hardware installation.

A virtual GPU does not validate NVIDIA acceleration, VRR, HDR, multi-monitor
behavior, or gaming performance. Those remain physical-hardware tests.

## Installation and rebase

Rebasing changes the operating-system deployment. Back up important user data,
export irreplaceable application state, and have bootable recovery media before
continuing. Confirm that the public signature matches the intended digest and
review the successful Forgejo run first.

Record the current deployment and enough information to return to it:

```bash
sudo bootc status
findmnt / /boot /boot/efi
```

The mutable stream switch is:

```bash
sudo bootc switch \
  pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable
sudo bootc status
```

For the safest first deployment, use the verified immutable digest instead of
the mutable tag:

```bash
sudo bootc switch \
  pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:<verified-digest>
sudo bootc status
```

Review the staged deployment before rebooting. If `bootc status` does not show
the intended image and digest, do not reboot. After reboot, select **Hyprland**
at the login screen. The first session creates the user configuration defaults.

Registry authentication, if needed, is an operator concern and must use a
credential store or supported bootc/container-auth mechanism. Never put a token
in this repository or an image reference.

### Updates

For the mutable `stable` stream:

```bash
sudo bootc upgrade --check
sudo bootc upgrade
sudo bootc status
```

Reboot only after reviewing the staged deployment. A digest-pinned deployment
does not follow `stable`; explicitly switch to a newly verified digest when you
choose to update.

### Rollback and recovery

Before reboot, discard an unwanted staged deployment with the bootc command
appropriate to the installed bootc version, after checking `bootc --help` and
`bootc status`. After a bad boot, select the previous deployment from the boot
loader. Once running a known-good deployment:

```bash
sudo bootc status
sudo bootc rollback
sudo bootc status
```

Do not assume rollback repairs mutable state in `/etc`, `/var`, or home
directories; those areas may survive deployment changes. Use backups for data
recovery. If both deployments fail, boot trusted rescue/install media, preserve
data before repair, and use documented Bazzite/bootc recovery procedures rather
than deleting OSTree or bootloader state by hand.

## Libvirt, QEMU, and VFIO boundary

The image enables `libvirtd.service` and installs the workstation virtualization
stack. User authorization is machine-specific. After installation, check group
membership and add the intended account only if needed:

```bash
getent group libvirt
id
sudo usermod --append --groups libvirt "$USER"
```

Log out and back in before opening virt-manager. Adding users to `libvirt` is a
privileged local policy decision; do not apply it indiscriminately.

This image deliberately does **not** configure VFIO passthrough. It does not set
IOMMU kernel arguments, bind PCI IDs, isolate CPUs, reserve huge pages, alter
initramfs contents, configure Looking Glass shared memory, or detach a host GPU.
Those choices depend on the motherboard's IOMMU groups, exact PCI functions,
guest OS, and recovery plan. A wrong configuration can remove the host display
or make the machine unbootable. Inspect hardware and design a rollback path on
the target workstation before making those separate changes.

## Validation status and known risks

Use this vocabulary when reporting results:

- **static**: repository syntax and consistency checks ran;
- **built**: the OCI image completed, including `bootc container lint`;
- **inspected**: required packages, files, and service enablement were checked
  inside the built image;
- **published**: the registry accepted the tags and they resolve to one digest;
- **signature-verified**: Cosign verified that exact registry digest;
- **booted**: a QCOW2 or installer result completed a VM boot;
- **hardware-tested**: the physical NVIDIA workstation completed the test plan.

Never use a lower-fidelity result as evidence of a higher one.

Important remaining risks until independently validated:

- third-party Hyprland COPR trust and availability;
- compatibility between the current Fedora/Bazzite snapshot and current COPR
  RPM set;
- real Plasma Login Manager login and Hyprland session startup;
- NVIDIA suspend/resume, display, VRR/HDR, and multi-monitor behavior;
- Steam, Gamescope, screen sharing, and XWayland behavior under Hyprland;
- Forgejo runner disk capacity, DinD privilege, registry permissions, and
  package visibility;
- bootc-image-builder QCOW2/ISO output and installer boot;
- host-specific libvirt/VFIO and Looking Glass integration.

## Scope

This repository owns the shallow system-image delta and its operator workflow.
It does not manage personal dotfiles, application source builds, development
database services, secrets, guest definitions, or host-specific VFIO settings.
Prefer toolbox/Distrobox/Podman for project-specific toolchains and services so
the immutable host remains maintainable.
