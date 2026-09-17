# bazzite-firebadnofire: project dossier

This document is a self-contained handoff for an AI coding agent working in this repository. It describes the repository as it exists at commit `1dd3b65` on 2026-09-17. Verify the working tree and recent history before relying on snapshot-specific details.

## Executive summary

This is a small Universal Blue `image-template` repository for producing a customized bootc operating-system image from Bazzite. The image build is declarative and layered:

1. Podman evaluates `Containerfile`.
2. The pinned Bazzite base image is pulled.
3. `build_files/build.sh` overlays `system_files/`, installs packages, and enables services.
4. `bootc container lint` validates the resulting container.
5. The `Justfile` can rechunk the image for smaller incremental updates.
6. CI can push aliases to GHCR and sign the pushed digest with Cosign.
7. A separate workflow can turn a published OCI image into QCOW2 and Anaconda ISO artifacts.

The repository has not yet been configured as a finished `bazzite-firebadnofire` product. Most identity values and documentation are upstream placeholders. The current custom behavior is only:

- inherit from a digest-pinned `ghcr.io/ublue-os/bazzite:stable` image;
- copy the `system_files/` overlay, which currently contains no payload files;
- install `tmux`; and
- enable `podman.socket`.

Do not assume that the repository name is the built image name. At present, the primary build reads `IMAGE_NAME=image-template`, while the disk workflow uses the repository name. This and the missing `disk_config/iso.toml` are blocking configuration inconsistencies described below.

## Authority and scope

- There is no repository-local `AGENTS.md`.
- There is no `/VISION.md`.
- The current user request and any instructions supplied by the execution environment govern changes.
- Executable files are more authoritative than the generic `README.md`, which still documents the upstream template.
- Preserve the existing bootc/Universal Blue architecture unless the user explicitly requests a replacement.
- Do not expand a focused request into a general template-completion effort without authorization.

## Repository state at this snapshot

| Item | Current value |
|---|---|
| Branch | `main` |
| HEAD | `1dd3b656c4eb99dea9fbf9bd8210a754bd94adab` |
| Working tree before this dossier | Clean and aligned with `origin/main` |
| Origin | `ssh://git@pubcode.archuser.org:2222/universalblue/bazzite-firebadnofire.git` |
| Tags | None visible locally |
| License | Apache License 2.0 |
| Primary runtime | Linux/bootc image; not Windows |
| Local orchestration | `just`, Bash, Podman, `jq` |
| CI definitions | GitHub Actions syntax, GHCR publication |
| Tests | No unit or integration test suite |

The checkout may be opened from Windows, but build scripts use Bash, Linux tools, Podman, systemd, DNF, SELinux mount labels, `/var/lib/containers/storage`, and KVM. Run substantive build and lint commands on a compatible Linux or bootc host, or in a deliberately prepared Linux environment. Do not translate commands mechanically into PowerShell and claim equivalent validation.

## Architecture and data flow

```text
image-template.env
      |
      v
  Justfile ------------------------------+
      |                                  |
      | just build                       | disk recipes
      v                                  v
Containerfile                     bootc-image-builder
      |                                  |
      +--> pinned Bazzite base            +--> QCOW2 / raw / ISO
      |
      +--> build_files/build.sh
              |
              +--> copy system_files/ onto /
              +--> dnf5 install tmux
              +--> systemctl enable podman.socket
      |
      +--> bootc container lint
      v
local OCI image
      |
      +--> rpm-ostree rechunk (CI default)
      +--> tag aliases
      +--> push to GHCR
      +--> Cosign-sign pushed digest
```

### Container build

`Containerfile` uses a scratch stage named `ctx` to make build scripts and overlay files available through a bind mount without leaving those source files in the final image. The main stage currently uses:

```text
ghcr.io/ublue-os/bazzite:stable@sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76
```

The build script is run with:

- a read-only-style build context bind at `/ctx`;
- cache mounts for `/var/cache` and `/var/log`; and
- a tmpfs at `/tmp`.

The final `RUN bootc container lint` is an important image invariant. Do not remove it merely to make a failing image build pass; diagnose the lint failure.

### Image customization

`build_files/build.sh` is the central customization entry point. It uses `set -ouex pipefail`, so unset variables, command failures, and pipeline failures are fatal and commands are traced. Its current sequence is:

1. `cp -avf /ctx/system_files/. /`.
2. `dnf5 install -y tmux`.
3. `systemctl enable podman.socket`.

The script is executable in Git. Preserve that mode. Package installation and service enablement occur during image construction, not on first boot.

### Filesystem overlay

`system_files/` mirrors the root filesystem. A file at `system_files/usr/lib/example` becomes `/usr/lib/example` in the image. The only tracked entries today are:

- `system_files/etc/.gitkeep`
- `system_files/usr/.gitkeep`

Therefore, the overlay currently changes nothing. For immutable OS defaults, prefer appropriate paths under `/usr`; use `/etc` only when the intended bootc configuration semantics are understood. Never place secrets, machine-specific credentials, private keys, or mutable user data in the image overlay.

### Rechunking

CI uses `just ostree-rechunk`, which runs `rpm-ostree compose build-chunked-oci` from the already-built local image, with privileged access to the Podman graph root. It replaces the original local tag with a chunked image containing at most 127 layers.

An alternative `just rechunk` recipe uses the floating `quay.io/coreos/chunkah:latest` image and an OCI directory. It is not used by the active workflow. It creates temporary files and registers an exit trap for cleanup.

### Publication and signing

`.github/workflows/build.yml` runs for pull requests to `main`, pushes to `main`, a daily 10:05 UTC schedule, and manual dispatch. README-only pushes are ignored.

The workflow:

1. checks out the repository;
2. frees runner disk space;
3. installs `just`;
4. validates Just syntax;
5. resolves the image name and default tag from `image-template.env`;
6. builds and rpm-ostree-rechunks the image;
7. generates date, commit, and default-tag aliases;
8. logs into GHCR on non-PR default-branch runs;
9. pushes every alias and records a digest; and
10. signs the final digest with Cosign using `secrets.SIGNING_SECRET`.

The workflow grants `contents: read`, `packages: write`, and `id-token: write`. Publication and signing are skipped for pull requests. Signing is key-based, not keyless, despite the OIDC permission. Cosign is explicitly told to use the older bundle format for rpm-ostree compatibility.

The digest output comes from the last `podman push` in the alias loop. All aliases refer to the same image ID, so that is expected to be the same content digest, but any change to tagging/pushing must preserve digest-accurate signing.

### Disk images

`.github/workflows/build-disk.yml` is intended to build both `qcow2` and `anaconda-iso` using `osbuild/bootc-image-builder-action`. Manual runs require an `amd64` or `arm64` choice and optionally upload to S3. Otherwise, artifacts are uploaded through the workflow artifact service.

`disk_config/disk.toml` sets a 20 GiB minimum root filesystem. The two ISO variants contain different Anaconda module choices:

- `iso-gnome.toml` enables only Storage and Runtime and disables Network, Security, Services, Users, Subscription, and Timezone.
- `iso-kde.toml` enables Storage, Runtime, Network, Security, Services, Users, and Timezone; it disables only Subscription.

Both ISO variants currently switch the installed system to the placeholder image `ghcr.io/ublue-os/image-template:latest` in `%post`.

## File map

| Path | Role | Change with care because… |
|---|---|---|
| `Containerfile` | Selects the base image, invokes customization, lints final image | Base digest and bootc validity define the shipped OS |
| `build_files/build.sh` | Installs packages, applies overlay, enables services | Runs as part of the image build with root privileges |
| `system_files/` | Root filesystem overlay | Contents ship on every installed system |
| `image-template.env` | Image identity, tags, metadata, builder image | Consumed automatically by every Just recipe |
| `Justfile` | Local/CI build, rechunk, tag, disk, VM, lint, clean tasks | Contains privileged and destructive cleanup/build operations |
| `.github/workflows/build.yml` | OCI build, GHCR push, Cosign signing | Has package-write permission and uses a signing secret |
| `.github/workflows/build-disk.yml` | QCOW2/ISO generation and optional S3 upload | Uses privileged image building and external credentials |
| `disk_config/disk.toml` | Non-ISO disk sizing | Affects installed filesystem layout/capacity |
| `disk_config/iso-gnome.toml` | GNOME-oriented installer customization | Currently unused and contains a placeholder image reference |
| `disk_config/iso-kde.toml` | KDE-oriented installer customization | Currently unused and contains a placeholder image reference |
| `.github/renovate.json5` | Renovate behavior | Auto-merges pinning updates and manages action/base references |
| `.github/dependabot.yml` | Weekly GitHub Actions updates | Overlaps Renovate's dependency domain |
| `artifacthub-repo.yml` | Optional Artifact Hub ownership claim | Entirely placeholder data today |
| `README.md` | Upstream template guide | Does not describe this repository as a configured product |
| `.gitignore` | Excludes private key and build outputs | `cosign.key` must remain untracked |

## Configuration contracts

### `image-template.env`

The Justfile loads this file automatically and requires all seven values:

| Variable | Current value | Consumer |
|---|---|---|
| `IMAGE_NAME` | `image-template` | Build/tag/push identity |
| `REPO_ORGANIZATION` | `alice-and-bob` | OCI metadata URLs/vendor |
| `IMAGE_DESC` | `My Customized Bootc Image` | OCI description |
| `IMAGE_KEYWORDS` | `bootc,oci,linux` | Artifact Hub metadata |
| `IMAGE_LOGO_URL` | upstream avatar URL | Artifact Hub metadata |
| `DEFAULT_TAG` | `latest` | Build and alias generation |
| `BIB_IMAGE` | `quay.io/centos-bootc/bootc-image-builder:latest` | Local disk builds |

Changing identity requires tracing all consumers, not just editing `IMAGE_NAME`. At minimum reconcile:

- `image-template.env`;
- `.github/workflows/build-disk.yml`;
- both installer kickstarts (or the selected replacement `iso.toml`);
- OCI metadata URLs in the Justfile;
- `README.md` examples and switch instructions;
- `artifacthub-repo.yml`; and
- actual registry/repository ownership and secrets.

### Tag contract

For a clean Git tree, `just generate-build-tags NAME TAG` emits:

- `TAG-SHORT_SHA`
- `TAG-YYYYMMDD-SHORT_SHA`
- `YYYYMMDD-SHORT_SHA`
- `YYYYMMDD`
- `TAG`
- `TAG-YYYYMMDD`

For a dirty tree, the three commit-derived tags are omitted. Image metadata similarly includes commit-specific source/documentation URLs only for a clean tree.

### External secret contract

- `SIGNING_SECRET`: plaintext contents of the unencrypted Cosign private key expected by `cosign --key env://COSIGN_PRIVATE_KEY`. Never print or commit it.
- `S3_PROVIDER`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION`, `S3_ENDPOINT`, `S3_BUCKET_NAME`: used only when manual disk upload is enabled. Do not add fallback credentials to the repository.

No `cosign.pub` is tracked at this snapshot, although the README tells template users to create one. Do not claim that consumers can verify releases from this repository until a public verification contract is deliberately established and tested.

## Known inconsistencies and unfinished setup

These are current facts, not an instruction to fix everything opportunistically.

1. **Image identity mismatch.** The container workflow builds and pushes `image-template`; the disk workflow reads `${{ github.event.repository.name }}`, which would be `bazzite-firebadnofire` on a same-named GitHub repository.
2. **Missing ISO configuration.** The active disk workflow and the Justfile refer to `disk_config/iso.toml`, which does not exist. Only `iso-gnome.toml` and `iso-kde.toml` exist.
3. **Disk workflow trigger mismatch.** Pull requests watch `./disk_config/iso.toml`, so edits to the two tracked ISO variants do not trigger the workflow.
4. **Placeholder installer target.** Both tracked ISO configurations switch installations to `ghcr.io/ublue-os/image-template:latest`.
5. **Placeholder metadata.** Organization, description, logo, Artifact Hub repository ID, owner, and email remain template examples.
6. **Generic documentation.** The README describes how to instantiate the template rather than what this image is intended to provide.
7. **No public signing key in tree.** Signing may occur in CI if the private-key secret exists, but repository-local verification material is absent.
8. **Floating build tools.** `BIB_IMAGE` and the optional Chunkah image use `latest`; this reduces reproducibility compared with the digest-pinned base and pinned workflow actions.
9. **Hosting assumption is unresolved.** The configured Git remote is on `pubcode.archuser.org`, while workflows use GitHub contexts, GHCR, and GitHub-hosted action syntax. This may be intentional via mirroring or a compatible runner, but the repository does not document it. Verify the actual CI host before editing publication logic.
10. **No automated runtime tests.** Current validation is syntax checks, shell lint when run explicitly, container build success, and `bootc container lint`. VM/device behavior is not proven by CI configuration alone.

## Development workflows

Run these from the repository root on Linux with the listed dependencies. Commands that build disk images or manipulate rootful container storage may invoke `sudo` and require substantial disk space.

### Fast, non-destructive checks

```bash
git status --short --branch
just check
just lint
```

Requirements:

- `just check`: `just`, Bash, standard Unix `find`.
- `just lint`: `just`, Bash, ShellCheck.

`just format` modifies every `*.sh` file using `shfmt`; inspect its diff. `just fix` modifies Just syntax formatting. They are not validation-only commands.

### Build the OCI image

```bash
just build
```

Requirements include Podman, Bash, Git, network access to the configured registry, and enough disk space for a Bazzite image. The recipe uses `--pull=newer` but the base is digest-pinned, so changing the base requires an intentional digest update.

After a successful build, validate at least:

```bash
podman image inspect image-template:latest
podman run --rm image-template:latest rpm -q tmux
```

Testing `podman.socket` enablement may require inspecting the image filesystem or booting it; a plain container process is not a systemd boot.

### Rechunk and inspect

```bash
just ostree-rechunk
podman image inspect image-template:latest
```

The recipe is privileged and directly mounts the Podman graph root. Do not treat it as a harmless formatting step.

### Build bootable artifacts

The generic commands are:

```bash
just build-qcow2
just build-raw
just build-iso
```

QCOW2 and raw use `disk_config/disk.toml`. ISO currently fails before a meaningful build because `disk_config/iso.toml` is absent. Resolve the desired desktop/config choice explicitly before creating that file or changing the recipes.

Disk output is placed under `output/`. The recipes run a privileged bootc-image-builder container, mount rootful container storage, and may copy a rootless image into rootful storage first.

### Run a VM

`just run-vm-qcow2` and related recipes use `docker.io/qemux/qemu`, `/dev/kvm`, TPM and GPU options, 4 CPU cores, 8 GiB RAM, a 64 GiB disk, and a web console bound only to `127.0.0.1`, beginning at port 8006. They also attempt to call `xdg-open` after 30 seconds.

`just spawn-vm` instead requires `systemd-vmspawn`. Neither path is suitable for an unprepared Windows host.

### Cleanup

`just clean` recursively removes matching `_build*` paths and deletes generated files and `output/`. Review `git status` and confirm that no needed artifact lives in those ignored locations before running it. It is intended to be idempotent, but it is destructive to local build outputs.

## Validation matrix

Use the smallest relevant checks first, then increase fidelity. Never report a lower layer as proof of a higher one.

| Change type | Minimum validation | Stronger validation |
|---|---|---|
| Documentation only | Review diff; verify paths/commands against tree | Markdown/link check if available |
| `Justfile` | `just check` | Run the affected recipe in a disposable/local environment |
| Bash customization | `just lint`; `shfmt --diff build_files/build.sh` | Full `just build` |
| Overlay file | Confirm destination path, mode, owner, SELinux expectations | Full image build plus `podman` filesystem inspection |
| Package/service change | Full OCI build and `bootc container lint` | Boot VM and verify package/service state after reboot |
| Base image update | Full build, inspect resolved digest and labels | VM boot, upgrade/rebase and rollback checks |
| Rechunk logic | Build then rechunk; compare image inspect output | Push to test registry and perform an update test |
| Workflow edit | YAML parse plus action/input review | Pull-request CI run |
| Disk config | TOML parse and referenced-path check | Build each affected artifact, boot/install it in a VM |
| Publication/signing | Local static review without secrets | Authorized CI push, signature verification by digest |

Be explicit in the final report: local syntax checks do not prove CI; CI build success does not prove publication unless the push ran; an OCI build does not prove a bootable disk; a VM boot does not prove physical hardware support.

## Security and reliability invariants

- Never commit `cosign.key`, signing secrets, S3 credentials, registry tokens, or machine credentials.
- Keep image signing fail-closed. Do not make signing optional on publication merely to obtain a green workflow.
- Sign immutable digests, not only mutable tags, and preserve exact verification instructions when a public key is introduced.
- Preserve certificate verification for registries and object storage. Do not add insecure-registry or TLS-bypass flags.
- Prefer digest-pinned images and commit-pinned actions. Treat updates as supply-chain changes requiring build validation.
- Retain least-privilege workflow permissions. Add permissions only when a demonstrated step needs them.
- Preserve the VM console's loopback binding unless remote exposure is explicitly required and secured.
- Treat `build_files/build.sh`, `Containerfile`, workflow shell blocks, installer `%post`, and overlay executables as privileged code.
- Ensure new scripts are safe on repeated image builds. Avoid appending duplicate configuration or depending on mutable external state without validation.
- Do not mask errors with `|| true`, broad exception handling, or removed strict-mode flags.
- Do not remove `bootc container lint` to bypass a failure.
- Avoid writing mutable application state into immutable image paths. Understand bootc `/usr`, `/etc`, `/var`, and `/opt` behavior before choosing a destination.

## Guidance for common changes

### Add a package

1. Confirm it is available in repositories already enabled by the Bazzite base.
2. Add it to the existing `dnf5 install` invocation or a clearly grouped invocation in `build_files/build.sh`.
3. Keep the operation noninteractive and repeatable.
4. Run shell lint/format checks.
5. Build the image and query the installed RPM.
6. Boot-test if the package changes services, drivers, graphics, networking, or early boot.

Do not enable a COPR permanently. If one is required, enable it narrowly, install the package, and disable it before the layer completes.

### Add or modify a system file

1. Map the exact target path under `system_files/`.
2. Check whether the Bazzite base already owns or generates that path.
3. Preserve appropriate mode and avoid embedding secrets.
4. Build and inspect the final file, including ownership and symlink behavior.
5. Boot-test files consumed by systemd, udev, NetworkManager, dracut, bootloader tooling, or the desktop session.

### Add a systemd unit

1. Put a packaged-style unit under `system_files/usr/lib/systemd/system/` unless there is a specific reason to use another location.
2. Enable it during the image build with `systemctl enable UNIT`.
3. Ensure repeated builds do not produce duplicate state.
4. Run `systemd-analyze verify` where practical, build the image, then boot-test status and logs.

### Change the product identity

Treat this as a cross-cutting configuration change. Reconcile every item listed under “Configuration contracts,” decide which ISO variant is authoritative, update registry references atomically, and validate the exact image URI generated by both workflows. Do not silently choose GNOME or KDE if the user has not specified the intended Bazzite flavor.

### Change the base image

Keep the tag and digest coherent. A digest pin overrides movement of the `stable` tag. Record why the new base/flavor is correct, build it, inspect the actual resolved image, and boot-test features that depend on kernel, GPU, desktop, or hardware enablement.

### Change CI or release behavior

Trace event conditions, default-branch guards, permissions, secrets, registry destination, aliases, digest capture, and signing as one flow. Pull requests intentionally build but do not publish. Do not push, publish, create secrets, rotate keys, or modify external repository settings without explicit authority.

## Agent operating procedure

Before editing:

1. Read the current user request and repository/execution instructions.
2. Run `git status --short --branch`; preserve unrelated user changes.
3. Check for a newly added `/VISION.md` or `AGENTS.md`.
4. Inspect every direct consumer of the setting or behavior being changed.
5. State a minimal implementation and validation plan.
6. Identify whether the work requires Linux, Podman, root, network, CI, registry, VM, or hardware access.

During implementation:

1. Make the smallest coherent change.
2. Match existing Bash, Just, YAML, and TOML style.
3. Validate that unit before moving to the next one.
4. Stop on critical failures and report the exact failing command and relevant output.
5. Keep generated artifacts, secrets, and unrelated formatting out of the diff.

Before handoff:

1. Review `git diff --check` and `git diff`.
2. Run all locally available relevant checks.
3. Search for stale names/paths if identity or disk configuration changed.
4. Distinguish what was statically inspected, locally executed, built, booted, published, or hardware-tested.
5. List unresolved risks or external validation honestly.

## Questions that require a product decision

Do not guess these from the repository name:

- What does “firebadnofire” mean as a user-facing product and what behavior should distinguish it from stock Bazzite?
- Should the actual OCI image be named `bazzite-firebadnofire`, and under which registry organization?
- Is the target desktop/image flavor KDE, GNOME, Steam Gaming Mode, or another Bazzite variant?
- Which ISO configuration should be authoritative, if ISO production is in scope?
- Is GHCR the intended publication registry despite the non-GitHub origin remote?
- Is Artifact Hub publication desired?
- What is the public Cosign verification key and documented verification command?
- Which architectures and hardware targets are supported and actually tested?

Until those questions are answered, preserve placeholders only when outside the requested change, but never describe them as production-ready values.

## Current baseline conclusion

The repository is structurally capable of building a lightly modified, digest-pinned Bazzite bootc container and has mature template machinery for rechunking, publication, signing, disk generation, and VM launching. Its product-specific configuration is incomplete and internally inconsistent. A safe agent should first clarify the intended identity and desktop/ISO target for any productization request, then update all connected consumers together and validate from syntax through image build and, when relevant, VM boot or installation.
