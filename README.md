# bazzite-firebadnofire

`bazzite-firebadnofire` is a personal x86_64 Universal Blue/bootc workstation
image. It layers a complete Hyprland session, administration and development
tools, and a libvirt/QEMU foundation over Bazzite's NVIDIA-open image while
retaining Bazzite's gaming and Steam/Gamescope integration.

The published image identity is:

```text
pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable
```

The synchronized transport mirror is
`ghcr.io/firebadnofire/bazzite-firebadnofire:stable`. The canonical `pubcode`
name remains the image and update identity. A repository-scoped
`containers-registries.conf` entry tries GHCR first and falls back to the
canonical Pubcode endpoint for pulls of that identity; TLS certificate
validation remains enabled for both. Because containers/image tries entries
named `mirror` before `location`, GHCR occupies the mirror slot and Pubcode the
source-location slot without changing the logical image reference shown by
bootc.

This is a personal image, not an official Bazzite or Universal Blue edition.
Read the [risk and validation status](#validation-status-and-known-risks) before
installing it on a workstation.

## Implemented product contract

| Area | Current implementation |
| --- | --- |
| Architecture | x86_64 only |
| Base | Digest-pinned `ghcr.io/ublue-os/bazzite-nvidia-open:stable` |
| OS display name | `firebadnofire-bazzite` in `NAME` and `PRETTY_NAME`; compatibility remains `ID=bazzite` and `ID_LIKE=fedora` |
| GPU target | NVIDIA Turing and newer, including GeForce RTX; other hardware inherits the upstream Bazzite behavior |
| Desktop | Hyprland 0.56-compatible Lua configuration with XWayland, adapted from the operator's workstation setup |
| Gaming | Inherited Bazzite Steam, Gamescope, codecs, controller support, and gaming tools |
| Audio/video | Inherited PipeWire/WirePlumber plus pavucontrol and playerctl |
| Desktop plumbing | Waybar, Fuzzel, SwayNotificationCenter, NetworkManager and Bluetooth applets, portals, polkit agent, clipboard history, screenshots, idle locking |
| Administration | SSH and inherited networking/storage tools plus mosh, nmap, Wireshark CLI, iperf3, strace, ripgrep, fd, sysstat, hardware inspection, and serial-console utilities |
| Development | Podman/toolbox support from Bazzite plus GitHub CLI, Git LFS, GCC/C++, CMake, Meson, Ninja, pkg-config, and Python pip |
| Virtualization | QEMU/KVM, libvirt, virt-manager, virt-install, virt-viewer, swtpm, SPICE, libguestfs, the Looking Glass B7 client, and exclusive `*-gpu` NVIDIA handoff |
| CI | Forgejo Actions on the global `ubuntu-22.04` runner label |
| Publication | Canonical Forgejo image on `pubcode.archuser.org` with a required GHCR mirror at `ghcr.io/firebadnofire/bazzite-firebadnofire` |
| Signing | Separate key-based Cosign signatures over each registry-qualified OCI digest; detached OpenPGP signatures for downloadable disk artifacts |

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
- `include.txt` lists additional RPM packages to bake into every image build.
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
the immutable Hyprland, Hypridle, Hyprlock, Hyprpaper, and Waybar defaults into
`~/.config/` only when the corresponding user file does not already exist.
Image updates never replace edited user configuration. Exact, unmodified
Hyprland defaults from earlier image revisions are upgraded to the current Lua
default so corrected bindings reach existing installations. A user-authored
legacy `hyprland.conf` is preserved and passed explicitly to Hyprland.
After provisioning those defaults, the image wrapper hands the session to
Hyprland's supported `/usr/bin/start-hyprland` launcher and supervises that
process through logout or an abnormal exit. Legacy configuration arguments are
passed after its required `--` separator. The image also installs
`hyprland-guiutils`, which supplies Hyprland's runtime dialogs and emergency
launcher.
`just inspect` and Forgejo's **Inspect image contract** step validate the
shipped `/usr/share/bazzite-firebadnofire/hyprland.lua` with Hyprland's
`--verify-config` mode.

The wrapper owns one systemd session lifecycle. After Hyprland publishes a
fresh `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP=Hyprland`, and
`HYPRLAND_INSTANCE_SIGNATURE` to the user manager, the wrapper synchronizes the
same environment to D-Bus activation and starts the image-provided
`hyprland-session.target`. That target binds to Fedora's unmodified
`graphical-session.target`, allowing portal services with a graphical-session
requisite to start without a race. On clean logout, a compositor crash, or
termination by the display manager, the wrapper stops `hyprland-session.target`.
Fedora's existing `StopWhenUnneeded=yes` behavior then deactivates
`graphical-session.target` only if another session target does not still need
it. Hyprland's optional native target handling is disabled for this wrapper so
the two lifecycle mechanisms cannot compete.

The image explicitly installs the portal frontend, the Hyprland backend, and
the GTK backend. `/usr/share/xdg-desktop-portal/hyprland-portals.conf` selects
Hyprland first for the interfaces it implements and GTK as the fallback, with
GTK selected explicitly for `FileChooser`. Portal services remain D-Bus
activated; the launcher does not restart already working portal processes.
Dolphin remains installed and provides the file-manager integration used by
applications that reveal a downloaded file.

For an account without `~/.config/user-dirs.dirs`, first Hyprland startup runs
`xdg-user-dirs-update`, whose Fedora default creates `~/Downloads` and records
it as `XDG_DOWNLOAD_DIR`. If that configuration file already exists, the
launcher never invokes the updater, so custom user-directory paths are not
rewritten.

Older installations that used the temporary per-user target should move it out
of systemd's search path after installing the corrected image, then reload the
user manager and log out and back in:

```bash
mv ~/.config/systemd/user/hyprland-session.target \
  ~/.config/systemd/user/hyprland-session.target.manual-backup
systemctl --user daemon-reload
```

The backup is intentionally retained until the next Hyprland login has been
tested. Fresh accounts need no per-user unit.

The default session starts:

- Waybar and SwayNotificationCenter;
- Hyprpaper;
- `nm-applet` and `blueman-applet`;
- `hyprpolkitagent` through its user service;
- `hypridle`/`hyprlock`;
- text and image clipboard-history watchers.

The portal permission policy allows screen capture only to the exact `grim` and
Hyprland portal executables. Other clients retain Hyprland's permission prompt.
The configuration does not use deprecated NVIDIA workarounds such as
`WLR_NO_HARDWARE_CURSORS` and does not force a Wayland-only SDL backend, which
would be hostile to games that still need XWayland.

The shipped Waybar layout exposes workspaces and the active window on the left
and center, with clipboard, audio, network, power, CPU, memory, temperature,
backlight, language, battery, clock, and tray modules on the right. Hardware-
specific modules disappear normally when the relevant device or service is not
available.

Useful default bindings, adapted from the operator's workstation setup:

| Binding | Action |
| --- | --- |
| `Super+Q` | Foot terminal |
| `Super+R` | Fuzzel application launcher |
| `Super+E` | Dolphin file manager |
| `Super+C` | Close the focused window |
| `Super+Z` | Toggle fullscreen |
| `Super+V` | Toggle floating |
| `Super+I` | Select a random wallpaper from `~/.config/wallpapers` |
| `Super+N` | Toggle notification center |
| `Super+L` | Lock the session |
| `Alt+H` | Steam |
| `Alt+G` | Vesktop Flatpak, when installed |
| `Alt+D` | Firefox |
| `Print` | Full-screen capture to `~/Pictures/Screenshots` and clipboard |
| `Super+Print` | Region capture |
| `Super+1` through `Super+0` | Select workspace 1 through 10 |
| `Super+Shift+1` through `Super+Shift+0` | Move a window to a workspace |

Audio, microphone, media, and brightness keys are also configured. The idle
policy requests a lock after five minutes and powers displays off after ten.
Wallpaper images are deliberately not embedded in the public image because the
reference files do not have repository-ready provenance or licensing. If
`~/.config/wallpapers` has no JPG, PNG, or WebP images, `Super+I` reports that
condition without disrupting the session.

## Package sources and security boundary

### Additional base-image packages

Add one RPM package name per line to the repository-root `include.txt` to bake
it into future `bazzite-firebadnofire` OCI images. Blank lines and lines whose
first non-whitespace character is `#` are ignored; surrounding whitespace is
also ignored. An empty file is valid. Package names are resolved and installed
with `dnf5` during the normal image build, and the finished image is checked
with `rpm -q` against the same manifest. An invalid, unavailable, or failed
package installation fails the build rather than being skipped.

`include.txt` is copied into the image at
`/usr/share/bazzite-firebadnofire/include.txt` so post-build inspection can
verify the installed package set without duplicating the list elsewhere.

Most additions come from Fedora, RPM Fusion, Terra, or repositories already
configured by Bazzite. Fedora 44 does not currently publish Hyprland itself, so
the build temporarily enables the GPG-checked `lionheartp/Hyprland` COPR for
only these packages:

- `hyprland`
- `hyprland-guiutils`
- `xdg-desktop-portal-hyprland`
- `hypridle`
- `hyprlock`
- `hyprpaper`
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

Treat every base-image digest change as a supply-chain update:

1. Read the upstream Bazzite or bootc-image-builder release notes.
2. Inspect the current manifest with Skopeo or another registry client:

   ```bash
   skopeo inspect docker://ghcr.io/ublue-os/bazzite-nvidia-open:stable
   skopeo inspect docker://quay.io/centos-bootc/bootc-image-builder:latest
   skopeo inspect --raw docker://quay.io/fedora/fedora-bootc:44 | sha256sum
   ```

3. Update the Bazzite digest in `Containerfile`, the Image Builder digest in
   `bazzite-firebadnofire.env` and `.forgejo/workflows/build-disk.yml` together,
   or the Fedora bootc digest in `network-installer/Containerfile`, according to
   the input being updated.
4. Run static validation and the complete affected build. For the workstation
   image, also run image inspection and VM tests; for the network installer,
   force-pull and build its container before dispatching the ISO workflow.
5. Review the complete diff before merging to `main`.

## Forgejo Actions

### Runner prerequisites

All Forgejo workflows select the existing global `ubuntu-22.04` label, currently
served by the `opensuse-server` runner. The image workflow fails early unless
the job is x86_64 and can reach a working Docker daemon and Docker Buildx.

That label launches a minimal `ubuntu:22.04` job container, not a preloaded
GitHub-hosted-runner image. Each workflow therefore installs the Jammy Docker
CLI/Buildx and performs an exact-ref shell checkout of this public repository.
The disk workflow bootstrap also includes checksum-pinned Node.js 24 LTS.
This avoids assuming that `node`, `git`, or
`docker` already exists inside the job container. Docker operations still
require the runner administrator to expose a dedicated external DinD daemon.

The Alpine `forgejo-runner` container and the per-job Ubuntu container are
separate environments. Installing `docker-cli` interactively with `apk` in the
runner container does not install it in a job, does not repair job access to a
Docker daemon, and is lost when that runner container is replaced unless it is
part of its image. Likewise, seeing `/var/run/docker.sock` inside a job is not
proof of access; the preflight requires `docker info` to succeed.

The deployed `opensuse-server` runner uses one isolated, TLS-enabled DinD
daemon. Its external deployment lives on the runner host at
`/home/william/docker/forgejo-runner`; it is intentionally not copied into this
repository. The four runtime layers are:

1. the host Docker daemon starts the runner and DinD containers;
2. the non-privileged `forgejo-runner` container connects to DinD at
   `tcp://docker:2376` with the generated client certificate;
3. DinD creates the per-job Ubuntu container with host networking relative to
   the DinD container, so the job connects to the same daemon at
   `tcp://127.0.0.1:2376`;
4. Docker commands in the job create the image-build and privileged
   bootc-image-builder containers in that same isolated daemon.

The runner does not mount `/var/run/docker.sock` and is not privileged. Only
the dedicated DinD service is privileged; its port is not published to the
host. This prevents workflows from directly controlling the host daemon and
its unrelated workloads. It does not turn a privileged container into a hard
security boundary: keep the runner host patched and prefer a dedicated runner
VM if untrusted contributors can execute workflows. Never make a Docker socket
world-writable. Forgejo's [Docker access guide](https://forgejo.org/docs/latest/admin/actions/docker-access/)
and [Actions security guidance](https://forgejo.org/docs/latest/admin/actions/security/)
describe the underlying trust model.

The runner host Compose file pins
`docker:29.5.2-dind@sha256:6b9cd914eb9c6b342c040a49a27a5eb3804453bae6ecc90f7ff96133595a95e8`
and includes these essential settings:

```yaml
services:
  docker-in-docker:
    image: docker.io/library/docker:29.5.2-dind@sha256:6b9cd914eb9c6b342c040a49a27a5eb3804453bae6ecc90f7ff96133595a95e8
    hostname: docker
    privileged: true
    environment:
      DOCKER_TLS_CERTDIR: /certs
    volumes:
      - docker-certs:/certs:z
      - docker-data:/var/lib/docker
    networks: [runner-dind]

  runner:
    environment:
      DOCKER_HOST: tcp://docker:2376
      DOCKER_TLS_VERIFY: "1"
      DOCKER_CERT_PATH: /certs/client
    volumes:
      - docker-certs:/certs:ro,z
    networks: [ci-network, runner-dind]

volumes:
  docker-certs:
  docker-data:

networks:
  ci-network:
    external: true
  runner-dind:
    driver: bridge
```

The `:z` labels are required on the SELinux-enabled runner host so both
containers can read the certificate volume. Do not replace them with broad
filesystem permissions. Keep the client private key inside the Docker-managed
volume and do not log, copy, or commit it.

`data/runner-config.yml` passes the TLS endpoint into each job without asking
Forgejo Runner to mount a host socket:

```yaml
runner:
  envs:
    DOCKER_HOST: tcp://127.0.0.1:2376
    DOCKER_TLS_VERIFY: "1"
    DOCKER_CERT_PATH: /certs/client

container:
  network: "host"
  privileged: false
  options: "--volume /certs/client:/certs/client:ro"
  valid_volumes:
    - /certs/client
  docker_host: "-"
```

Before changing that external deployment, back up both files. Validate the
rendered configuration before restarting:

```bash
cd /home/william/docker/forgejo-runner
stamp=$(date -u +%Y%m%dT%H%M%SZ)
cp -a docker-compose.yml "docker-compose.yml.bak.${stamp}"
cp -a data/runner-config.yml "data/runner-config.yml.bak.${stamp}"
docker compose config --quiet
docker compose up -d
docker compose ps
docker logs --tail 100 forgejo-runner
```

If startup fails, restore both files from the same timestamp and run
`docker compose up -d` again. Do not restore only one file because the endpoint
and job propagation settings form one contract.

The runner must provide:

- an x86_64 Linux job environment;
- Docker-in-Docker or equivalent Docker-daemon access exposed to the job;
- permission for the root job container to install Jammy packages;
- outbound HTTPS and valid CA trust for all package and registry endpoints;
- enough storage for the Bazzite base, build layers, and artifacts (at least
  60 GiB free is a practical starting point; disk builds can require more);
- `apt-get` plus root or `sudo` for small validation dependencies.

The image workflow enforces that 60 GiB free-space floor on the filesystem
backing the job and DinD before it starts the build, then requires at least 40
GiB to remain immediately before publication. These are intentionally
fail-closed guards: on the deployed runner the Forgejo registry, Actions logs,
and DinD ultimately share the host filesystem, so exhausting it during a
large, many-layer push can prevent Forgejo from recording the push error
itself. The preflight records filesystem capacity and inodes, memory and cgroup
events, and Docker-daemon identity. If it fails, remove only identified stale
runner artifacts or expand storage; do not broad-prune the persistent
bootc-image-builder cache.

The disk workflow additionally runs bootc-image-builder with `--privileged`.
The runner's Docker policy must allow privileged containers and named volumes.
It does not require host Podman and does not bind the job workspace into the
DinD daemon; configuration and outputs are transferred with `docker cp`.

Every job preflight runs `docker --version`, `docker info`, and
`docker buildx version`, then starts the digest-pinned `hello-world` image. The
disk preflight additionally starts the pinned bootc-image-builder image with
`--privileged` and prints its version. If the client exists but `docker info`
fails, check all three propagation points: the runner's `tcp://docker:2376`
endpoint, the job's `tcp://127.0.0.1:2376` endpoint, and read access to
`/certs/client`. On an SELinux host, `permission denied` for `ca.pem` normally
means the shared `:z` volume label is missing. Installing `docker-cli` inside
the runner container or changing socket permissions does not repair this path.

The workflows deliberately do not select the macOS runner or the currently
offline FreeBSD and Windows runners.

### Required secrets

Configure these in the repository's Forgejo **Settings → Actions → Secrets**.
Do not put their values in files, workflow logs, commits, or issue text.

| Secret | Purpose | Required for |
| --- | --- | --- |
| `REGISTRY_TOKEN` | Sensitive Forgejo PAT with `write:package` scope, owned by `firebadnofire` and permitted to publish packages for `universalblue` | Main-branch push, daily schedule, or manual image publication |
| `GH_KEY` | Sensitive GitHub classic PAT owned by `firebadnofire` with `write:packages` and `public_repo` scopes | Required GHCR mirror for every non-PR image publication and GitHub release mirror for every manual network ISO release |
| `COSIGN_PRIVATE_KEY` | Sensitive contents of the private `cosign.key` | OCI signing in production image runs |
| `COSIGN_PASSWORD` | Sensitive password for `COSIGN_PRIVATE_KEY` | OCI signing in production image runs |
| `GPG_KEY_B64` | Sensitive base64 encoding of the private OpenPGP key whose primary fingerprint is `7D6EF134D851C8DA0862D97494F31AF374E2EE3C` | Manual disk, offline ISO, and network ISO release signing |
| `GPG_KEY_PASSWORD` | Sensitive passphrase for the OpenPGP private key | Manual disk, offline ISO, and network ISO release signing |

The deployed Forgejo instance reports version 14.0.5. Forgejo
[automatically creates a unique workflow token](https://forgejo.org/docs/v14.0/user/actions/basic-concepts/#automatic-token)
and removes it when the workflow finishes. The disk release job uses that token
only for the repository-local Forgejo release and tag API. Registry publication
continues to use the manually verified PAT path: the fixed non-secret username
is `firebadnofire`, and the token is `REGISTRY_TOKEN`. Do not replace it with
the automatic token unless organization package publication is separately
proved on the deployed Forgejo version. `REGISTRY_USERNAME`, `IMAGE_REGISTRY`,
and `IMAGE_PATH` are configuration values, not secrets.

If any artifact workflow completes `prepare` but leaves its dependent build job
at **Blocked**, with zero duration and no steps, manually dispatch **Actions →
Diagnose Forgejo dependent-job dispatch → Run workflow**. This diagnostic needs
no secrets and deliberately contains no image, Docker, cache, disk, or release
commands. It first proves a plain `simple_a` → `simple_b` dependency, then writes
a job output through `$GITHUB_OUTPUT` and consumes it through
`${{ needs.output_a.outputs.marker }}`. All four jobs use the same
`ubuntu-22.04` runner label as the artifact workflows.

Interpret the first job that does not start:

- `simple_b` blocked after `simple_a` succeeds means Forgejo did not perform its
  server-side dependent-job transition; job outputs and artifact commands are
  not involved.
- `output_a` blocked after `simple_b` succeeds is the same scheduling failure on
  a second plain dependency transition.
- `output_b` blocked or failed after `output_a` succeeds isolates job-output
  scheduling or propagation.
- all four jobs succeeding means the scheduler and job-output path worked for
  that run; compare Forgejo server queue errors and runner availability at the
  timestamps of the failed artifact run.

Do not compensate for a blocked diagnostic by weakening image validation or
rewriting artifact build commands. Preserve the run ID and inspect the Forgejo
server log for `actions_ready_job` or `checkJobsOfRun` errors. A runner log can
show task-fetch failures, but the server owns the transition from `blocked` to
`waiting` after a successful dependency.

The September 21, 2026 incident was traced to the public Forgejo server's
LevelDB queue: `Emit ready jobs of run ...: write
/data/gitea/queues/common/004805.log: no space left on device`. This affected
the plain dependency diagnostic as well as artifact workflows. The queue kept
returning the write error even after the `/data` filesystem had about 19 GiB
free. Restarting the public `forgejo` container reopened the journal and
restored queue writes. This was a server queue failure, not a `needs` syntax
or job-output compatibility problem.

For this specific error, inspect free bytes and inodes **inside the public
Forgejo container** first. Restore capacity if necessary, then perform a
controlled restart of that service and check its queue log and new server
errors. Do not delete the queue database. A successful predecessor whose
completion event could not be queued may leave an old run blocked; cancel
that stale run and dispatch the dependency diagnostic afresh before retrying
the artifact build. A restart alone does not prove the new workflow succeeds.
The public service is on `mainsrv.archuser.org`, reachable by SSH from
`192.168.86.54`; the `forgejo` container on `.54` serves a different site.

Create the PAT from the publishing account's Forgejo user settings with only
`write:package`, then add its value at **Settings → Actions → Secrets** as
`REGISTRY_TOKEN`. The token owner must be an organization owner or belong to a
team allowed to publish packages for `universalblue`. A successful Docker login
only proves token authentication; the workflow reports a separate actionable
error if the subsequent push lacks organization package permission.

Use the existing `GH_KEY` GitHub personal access token (classic), with
`write:packages` for GHCR and `public_repo` for releases in the public GitHub
mirror repository. Store it in the same Forgejo Actions secret settings.
GitHub Packages does not accept a fine-grained PAT for external GHCR
publication. For a new token, use GitHub's
[`write:packages` and `public_repo` token URL](https://github.com/settings/tokens/new?scopes=write:packages,public_repo)
instead of granting private-repository access through the broader `repo` scope.
Sharing the token gives it public-repository write access beyond its previous
package-only role; keep it exposed only to the respective mirror steps.
The token value must never appear in a workflow file or log.

No separate `GITHUB_RELEASE_TOKEN` secret is needed: the network ISO workflow
maps `GH_KEY` into the release helper's `GITHUB_RELEASE_TOKEN` environment
variable. If the existing token has only package permissions, the operator must
add `public_repo` before release mirroring can succeed. The GitHub repository must
already contain the triggering commit; the network release mirror verifies the
exact 40-character source revision and fails closed if source mirroring has not
completed.

The first command-line push creates a private personal GHCR package. After the
first production attempt has pushed it, open the package settings under the
`firebadnofire` GitHub account, link it to
`firebadnofire/bazzite-firebadnofire`, and change its visibility to **Public**.
Changing a GHCR package to public is irreversible. Rerun the Forgejo workflow
after that one-time operation. The workflow checks the digest with an isolated,
credential-free Docker configuration and remains failed until anonymous access
works; an authenticated inspection is not accepted as proof of public access.

`cosign.pub` is public verification material and is intentionally committed.
`cosign.key` is intentionally ignored. This repository never reads it during
normal builds; only the Forgejo secret is exposed to the signing step.

`GPG_KEY_B64` must be the base64 encoding of the private OpenPGP key material,
not raw armored key text. Generate the encoded value in a trusted local
environment without printing it to a shared terminal or log, then paste it
directly into the Forgejo secret form. The disk workflow decodes it into a
mode-`0600` file inside a mode-`0700` temporary `GNUPGHOME`, verifies the exact
primary fingerprint, signs through loopback pinentry without putting the
passphrase on a command line, verifies every signature, and removes the
temporary GnuPG home through an exit trap.

If a replacement key is ever required, back up the current key securely first,
generate the replacement with Cosign, replace `cosign.pub`, and update both
Cosign secrets in one controlled change. Previously signed images remain tied
to the old public key, so archive that key for historical verification. Never
commit a private key.

### Image workflow triggers and outputs

`.forgejo/workflows/build.yml` behaves as follows:

- a pull request targeting `main` runs validation, builds the complete image,
  and inspects it, but never logs in, pushes, or signs;
- every push to `main`, including documentation-only commits, performs those
  checks, publishes, signs, and verifies;
- a schedule runs every day at **04:17 UTC** from the current default-branch
  revision and follows the same production path as a push to `main`;
- a manual dispatch builds the selected ref and follows the same production
  publication path.

Start a manual build from **Actions → Validate, build, publish, and sign → Run
workflow**, selecting the ref to publish. Before a push, schedule, or manual
production run, configure `REGISTRY_TOKEN`,
`GH_KEY`, `COSIGN_PRIVATE_KEY`, and `COSIGN_PASSWORD`. For a non-publishing build
verification, open or update a pull request targeting `main`; pull-request runs
build and inspect the image but do not receive or use publication secrets.

A successful production run publishes these tags to both
`pubcode.archuser.org/universalblue/bazzite-firebadnofire` and
`ghcr.io/firebadnofire/bazzite-firebadnofire`:

- `stable` — mutable stream tag;
- `sha-<12-character-commit>` — commit traceability tag; a scheduled rebuild of
  the same commit may update it because external RPM repositories are mutable;
- `stable-YYYYMMDD-<12-character-commit>-<12-character-digest>` — immutable,
  content-qualified build tag.

The workflow first pushes the commit tag, reads the registry-reported digest
from Buildx's manifest descriptor, and signs exactly
`pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:…`. Only after
Cosign verification succeeds does it push the immutable and `stable` tags. It
then requires all three tags to resolve to the signed digest and verifies the
signature again. Publishing, digest resolution, signing, verification, and tag
consistency all fail closed. Do not trust a build until its complete workflow is
green and independent verification succeeds.

Each Forgejo push and registry digest lookup is attempted at most twice through
the repository's common retry helper. A failed attempt reports the Docker exit
status and snapshots daemon reachability, disk blocks and inodes, host/cgroup
memory pressure, registry DNS, and the unauthenticated `/v2/` response before
retrying. A second failure still fails the run. Image workflow runs for the
same ref queue rather than cancelling an in-flight canonical publication.

The build deliberately retains `docker buildx build --load`: the exact built
image must be run locally for the image-contract inspection, and that same
inspected image is subsequently tagged for Forgejo and GHCR. To keep the
persistent DinD daemon from retaining every workflow revision, the local tag is
unique to the run and an `always()` cleanup removes only tags that still point
to that run's image. It does not prune shared BuildKit or disk-image caches and
does not remove remote registry tags.

Forgejo remains the canonical publication. After its three tags and signature
are verified, the workflow pushes the traceability tag to GHCR and requires the
GHCR registry-reported digest to equal the canonical Forgejo digest. It signs
and verifies the GHCR-qualified digest separately before pushing the immutable
and `stable` tags, then requires all three GHCR tags to resolve to that digest.
An already-valid GHCR signature is reused on a rerun instead of creating a
duplicate. The complete GHCR operation is attempted at most twice. If both
attempts fail, the run fails with the already-published Forgejo image left
intact; cross-registry publication cannot be atomic, and a rerun safely
reconciles GHCR.

Verify a published digest locally:

```bash
cosign verify \
  --key cosign.pub \
  pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:<digest>

cosign verify \
  --key cosign.pub \
  ghcr.io/firebadnofire/bazzite-firebadnofire@sha256:<digest>
```

Resolve the current `stable` digest before installation with Skopeo:

```bash
skopeo inspect \
  docker://pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable \
  --format '{{.Digest}}'

skopeo inspect \
  docker://ghcr.io/firebadnofire/bazzite-firebadnofire:stable \
  --format '{{.Digest}}'
```

If the registry package is private, authenticate with a least-privilege token;
do not embed credentials in the image reference or shell history.

### Disk-artifact workflow

After a signed `stable` image exists, manually dispatch
**Actions → Build and release disk artifacts → Run workflow** on the revision
to associate with the release. Configure `GPG_KEY_B64` and `GPG_KEY_PASSWORD`
first. The workflow resolves `stable` once, validates its canonical registry
digest, and passes that digest-pinned image reference to both privileged x86_64
build jobs. The matrix produces:

- `bazzite-firebadnofire-<12-character-commit>-<12-character-digest>.qcow2`;
- `bazzite-firebadnofire-<12-character-commit>-<12-character-digest>.iso`;
- `SHA256SUMS` covering those two files;
- one matching `.asc` detached OpenPGP signature for each of the three files.

The matrix outputs are staged in separate Docker named volumes on the
dedicated DinD daemon, not uploaded to Actions artifact storage. Volume names
are scoped to repository, run ID, attempt, and format; labels bind them to the
full revision and OCI digest. The prepare job records the daemon ID, which all
producers and the release consumer must match. A different daemon fails closed.
The current single `opensuse-server` runner needs no configuration change. If
more runners gain the `ubuntu-22.04` label, assign all jobs in this workflow a
dedicated label backed by the same daemon before using this handoff.

Only after **both** matrix builds succeed, an unprivileged final job copies the
volumes through stopped, read-only-mounted helper containers, verifies each
handoff SHA256, creates and verifies the final `SHA256SUMS`, imports the signing key into
an isolated temporary GnuPG home, creates and verifies all three signatures,
checks that the release directory contains exactly the expected six files, and
publishes them with the official Forgejo release action pinned by commit.
That action creates a draft, uploads all six assets, and only then publishes
it. Private keys and release credentials never enter handoff volumes or helper
containers. Docker-daemon access remains a privileged trust boundary; volume
labels/checksums prevent accidental mixing, not attacks by another daemon admin.

Cleanup runs on success or failure and removes only this attempt's validated
handoff volumes. A runner crash, cancellation, failed checkout, or changed
daemon can prevent cleanup; these are ephemeral staging volumes, not a
seven-day artifact archive. Plan for both payloads plus local copy overhead on
the DinD/job filesystems. The only large network upload is the final Release
upload, whose proxy limits still need to accommodate the complete file.
See [artifact finalization troubleshooting and handoff tests](docs/disk-artifact-handoff.md)
for server logs, cleanup guidance, and verification commands.

For a release containing only the Anaconda installer ISO, manually dispatch
**Actions → Build and release installer ISO → Run workflow**. The separate
`.forgejo/workflows/build-iso.yml` workflow has no matrix and never builds a
QCOW2. It preserves the same exact-digest resolution, x86_64/DinD checks,
rootful Podman cache, `disk_config/iso.toml`, Btrfs root, failure diagnostics,
daemon-local checksum handoff, and pinned Forgejo release action.

The ISO-only release tag is
`iso-<12-character-commit>-<12-character-source-digest>`, so it cannot collide
with the combined workflow's `disk-...` namespace. Its release directory is
required to contain exactly four nonempty files:

- `bazzite-firebadnofire-<release-id>.iso`;
- `bazzite-firebadnofire-<release-id>.iso.sig`;
- `SHA256SUMS`, covering only the ISO payload;
- `SHA256SUMS.sig`.

The `.sig` files are binary detached OpenPGP signatures. The signing helper
imports the base64-decoded private key into a temporary isolated GnuPG home,
requires the documented full primary fingerprint, signs both payload files,
and cryptographically verifies both signatures before continuing. A second
gate checks the exact four-file set and verifies that every nonsignature asset
has one corresponding nonempty `.sig` file and every `.sig` has a payload. The
release action cannot run if either gate fails. Immediately before that action,
the workflow logs each upload asset's exact byte count and human-readable size,
followed by the aggregate upload size. Release notes are passed separately and
are not downloadable assets. The existing combined disk workflow continues to
request ASCII-armored `.asc` signatures.

For the smallest network-dependent installer, manually dispatch
**Actions → Build and release network installer ISO → Run workflow**. The
`.forgejo/workflows/build-net.yml` workflow builds a purpose-specific Fedora
44 bootc/Anaconda environment from `network-installer/Containerfile` with the
current unified Image Builder `bootc-generic-iso` path. It does **not** pass a
workstation payload to Image Builder and does not embed the
`bazzite-firebadnofire` OCI image. The build extracts and inspects the finished
ISO and its installer squashfs, fails if it finds a top-level payload or any
regular container-storage payload files, and verifies the exact network
Kickstart and mirror configuration before release.

The installer is text-mode and interactive so booting the media does not
silently select or erase a disk. It activates DHCP, then Anaconda resolves and
pulls the then-current
`pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable` logical stream
only after boot. The repository-scoped containers/image configuration pulls
from synchronized
`ghcr.io/firebadnofire/bazzite-firebadnofire:stable` first and falls back to
Pubcode.
Installation therefore requires working network link, DHCP, DNS, trusted CA
time/state, and outbound HTTPS to at least one endpoint. There is no offline
fallback in this ISO.

During the OCI pull, the text installer displays a continuously moving
`Downloading operating system image` bar and continues to surface bootc phase
and error messages. The bar is intentionally indeterminate: the current
Anaconda/bootc task interface does not provide a trustworthy total byte count,
so displaying a fabricated percentage would be misleading. The network ISO
build patches this narrow UI boundary with exact checks and fails if a future
Anaconda update no longer matches the validated integration point.

To avoid duplicating hundreds of MiB in the live filesystem, the installer is
English-only and carries boot-time firmware in its no-hostonly initramfs rather
than again in the squashfs. It retains the matching kernel module tree for
installer services that request modules after the live-root transition, and it
includes `tmux` explicitly because weak dependencies are disabled while the
interactive Anaconda text service requires it. Plymouth is disabled on the
installer kernel command line so it cannot hold the deliberately text-only UI.
The boot command explicitly selects `anaconda.target`. Its text UI is attached
to both the VGA console (`tty1`) and the first serial port (`ttyS0`), with
kernel messages on both and a recovery shell already running on `tty2`
(`Ctrl+Alt+F2`; return with `Ctrl+Alt+F1`). The serial port shares the same
Anaconda tmux session; it does not start a second installer. A serial login
getty is masked to prevent it competing for that terminal.

For libvirt, configure a serial device with a PTY backend and a console with
target type `serial`, port `0`, then attach with
`virsh -c qemu:///system console VM_NAME` (exit with `Ctrl+]`). A host PTY alone
does not activate a guest console. The ISO configures 115200 baud, 8N1; a
virtio console (`hvc0`) is a different device. Inside the installer tmux
session, `Alt+Tab` cycles through the installer, shell, and log windows.
If the UI still fails, use the recovery shell to inspect
`systemctl --failed`, `journalctl -b -u anaconda.service -u anaconda-tmux@tty1.service -u anaconda-tmux@ttyS0.service`,
and `/tmp/anaconda.log`. Rebuild the network ISO to include these changes;
previously downloaded ISOs are unaffected. Static validation does not prove
boot success; verify both VGA and serial interaction on the rebuilt media.

The live installer loads SELinux policy in permissive mode, matching Anaconda's
documented installer-runtime behavior. This does not disable SELinux in the
downloaded and installed workstation image, whose own policy remains enforcing.
The live environment also omits its own OSTree deployment repository: it is
not an updatable installed system, and the retained bootc client initializes
the destination from the separately downloaded workstation image.

The prepare job resolves the GHCR `stable` endpoint first and records its digest
as release provenance. When GHCR is available it audits Pubcode; when GHCR is
unavailable it warns and falls back to Pubcode. If both endpoints are reachable
but resolve to different digests, the build fails closed. This is a snapshot,
not a pin for installation: a later boot
intentionally resolves `stable` again to satisfy the latest-image contract.
Consequently the signed ISO authenticates the installer bits but does not freeze
the OS payload selected later. Verify the current OCI digest and its Cosign
signature before installing when a fixed, auditable payload is required.

The workflow reports the finished ISO byte count for operator visibility but
does not enforce, warn about, or classify the result against an arbitrary size
threshold. Artifact integrity and release-backend capacity checks remain
enforced independently. The release namespace is
`netiso-<12-character-commit>-<12-character-build-time-digest>` and contains
exactly four files:

- `bazzite-firebadnofire-<UTC-date>-<release-id>.net.iso`;
- the matching `.net.iso.sig`;
- `SHA256SUMS`;
- `SHA256SUMS.sig`.

After Forgejo publication succeeds, the workflow creates or reconciles the
same tag and exact four-file release at
`github.com/firebadnofire/bazzite-firebadnofire`. GitHub reconciliation keeps
the release in draft state while replacing its asset set, rejects any file at
or above GitHub's 2 GiB per-file ceiling, and requires GitHub's reported size
and SHA-256 digest for every upload to match the local signed asset before the
release becomes public. A GitHub failure fails the workflow; Forgejo remains
the canonical release location.

The network workflow needs the same privileged isolated DinD access as other
disk builders, plus enough temporary storage for the installer container,
Podman graphroot, ISO, and squashfs inspection. It does not need registry or
Cosign private keys. Only the final unprivileged release job receives the GPG
secrets and narrowly scoped GitHub release token. Its Fedora bootc base and
Image Builder execution image are both digest-pinned x86_64 inputs and must be
reviewed as supply-chain changes when updated.

The permanent release/tag is
`disk-<12-character-commit>-<12-character-digest>`. Re-running with the same
source revision and OCI input reconciles that release instead of creating a
duplicate. A different source revision or OCI digest creates a distinct
historical disk release. Daily OCI schedules do not build disks or create
releases, so the release list does not grow every day. Release notes record the
full repository revision and exact OCI digest used for the build.

The repository and owning organization are public, so the privileged jobs pull
the digest-pinned image anonymously. No registry PAT, Cosign private key, or
Cosign password is exposed to the privileged disk builders. GPG credentials are
provided only to the final unprivileged signing step. If the package becomes
private later, add the narrowest job-scoped pull credential rather than logging
the DinD daemon in globally.

bootc-image-builder consumes its source through rootful Podman
containers-storage even though this Forgejo job is driven by the Docker CLI.
Before the matrix starts, the prepare job pulls the exact digest-pinned source
into the persistent, labeled Docker volume
`bazzite-firebadnofire-bib-image-cache-v1`. It never keys the cache from the
mutable `stable` tag: `stable` is resolved and verified first, and the cache is
then populated from `pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:...`.
A missing or empty volume is a normal cold cache and Podman downloads the image;
later digests reuse any unchanged content-addressed layers already present.

Each matrix job still creates its own writable Docker volume for
`/var/lib/containers/storage`. `disk_config/ci-storage.conf` exposes the
persistent store to that job through containers/storage's read-only
`additionalimagestores` mechanism. The QCOW2 and ISO builders mount the cache
read-only and can create temporary images or metadata only in their separate,
run-scoped writable stores. They therefore do not concurrently mutate one
containers/storage database.

Podman can inspect the canonical registry digest through the additional image
store, but bootc-image-builder/osbuild's containers-storage resolver needs the
image name and all layer metadata in the primary writable graphroot. A writable
tag or a copy performed while the additional store remains visible can resolve
the name while still leaving osbuild unable to find the read-only layers.
Under the existing shared cache lock, each job therefore resolves the
digest-pinned cached image to its full Podman image ID and uses
`cp -a --reflink=always` to copy only the cache's immutable `overlay`,
`overlay-images`, and `overlay-layers` data into its disposable store.
The earlier cache-verification and diagnostic Podman commands normally
initialize that store's directories, locks, and graphroot-specific `libpod`
database even when it contains no writable images. Promotion therefore checks
the writable image inventory rather than filesystem emptiness and merges the
cached image data into those initialized directories without copying `libpod`.
If the deterministic local build reference already exists, its full image ID
must match the cached image ID; otherwise a nonempty writable image inventory
fails closed before the raw image-store merge.
The Btrfs-backed runner makes this a copy-on-write local promotion rather than
a second registry pull or a second fully allocated image. Reflink support and
same-filesystem Docker volumes are therefore disk-builder runner requirements;
the job fails instead of silently making a space-heavy full copy.

After promotion, the builder switches to
`disk_config/ci-writable-storage.conf`, which removes `additionalimagestores`
from the builder's resolution path, and creates
`localhost/bazzite-firebadnofire-build-source:cached` in the writable store.
The job requires that the local name appears in `readonly=false` output and
that its full image ID exactly equals the cached digest-selected image ID. It
then gives only this verified local name to bootc-image-builder. Any conflicting
writable image, incomplete copy, missing name, ambiguous writable entry, or ID
mismatch fails before manifest generation; the original registry digest
remains the release's canonical source identity.

The companion `bazzite-firebadnofire-bib-image-cache-lock-v1` volume contains
the cross-container lock file. Cache refresh and maintenance take an exclusive
`flock`; each builder holds a shared lock for its entire run. This also protects
against disk workflows for different refs, which are not covered by the same
Forgejo concurrency group. The cache volumes live in the DinD daemon under
`/var/lib/docker/volumes/`, backed by Compose's persistent
`docker-data:/var/lib/docker` volume. They survive matrix jobs, workflow runs,
and runner/DinD container restarts, but remain disposable Docker data. The
host-side `./build-cache` bind mount is deliberately unused, so it does not need
to be added to the DinD service.

Ordinary workflow cleanup removes only per-job containers, output volumes,
writable Podman stores, and run-scoped handoff volumes. It never removes the
persistent source cache. A failed build prints both writable-store and
read-only-cache inventory, exact image identity, directories, cache size, and
filesystem capacity before cleanup. See
[bootc source-cache operations](docs/disk-source-cache.md) for inspection,
exclusive-lock pruning, rollback, and warm-cache verification commands.

### Terra Mesa repository keys

Bazzite supplies `/etc/yum.repos.d/terra-mesa.repo` through
`terra-release-mesa`; `terra-gpg-keys` supplies
`/etc/pki/rpm-gpg/RPM-GPG-KEY-terra44-mesa`. The inspected published Fedora 44
image already contained this key. The manifest depsolver's metadata verifier
can resolve the repo's absolute `file://` key URL against the **builder** root
instead of the source image root, producing a misleading missing-key error.

At the end of image construction, `build_files/fix-terra-mesa-keys.sh` changes
only the Mesa and Mesa-source GPG-key locations to Terra's official
`https://repos.fyralabs.com/terra$releasever-mesa/key.asc` (and `-mesa-source`)
endpoints. It first requires each downloaded key to match the packaged local
key byte-for-byte; missing keys or key rotations fail the build for review.
The local files remain installed. Repo enablement, package `gpgcheck=1`, and
metadata `repo_gpgcheck=1` are preserved. HTTPS certificate verification stays
enabled. Subsequent depsolving depends on Terra's HTTPS endpoint and its key
distribution, rather than a builder-local key file; no runner changes are needed.

`build_files/validate-repo-keys.py` then checks every enabled section in
`/etc/yum.repos.d/*.repo`, expanding Fedora/architecture and DNF vars and failing
on unresolved variables or missing, empty, or unreadable local GPG-key files.
It conservatively checks the on-disk `enabled` setting even if DNF5 overrides
disable a repo, because other solvers may not consume those overrides. This
gate checks source-image completeness; the HTTPS repair separately addresses
the builder-root mismatch. Offline regression tests run with `just validate`.

Verify on Linux after applying the change:

```bash
just validate
just build
podman run --rm --entrypoint /usr/bin/bash localhost/bazzite-firebadnofire:stable -c '
  set -Eeuo pipefail
  cat /etc/yum.repos.d/terra-mesa.repo
  rpm -qf /etc/yum.repos.d/terra-mesa.repo /etc/pki/rpm-gpg/RPM-GPG-KEY-terra44-mesa
  test -s /etc/pki/rpm-gpg/RPM-GPG-KEY-terra44-mesa
  dnf5 -y --repo=terra-mesa --refresh makecache
'
```

Then publish the changed image via **Actions → Validate, build, publish, and sign → Run workflow**
on `main`, wait for publication and signature verification to succeed, and
dispatch **Build and release disk artifacts**. Confirm its resolved digest is
the new image digest and both `qcow2` and `installer-iso` pass manifest
generation, artifact validation, signing, and release verification. Rerunning
the disk workflow against the old image cannot pick up this image-side fix.
Local metadata verification alone does not prove either disk build or VM boot.

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
space. They do not sign or publish artifacts and do not modify a physical disk.

### OpenPGP verification for downloadable artifacts

OpenPGP `.asc` signatures authenticate the downloadable QCOW2, ISO, and
`SHA256SUMS` files. They do not authenticate the OCI registry image; use Cosign
for that as documented above.

The expected signing identity is `William Jones (Yubikey generated GPG key)`.
The required full fingerprint is:

```text
7D6E F134 D851 C8DA 0862 D974 94F3 1AF3 74E2 EE3C
```

Import the public key from either supported keyserver:

```bash
gpg --keyserver hkps://keys.openpgp.org \
  --recv-keys 7D6EF134D851C8DA0862D97494F31AF374E2EE3C
gpg --keyserver hkps://keyserver.ubuntu.com \
  --recv-keys 7D6EF134D851C8DA0862D97494F31AF374E2EE3C
```

Public-key copies are also available from
[`https://github.com/firebadnofire.gpg`](https://github.com/firebadnofire.gpg),
[`https://archuser.org/gpg.key`](https://archuser.org/gpg.key), and the direct
import URL [`https://archuser.org/gpg/william.asc`](https://archuser.org/gpg/william.asc).
On PowerShell, direct import is:

```powershell
Invoke-WebRequest `
    -Uri 'https://archuser.org/gpg/william.asc' `
    -OutFile 'william.asc'

gpg --import .\william.asc
```

On Windows, Kleopatra is included with
[Gpg4win](https://www.gpg4win.org/), which can be installed with:

```powershell
winget install GnuPG.Gpg4win
```

Always inspect the full fingerprint, then verify each artifact against the
matching signature:

```bash
gpg --fingerprint 7D6EF134D851C8DA0862D97494F31AF374E2EE3C
gpg --verify ./<artifact>.asc ./<artifact>
```

A `Good signature` result is not sufficient by itself. Confirm that the key has
the exact full fingerprint shown above. After that, validate the checksum list
from the directory containing the downloads with `sha256sum --check
--strict SHA256SUMS` (or an equivalent trusted checksum tool).

## VM smoke testing

Do not install on hardware before booting the QCOW2 in a UEFI QEMU/KVM VM.
Exact firmware paths differ by distribution. A representative Fedora/Bazzite
test uses `qemu-system-x86_64`, KVM, host CPU passthrough, 8 GiB RAM, and an OVMF
firmware pair supplied by `edk2-ovmf`.

In the VM, verify at minimum:

```bash
sudo bootc status
grep -E '^(NAME|PRETTY_NAME|ID|ID_LIKE)=' /etc/os-release
systemctl is-enabled virtqemud.service
rpm -q dolphin foot hyprland hyprland-guiutils hyprpaper \
  xdg-desktop-portal xdg-desktop-portal-gtk \
  xdg-desktop-portal-hyprland xdg-user-dirs qemu-kvm virt-manager
```

Then exercise the actual graphical path:

1. Select the Hyprland session in the display manager and log in.
2. Open Foot, Dolphin, Fuzzel, Waybar, and the notification center.
3. Add a test image to `~/.config/wallpapers`, press `Super+I`, and confirm
   Hyprpaper changes the wallpaper. Also confirm the empty-directory
   notification with a fresh test account.
4. Test audio controls, locking/unlocking, the Waybar clipboard picker, full and
   region screenshots, and a PipeWire screen-share portal request.
5. Launch an XWayland application and a native Wayland application.
6. Verify the session and portal lifecycle from a terminal:

   ```bash
   systemctl --user is-active \
     hyprland-session.target graphical-session.target \
     xdg-desktop-portal.service
   systemctl --user status xdg-desktop-portal-hyprland.service
   systemctl --user show-environment | \
     grep -E '^(WAYLAND_DISPLAY|XDG_CURRENT_DESKTOP|HYPRLAND_INSTANCE_SIGNATURE)='
   test -d "$(xdg-user-dir DOWNLOAD)"
   grep '^XDG_DOWNLOAD_DIR=' ~/.config/user-dirs.dirs
   ```

   All three units in the first command must report `active`, and the manager
   environment must identify the running Hyprland instance.
7. In Flatpak Firefox, download a file to the reported downloads directory,
   exercise both open and save file dialogs, and use **Show in Folder** to
   confirm Dolphin reveals the file.
8. Log out normally and confirm the display manager returns, then log in again
   and repeat the unit checks. Also test one controlled abnormal exit from a
   text console or SSH session and confirm the login manager recovers and the
   next session activates both targets without manual commands.
9. Reboot, update, and roll back once before considering hardware installation.

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

The shipped repository-scoped registry configuration preserves
`pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable` as the origin
shown by bootc. Pulls transparently rewrite the same repository/tag or digest to
`ghcr.io/firebadnofire/bazzite-firebadnofire` first, then fall back to Pubcode
if GHCR is unavailable. Keep the two `stable` tags synchronized; the
network-installer workflow fails before building when both are reachable and
their resolved digests differ, and warns when either fallback audit cannot run.
The fallback does not disable TLS,
accept a different repository name, or broaden mirroring to unrelated images.

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

The image enables Fedora’s modular `virtqemud.service` and supporting libvirt
sockets, disables the conflicting legacy `libvirtd` defaults, and installs the
workstation virtualization stack. User authorization is machine-specific. After
installation, check group membership and add the intended account only if needed:

```bash
getent group libvirt
id
sudo usermod --append --groups libvirt "$USER"
```

Log out and back in before opening virt-manager. Adding users to `libvirt` is a
privileged local policy decision; do not apply it indiscriminately.

The image ships single-GPU NVIDIA handoff for system-libvirt guests named with
an exact, case-sensitive `-gpu` suffix. Only one such guest can own the GPU;
shutdown restores the host driver and login screen. Starting a GPU guest ends
the graphical session. Users must configure managed PCI assignments and the
machine's firmware/IOMMU prerequisites first.

GPU-holder diagnostics distinguish metadata-only device descriptors from active
GPU handles, including those owned by PID 1. See the troubleshooting guidance below
before attempting to stop a reported holder.

Read [single-GPU VFIO setup, activation checks, recovery, and validation](docs/vfio.md)
before use. After a bootc update and reboot, `sudo vfio-host-check` verifies
that the running daemon executes the installed adapter.
`sudo vfio-host-recover --status` inspects ownership; `sudo vfio-host-recover` performs guarded recovery.
Locally modified `/etc` hooks are preserved and may require reconciliation.

These GPLv3 components adapt RisingPrism's single-GPU scripts, with the upstream
license and contributor credits shipped in the image. The implementation does
not set machine-specific PCI IDs, IOMMU kernel arguments, ROMs, driver
blacklists, CPU isolation, huge pages, or Looking Glass shared memory. Mocked
tests and image checks do not establish physical GPU handoff compatibility;
follow the separate booted-system and hardware acceptance matrix in the guide.

## Validation status and known risks

Use this vocabulary when reporting results:

- **static**: repository syntax and consistency checks ran;
- **built**: the OCI image completed, including `bootc container lint`;
- **inspected**: required packages, files, and service enablement were checked
  inside the built image;
- **published**: both registries accepted all three tags and they resolve to the
  same digest, including an anonymous GHCR resolution;
- **signature-verified**: Cosign independently verified both fully qualified
  registry digest references;
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
- Forgejo runner disk capacity, DinD privilege, both registries' permissions,
  and GHCR package visibility;
- bootc-image-builder QCOW2/ISO output and installer boot;
- host-specific libvirt/VFIO and Looking Glass integration.

## Scope

This repository owns the shallow system-image delta and its operator workflow.
It does not manage personal dotfiles, application source builds, development
database services, secrets, guest definitions, or host-specific VFIO settings.
Prefer toolbox/Distrobox/Podman for project-specific toolchains and services so
the immutable host remains maintainable.
