#!/usr/bin/bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
cd "${root}"

required_files=(
    .forgejo/workflows/build-iso.yml
    .forgejo/workflows/build-net.yml
    bazzite-firebadnofire.env
    cosign.pub
    disk_config/ci-storage.conf
    disk_config/ci-writable-storage.conf
    disk_config/disk.toml
    disk_config/iso.toml
    scripts/oci-publication.sh
    scripts/retry-once.sh
    scripts/publish-github-release.sh
    scripts/sign-release-artifacts.sh
    network-installer/Containerfile
    network-installer/interactive-defaults.ks
    network-installer/iso.yaml
    system_files/etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf
    scripts/test-oci-publication.sh
    scripts/test-retry-once.sh
    system_files/usr/lib/tmpfiles.d/bazzite-firebadnofire.conf
    system_files/usr/libexec/bazzite-firebadnofire-rotate-wallpaper
    system_files/usr/share/bazzite-firebadnofire/hypridle.conf
    system_files/usr/share/bazzite-firebadnofire/hyprland.lua
    system_files/usr/share/bazzite-firebadnofire/hyprlock.conf
    system_files/usr/share/bazzite-firebadnofire/hyprpaper.conf
    system_files/usr/share/bazzite-firebadnofire/waybar/config.jsonc
    system_files/usr/share/wayland-sessions/hyprland.desktop
)

for file in "${required_files[@]}"; do
    [[ -s "${file}" ]] || {
        echo "error: required file is missing or empty: ${file}" >&2
        exit 1
    }
done

# Unlike the other required files, include.txt may intentionally be empty.
[[ -f include.txt ]] || {
    echo "error: required file is missing: include.txt" >&2
    exit 1
}

bash -n \
    scripts/disk-handoff.sh \
    scripts/test-disk-handoff.sh \
    build_files/fix-terra-mesa-keys.sh \
    build_files/include-packages.sh \
    build_files/build.sh \
    scripts/test-include-packages.sh \
    scripts/oci-publication.sh \
    scripts/retry-once.sh \
    scripts/publish-github-release.sh \
    scripts/sign-release-artifacts.sh \
    scripts/test-oci-publication.sh \
    scripts/test-retry-once.sh \
    scripts/validate-static.sh \
    system_files/usr/libexec/bazzite-firebadnofire-rotate-wallpaper \
    system_files/usr/libexec/bazzite-firebadnofire-screenshot \
    system_files/usr/libexec/bazzite-firebadnofire-start-hyprland

for command_name in python3 rg shellcheck; do
    command -v "${command_name}" >/dev/null || {
        echo "error: ${command_name} is required for repository validation" >&2
        exit 1
    }
done
shellcheck \
    scripts/disk-handoff.sh \
    scripts/test-disk-handoff.sh \
    build_files/fix-terra-mesa-keys.sh \
    build_files/include-packages.sh \
    build_files/build.sh \
    scripts/test-include-packages.sh \
    scripts/oci-publication.sh \
    scripts/retry-once.sh \
    scripts/publish-github-release.sh \
    scripts/sign-release-artifacts.sh \
    scripts/test-oci-publication.sh \
    scripts/test-retry-once.sh \
    scripts/validate-static.sh \
    system_files/usr/libexec/bazzite-firebadnofire-rotate-wallpaper \
    system_files/usr/libexec/bazzite-firebadnofire-screenshot \
    system_files/usr/libexec/bazzite-firebadnofire-start-hyprland

PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-repo-keys.py
bash scripts/test-include-packages.sh
bash scripts/test-oci-publication.sh
bash scripts/test-retry-once.sh

python3 - <<'PY'
from pathlib import Path
import json
import subprocess

try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        import toml as _toml

        class _TomlCompat:
            @staticmethod
            def loads(value):
                return _toml.loads(value)

        tomllib = _TomlCompat()

import yaml

hyprland_default = "/usr/share/bazzite-firebadnofire/hyprland.lua"
obsolete_hyprland_default = hyprland_default.removesuffix(".lua") + ".conf"
hyprland_source = Path(
    "system_files/usr/share/bazzite-firebadnofire/hyprland.lua"
).read_text(encoding="utf-8")
for required in (
    'local terminal = "foot"',
    'local menu = "fuzzel"',
    'hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal))',
    'hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(menu))',
):
    if required not in hyprland_source:
        raise ValueError(f"hyprland.lua: missing workstation contract: {required}")
if 'local terminal = "kitty"' in hyprland_source:
    raise ValueError("hyprland.lua: Kitty must not remain the default terminal")

if Path("system_files/usr/share/bazzite-firebadnofire/hyprland.conf").exists():
    raise ValueError("obsolete immutable Hyprland config is still shipped: hyprland.conf")

launcher_source = Path(
    "system_files/usr/libexec/bazzite-firebadnofire-start-hyprland"
).read_text(encoding="utf-8")
for managed_hash in (
    "5ec8d97af63d235777bee5d57e25f9716560379f9b72894e44bda8805b113f3d",
    "b1f3f2745e41db38865a50dced9ea91d6a80918ba5a3fceb2396c99a14a8567a",
    "663538eaf801c9340bfcc030adfc7f58ac1f09dda89367e03959226f6aa6d660",
):
    if managed_hash not in launcher_source:
        raise ValueError(
            "Hyprland launcher is missing a managed-default migration fingerprint: "
            f"{managed_hash}"
        )
for required in (
    "exec /usr/bin/start-hyprland\n",
    'exec /usr/bin/start-hyprland -- --config "${legacy_config}"',
):
    if required not in launcher_source:
        raise ValueError(
            "Hyprland launcher must hand off to the upstream start-hyprland wrapper: "
            f"{required.rstrip()}"
        )
if "exec /usr/bin/Hyprland" in launcher_source:
    raise ValueError("Hyprland launcher must not bypass start-hyprland")

desktop_source = Path(
    "system_files/usr/share/wayland-sessions/hyprland.desktop"
).read_text(encoding="utf-8")
for required in (
    "Exec=/usr/libexec/bazzite-firebadnofire-start-hyprland",
    "TryExec=/usr/bin/start-hyprland",
):
    if required not in desktop_source:
        raise ValueError(f"Hyprland desktop entry is missing: {required}")

build_source = Path("build_files/build.sh").read_text(encoding="utf-8")
for required in (
    "foot",
    "hyprland-guiutils",
    "test -x /usr/bin/foot",
    "test -x /usr/bin/start-hyprland",
    "test -x /usr/bin/hyprland-dialog",
    's/^NAME=.*/NAME="firebadnofire-bazzite"/',
    's/^PRETTY_NAME=.*/PRETTY_NAME="firebadnofire-bazzite"/',
    "grep -Fqx 'ID=bazzite' /etc/os-release",
    "grep -Fqx 'ID_LIKE=\"fedora\"' /etc/os-release",
):
    if required not in build_source:
        raise ValueError(f"build.sh: missing Hyprland runtime contract: {required}")

contract_sources = {
    "Justfile": Path("Justfile").read_text(encoding="utf-8"),
    ".forgejo/workflows/build.yml": Path(".forgejo/workflows/build.yml").read_text(
        encoding="utf-8"
    ),
}
for source_name, source_text in contract_sources.items():
    for required in (
        f"test -s {hyprland_default}",
        f"--config {hyprland_default}",
        "rpm -q foot ",
        "hyprland-guiutils",
        "test -x /usr/bin/foot",
        "test -x /usr/bin/start-hyprland",
        "test -x /usr/bin/hyprland-dialog",
        'test "$(readlink /etc/os-release)" = ../usr/lib/os-release',
        'grep -Fqx "NAME=\\"firebadnofire-bazzite\\"" /etc/os-release',
        'grep -Fqx "PRETTY_NAME=\\"firebadnofire-bazzite\\"" /etc/os-release',
        'grep -Fqx "ID=bazzite" /etc/os-release',
        'grep -Fqx "ID_LIKE=\\"fedora\\"" /etc/os-release',
        'grep -qx "TryExec=/usr/bin/start-hyprland"',
        "test -s /etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf",
        "pubcode.archuser.org/universalblue/bazzite-firebadnofire",
        "ghcr.io/firebadnofire/bazzite-firebadnofire",
    ):
        if required not in source_text:
            raise ValueError(
                f"{source_name}: image inspection must validate the shipped default: "
                f"{required}"
            )
    if obsolete_hyprland_default in source_text:
        raise ValueError(
            f"{source_name}: image inspection references obsolete immutable Hyprland "
            f"config: {obsolete_hyprland_default}"
        )

json.loads(
    Path("system_files/usr/share/bazzite-firebadnofire/waybar/config.jsonc").read_text(
        encoding="utf-8"
    )
)

for path in sorted(Path("disk_config").glob("*.toml")):
    tomllib.loads(path.read_text(encoding="utf-8"))

for path in sorted(Path(".forgejo/workflows").glob("*.yml")):
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    jobs = document.get("jobs", {})
    if not jobs:
        raise ValueError(f"{path}: workflow has no jobs")
    for job_name, job in jobs.items():
        if job.get("runs-on") != "ubuntu-22.04":
            raise ValueError(
                f"{path}: job {job_name!r} must target the available ubuntu-22.04 runner"
            )
        for index, step in enumerate(job.get("steps", []), start=1):
            script = step.get("run")
            if script is not None:
                subprocess.run(
                    ["bash", "-n"],
                    input=script,
                    text=True,
                    check=True,
                )
                subprocess.run(
                    ["shellcheck", "--shell=bash", "--exclude=SC1091", "-"],
                    input=script,
                    text=True,
                    check=True,
                )

image_workflow = Path(".forgejo/workflows/build.yml").read_text(encoding="utf-8")
for required in (
    'cron: "17 4 * * *"',
    "--format '{{json .Manifest}}'",
    "cosign verify --key cosign.pub",
    "GHCR_REGISTRY: ghcr.io",
    "GHCR_IMAGE_PATH: firebadnofire/bazzite-firebadnofire",
    'MIN_RUNNER_FREE_BYTES: "64424509440"',
    'MIN_PUBLISH_FREE_BYTES: "42949672960"',
    'report_publish_failure "publication storage preflight"',
    'local_image="localhost/${IMAGE_NAME}:ci-${GITHUB_RUN_ID}-${run_attempt}"',
    "source scripts/oci-publication.sh",
    "retry_once push_reference",
    "retry_once resolve_digest",
    "retry_once mirror_to_ghcr",
    "Job cgroup memory events",
    'for tag in "${TRACEABILITY_TAG}" "${IMMUTABLE_TAG}" stable',
    '[[ "${tag_digest}" != "${DIGEST}" ]]',
    'DOCKER_CONFIG="${anonymous_config}" docker buildx imagetools inspect',
):
    if required not in image_workflow:
        raise ValueError(f"build.yml: missing production contract: {required}")
if "--raw | sha256sum" in image_workflow:
    raise ValueError("build.yml: registry digest must not be reconstructed by hashing raw output")
for forbidden in ("docker system prune", "docker builder prune", "docker buildx prune"):
    if forbidden in image_workflow:
        raise ValueError(f"build.yml: run-local cleanup must not use broad pruning: {forbidden}")

image_document = yaml.safe_load(image_workflow)
if image_document["concurrency"].get("cancel-in-progress") is not False:
    raise ValueError("build.yml: an in-flight canonical publication must not be cancelled")
image_steps = {step["name"]: step for step in image_document["jobs"]["image"]["steps"]}
publication_steps = (
    "Log in to the Forgejo registry",
    "Push the commit traceability tag and resolve its canonical digest",
    "Install pinned Cosign",
    "Sign and verify the published digest",
    "Publish stream and immutable tags",
    "Mirror signed image to GHCR",
)
for step_name in publication_steps:
    if image_steps[step_name].get("if") != "github.event_name != 'pull_request'":
        raise ValueError(f"build.yml: {step_name} must publish for every non-PR event")
if image_steps["Log out of registries"].get("if") != (
    "always() && github.event_name != 'pull_request'"
):
    raise ValueError("build.yml: registry logout must always run after non-PR events")
cleanup_step = image_steps["Clean up this run's loaded image"]
if cleanup_step.get("if") != "always()":
    raise ValueError("build.yml: exact run-local image cleanup must always run")
cleanup_script = cleanup_step.get("run", "")
for required in (
    'docker image inspect "${LOCAL_IMAGE}"',
    '[[ "${reference_id}" != "${local_image_id}" ]]',
    "shared caches were not pruned",
):
    if required not in cleanup_script:
        raise ValueError(f"build.yml: run-local cleanup is missing: {required}")

mirror_step = image_steps["Mirror signed image to GHCR"]
mirror_environment = mirror_step.get("env", {})
if mirror_environment.get("GH_KEY") != "${{ secrets.GH_KEY }}":
    raise ValueError("build.yml: GHCR publication credentials must come from GH_KEY")
mirror_script = mirror_step.get("run", "")
for required in (
    '"${ghcr_image}@${DIGEST}"',
    "GHCR digest already has a valid Cosign signature",
    "make the package public in GitHub package settings",
):
    if required not in mirror_script:
        raise ValueError(f"build.yml: missing GHCR mirror contract: {required}")
if mirror_script.count("retry_once mirror_to_ghcr") != 1:
    raise ValueError("build.yml: GHCR mirror must invoke the two-attempt helper exactly once")
if image_workflow.count("${{ secrets.GH_KEY }}") != 1:
    raise ValueError("build.yml: GH_KEY must be exposed only to the GHCR mirror step")

image_step_order = [step["name"] for step in image_document["jobs"]["image"]["steps"]]
if not (
    image_step_order.index("Publish stream and immutable tags")
    < image_step_order.index("Mirror signed image to GHCR")
    < image_step_order.index("Clean up this run's loaded image")
    < image_step_order.index("Log out of registries")
):
    raise ValueError("build.yml: canonical publication, GHCR mirroring, cleanup, and logout are misordered")

logout_script = image_steps["Log out of registries"].get("run", "")
if 'for registry in "${IMAGE_REGISTRY}" "${GHCR_REGISTRY}"' not in logout_script:
    raise ValueError("build.yml: cleanup must log out of both OCI registries")

publication_helper = Path("scripts/oci-publication.sh").read_text(encoding="utf-8")
for required in (
    "docker push",
    "docker buildx imagetools inspect",
    "docker push returned status",
    "Docker daemon is not reachable from the job",
    "df -hT /",
    "df -ih /",
    "free -h",
    "/sys/fs/cgroup/memory.events",
    "getent ahosts",
    "Registry /v2/ unauthenticated HTTP status",
):
    if required not in publication_helper:
        raise ValueError(f"oci-publication.sh: missing fail-closed diagnostic: {required}")

disk_workflow = Path(".forgejo/workflows/build-disk.yml").read_text(encoding="utf-8")
for required in (
    "IMAGE_REPOSITORY}@${IMAGE_DIGEST}",
    "GPG_KEY_B64: ${{ secrets.GPG_KEY_B64 }}",
    "GPG_KEY_PASSWORD: ${{ secrets.GPG_KEY_PASSWORD }}",
    "bash scripts/sign-release-artifacts.sh release",
    "SHA256SUMS.asc",
    "bash scripts/disk-handoff.sh collect",
    "bash scripts/disk-handoff.sh cleanup",
    "both matrix builds must succeed before signing or publishing",
    "BIB_CACHE_VOLUME: bazzite-firebadnofire-bib-image-cache-v1",
    "flock --exclusive 9",
    "flock --shared 9",
    '"${BIB_CACHE_VOLUME}:/var/cache/bib-image-store:ro"',
    'build_source_image="localhost/bazzite-firebadnofire-build-source:cached"',
    'cp -a --reflink=always',
    'disk_config/ci-writable-storage.conf',
    'podman tag "${SOURCE_IMAGE}" "${BUILD_SOURCE_IMAGE}"',
    'podman images --filter readonly=false',
    'writable_image_ids_before',
    'existing_build_source_ids',
    'build_source_already_present',
    'writable_source_image_id',
    '"${cached_image_id}" == "${writable_image_id}"',
    '"${BUILD_SOURCE_IMAGE}"',
    "actions/forgejo-release@98265452477dafb3f0f27ba9c462c90b18cb44fd",
):
    if required not in disk_workflow:
        raise ValueError(f"build-disk.yml: missing release contract: {required}")

disk_document = yaml.safe_load(disk_workflow)
if "upload-artifact@" in disk_workflow or "download-artifact@" in disk_workflow:
    raise ValueError("build-disk.yml: disk payloads must not round-trip through Actions artifacts")
if 'cleanup_volume in "${output_volume}" "${storage_volume}" "${BIB_CACHE_VOLUME}"' in disk_workflow:
    raise ValueError("build-disk.yml: ordinary cleanup must not remove the persistent source cache")
storage_config = Path("disk_config/ci-storage.conf").read_text(encoding="utf-8")
for required in (
    'graphroot = "/var/lib/containers/storage"',
    'additionalimagestores = ["/var/cache/bib-image-store"]',
):
    if required not in storage_config:
        raise ValueError(f"ci-storage.conf: missing cache contract: {required}")
writable_storage_config = Path(
    "disk_config/ci-writable-storage.conf"
).read_text(encoding="utf-8")
if 'graphroot = "/var/lib/containers/storage"' not in writable_storage_config:
    raise ValueError("ci-writable-storage.conf: missing writable graphroot")
if "additionalimagestores" in writable_storage_config:
    raise ValueError(
        "ci-writable-storage.conf: builder must resolve only from its primary store"
    )
release = disk_document["jobs"]["release"]
if set(release["needs"]) != {"prepare", "disk"}:
    raise ValueError("build-disk.yml: release must depend on prepare and the whole disk matrix")
steps = release["steps"]
gate = next(i for i, step in enumerate(steps) if "disk-handoff.sh collect" in step.get("run", ""))
sign = next(i for i, step in enumerate(steps) if "sign-release-artifacts.sh" in step.get("run", ""))
publish = next(i for i, step in enumerate(steps) if "forgejo-release@" in step.get("uses", ""))
if not gate < sign < publish:
    raise ValueError("build-disk.yml: handoff verification must precede signing and publication")
if steps[gate].get("env", {}).get("DISK_RESULT") != "${{ needs.disk.result }}":
    raise ValueError("build-disk.yml: release must check the actual matrix result")
if '[[ "${DISK_RESULT}" == success ]]' not in steps[gate]["run"]:
    raise ValueError("build-disk.yml: failed matrix must block publication")
if steps[-1].get("if") != "${{ always() }}" or "disk-handoff.sh cleanup" not in steps[-1].get("run", ""):
    raise ValueError("build-disk.yml: final handoff cleanup must run on failures too")
privileged_job = yaml.safe_dump(disk_document["jobs"]["disk"])
if "secrets." in privileged_job:
    raise ValueError("build-disk.yml: privileged disk job must not receive secrets")
release_job = yaml.safe_dump(disk_document["jobs"]["release"])
for forbidden_secret in ("REGISTRY_TOKEN", "COSIGN_PRIVATE_KEY", "COSIGN_PASSWORD"):
    if forbidden_secret in release_job:
        raise ValueError(
            f"build-disk.yml: release job must not receive {forbidden_secret}"
        )

iso_workflow = Path(".forgejo/workflows/build-iso.yml").read_text(encoding="utf-8")
for required in (
    "workflow_dispatch:",
    "IMAGE_REPOSITORY}@${IMAGE_DIGEST}",
    "--type anaconda-iso",
    "disk_config/iso.toml",
    "output/bootiso/install.iso",
    "HANDOFF_FORMATS: iso",
    'build_source_image="localhost/bazzite-firebadnofire-build-source:cached"',
    'cp -a --reflink=always',
    'disk_config/ci-writable-storage.conf',
    'podman tag "${SOURCE_IMAGE}" "${BUILD_SOURCE_IMAGE}"',
    'podman images --filter readonly=false',
    'writable_image_ids_before',
    'existing_build_source_ids',
    'build_source_already_present',
    'writable_source_image_id',
    '"${cached_image_id}" == "${writable_image_id}"',
    '"${BUILD_SOURCE_IMAGE}"',
    "bash scripts/sign-release-artifacts.sh release sig",
    "GPG_KEY_B64: ${{ secrets.GPG_KEY_B64 }}",
    "GPG_KEY_PASSWORD: ${{ secrets.GPG_KEY_PASSWORD }}",
    '"${ISO_FILE}.sig"',
    "SHA256SUMS.sig",
    "unsigned release asset",
    "tag: iso-${{ steps.metadata.outputs.release_id }}",
    "actions/forgejo-release@98265452477dafb3f0f27ba9c462c90b18cb44fd",
):
    if required not in iso_workflow:
        raise ValueError(f"build-iso.yml: missing ISO release contract: {required}")
for forbidden in ("qcow2", ".asc", "matrix:"):
    if forbidden in iso_workflow:
        raise ValueError(f"build-iso.yml: forbidden ISO-only workflow content: {forbidden}")

iso_document = yaml.safe_load(iso_workflow)
if set(iso_document["jobs"]) != {"prepare", "iso", "release"}:
    raise ValueError("build-iso.yml: workflow must contain only prepare, iso, and release jobs")
if iso_document["jobs"]["iso"].get("strategy") is not None:
    raise ValueError("build-iso.yml: ISO job must not use a matrix")
if set(iso_document["jobs"]["release"]["needs"]) != {"prepare", "iso"}:
    raise ValueError("build-iso.yml: release must depend on prepare and the ISO build")
if "secrets." in yaml.safe_dump(iso_document["jobs"]["iso"]):
    raise ValueError("build-iso.yml: privileged ISO job must not receive secrets")
for workflow_name, workflow_text in (
    ("build-disk.yml", disk_workflow),
    ("build-iso.yml", iso_workflow),
):
    if "writable container storage is not empty before source promotion" in workflow_text:
        raise ValueError(
            f"{workflow_name}: initialized storage metadata must not block promotion"
        )
    if workflow_text.count('--env "BUILD_SOURCE_IMAGE=${build_source_image}"') < 2:
        raise ValueError(
            f"{workflow_name}: builder and diagnostics must receive the local source name"
        )
    if workflow_text.count('cp -a --reflink=always') != 1:
        raise ValueError(f"{workflow_name}: source promotion must occur exactly once")
    if workflow_text.count(
        'podman tag "${SOURCE_IMAGE}" "${BUILD_SOURCE_IMAGE}"'
    ) != 1:
        raise ValueError(f"{workflow_name}: deterministic local tag must occur exactly once")
    if workflow_text.count(
        'echo "Confirmed cached and writable-store image IDs match"'
    ) != 1:
        raise ValueError(f"{workflow_name}: exact image-ID match must be explicit")
    if 'bootc-image-builder \\\n' not in workflow_text or \
            '"${BUILD_SOURCE_IMAGE}"\n' not in workflow_text:
        raise ValueError(
            f"{workflow_name}: bootc-image-builder must use the writable local reference"
        )
    if '--use-librepo=true \\\n                "${SOURCE_IMAGE}"' in workflow_text:
        raise ValueError(
            f"{workflow_name}: bootc-image-builder must not receive the registry reference"
        )
iso_steps = iso_document["jobs"]["release"]["steps"]
iso_sign = next(
    i for i, step in enumerate(iso_steps)
    if "sign-release-artifacts.sh release sig" in step.get("run", "")
)
iso_complete = next(
    i for i, step in enumerate(iso_steps)
    if "unsigned release asset" in step.get("run", "")
)
iso_size_report = next(
    i for i, step in enumerate(iso_steps)
    if "Total upload size:" in step.get("run", "")
)
iso_publish = next(
    i for i, step in enumerate(iso_steps)
    if "forgejo-release@" in step.get("uses", "")
)
if not iso_sign < iso_complete < iso_size_report < iso_publish:
    raise ValueError(
        "build-iso.yml: signing, completeness, and size reporting must precede publication"
    )
if iso_size_report + 1 != iso_publish:
    raise ValueError("build-iso.yml: size reporting must run immediately before publication")
size_report_run = iso_steps[iso_size_report].get("run", "")
for required in ("stat --format='%s'", "numfmt --to=iec-i", "Upload asset:"):
    if required not in size_report_run:
        raise ValueError(
            f"build-iso.yml: upload-size report is missing required behavior: {required}"
        )
if iso_steps[-1].get("if") != "${{ always() }}" or \
        "disk-handoff.sh cleanup" not in iso_steps[-1].get("run", ""):
    raise ValueError("build-iso.yml: final ISO handoff cleanup must run on failures too")

net_workflow = Path(".forgejo/workflows/build-net.yml").read_text(encoding="utf-8")
for required in (
    "workflow_dispatch:",
    "IMAGE_REPOSITORY: pubcode.archuser.org/universalblue/bazzite-firebadnofire",
    "IMAGE_MIRROR: ghcr.io/firebadnofire/bazzite-firebadnofire",
    "bootc-generic-iso",
    "--file network-installer/Containerfile .",
    "HANDOFF_FORMATS: netiso",
    "bash scripts/disk-handoff.sh stage netiso",
    "Prove the ISO contains no workstation OCI payload",
    'xorriso -indev "${iso}" -find / -type f',
    'sed -e "s/^\x27//" -e "s/\x27$//"',
    "installer squashfs contains its own OSTree repository",
    "/LiveOS/squashfs.img",
    "usr/share/anaconda/interactive-defaults.ks",
    "0.5 GiB",
    "1 GiB",
    "bash scripts/sign-release-artifacts.sh release sig",
    "GPG_KEY_B64: ${{ secrets.GPG_KEY_B64 }}",
    "GPG_KEY_PASSWORD: ${{ secrets.GPG_KEY_PASSWORD }}",
    "GITHUB_RELEASE_TOKEN: ${{ secrets.GITHUB_RELEASE_TOKEN }}",
    "GITHUB_RELEASE_REPOSITORY: firebadnofire/bazzite-firebadnofire",
    "bash scripts/publish-github-release.sh release release-notes.md",
    "tag: netiso-${{ steps.metadata.outputs.release_id }}",
    "actions/forgejo-release@98265452477dafb3f0f27ba9c462c90b18cb44fd",
):
    if required not in net_workflow:
        raise ValueError(f"build-net.yml: missing network-installer contract: {required}")
for forbidden in ("--bootc-installer-payload-ref", "upload-artifact@", "download-artifact@"):
    if forbidden in net_workflow:
        raise ValueError(f"build-net.yml: forbidden embedded/artifact path: {forbidden}")

net_document = yaml.safe_load(net_workflow)
if set(net_document["jobs"]) != {"prepare", "netiso", "release"}:
    raise ValueError("build-net.yml: workflow must contain prepare, netiso, and release jobs")
if set(net_document["jobs"]["release"]["needs"]) != {"prepare", "netiso"}:
    raise ValueError("build-net.yml: release must depend on prepare and the network ISO build")
if "secrets." in yaml.safe_dump(net_document["jobs"]["netiso"]):
    raise ValueError("build-net.yml: privileged network ISO job must not receive secrets")
net_release_steps = net_document["jobs"]["release"]["steps"]
net_collect = next(
    i for i, step in enumerate(net_release_steps)
    if "disk-handoff.sh collect" in step.get("run", "")
)
net_sign = next(
    i for i, step in enumerate(net_release_steps)
    if "sign-release-artifacts.sh release sig" in step.get("run", "")
)
net_publish = next(
    i for i, step in enumerate(net_release_steps)
    if "forgejo-release@" in step.get("uses", "")
)
net_github_publish = next(
    i for i, step in enumerate(net_release_steps)
    if "publish-github-release.sh" in step.get("run", "")
)
if not net_collect < net_sign < net_publish < net_github_publish:
    raise ValueError("build-net.yml: handoff verification must precede signing and publication")
github_step = net_release_steps[net_github_publish]
if github_step.get("env", {}).get("GITHUB_RELEASE_TOKEN") != \
        "${{ secrets.GITHUB_RELEASE_TOKEN }}":
    raise ValueError("build-net.yml: GitHub release credentials must come from GITHUB_RELEASE_TOKEN")
if net_workflow.count("${{ secrets.GITHUB_RELEASE_TOKEN }}") != 1:
    raise ValueError("build-net.yml: GitHub release token must be exposed only to its mirror step")
if net_release_steps[-1].get("if") != "${{ always() }}" or \
        "disk-handoff.sh cleanup" not in net_release_steps[-1].get("run", ""):
    raise ValueError("build-net.yml: final network ISO handoff cleanup must always run")

installer_containerfile = Path("network-installer/Containerfile").read_text(encoding="utf-8")
for required in (
    "FROM quay.io/fedora/fedora-bootc:44@sha256:",
    "anaconda-core",
    "anaconda-tui",
    "dracut-network",
    "tmux",
    "'qemu-user-static*'",
    "/usr/lib/firmware",
    "/usr/share/locale/*",
    "/sysroot/ostree/repo",
    "test ! -e /sysroot/ostree/repo",
    "network-installer/iso.yaml /usr/lib/image-builder/bootc/iso.yaml",
    "network-installer/interactive-defaults.ks /usr/share/anaconda/interactive-defaults.ks",
):
    if required not in installer_containerfile:
        raise ValueError(f"network installer Containerfile is missing: {required}")
installer_iso = Path("network-installer/iso.yaml").read_text(encoding="utf-8")
for required in (
    "enforcing=0",
    "rd.plymouth=0 plymouth.enable=0",
):
    if required not in installer_iso:
        raise ValueError(f"network installer ISO configuration is missing: {required}")
kickstart = Path("network-installer/interactive-defaults.ks").read_text(encoding="utf-8")
for required in (
    "text",
    "network --bootproto=dhcp --device=link --activate --onboot=on",
    "bootc --source-imgref registry:pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable",
    "--target-imgref pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable",
):
    if required not in kickstart:
        raise ValueError(f"network installer kickstart is missing: {required}")
for destructive in ("clearpart", "autopart", "ignoredisk", "zerombr"):
    if destructive in kickstart:
        raise ValueError(f"network installer must stay interactive; found {destructive}")
yaml.safe_load(Path("network-installer/iso.yaml").read_text(encoding="utf-8"))
mirror_config = Path(
    "system_files/etc/containers/registries.conf.d/20-bazzite-firebadnofire-mirror.conf"
).read_text(encoding="utf-8")
tomllib.loads(mirror_config)
for required in (
    'prefix = "pubcode.archuser.org/universalblue/bazzite-firebadnofire"',
    'location = "ghcr.io/firebadnofire/bazzite-firebadnofire"',
    'location = "pubcode.archuser.org/universalblue/bazzite-firebadnofire"',
    'pull-from-mirror = "all"',
    "insecure = false",
):
    if required not in mirror_config:
        raise ValueError(f"registry failover configuration is missing: {required}")

github_release_helper = Path("scripts/publish-github-release.sh").read_text(encoding="utf-8")
for required in (
    "https://api.github.com",
    "https://uploads.github.com",
    "GITHUB_RELEASE_REPOSITORY",
    "draft:true",
    "draft:false",
    "((bytes < 2147483648))",
    "'.digest'",
    "'.assets | length'",
):
    if required not in github_release_helper:
        raise ValueError(f"publish-github-release.sh: missing fail-closed contract: {required}")

signing_helper = Path("scripts/sign-release-artifacts.sh").read_text(encoding="utf-8")
for required in (
    'readonly signature_extension="${2:-asc}"',
    "asc) readonly -a signature_format=(--armor)",
    "sig) readonly -a signature_format=()",
    'signature="${artifact}.${signature_extension}"',
    'gpg --batch --no-tty --verify "${signature}" "${artifact}"',
):
    if required not in signing_helper:
        raise ValueError(f"sign-release-artifacts.sh: missing signature-format contract: {required}")
PY

if rg --line-number \
    'image-template|alice-and-bob|ghcr\.io/ublue-os/image-template|ubuntu-26\.04' \
    .forgejo Containerfile Justfile bazzite-firebadnofire.env build_files disk_config system_files; then
    echo "error: template identity or unsupported runner reference remains" >&2
    exit 1
fi

grep -q '^FROM ghcr.io/ublue-os/bazzite-nvidia-open:stable@sha256:' Containerfile || {
    echo "error: Containerfile must pin the Bazzite NVIDIA-open base by digest" >&2
    exit 1
}
grep -q '^IMAGE_REGISTRY="pubcode.archuser.org"$' bazzite-firebadnofire.env || {
    echo "error: Forgejo registry identity is inconsistent" >&2
    exit 1
}
grep -q '^cosign\.key$' .gitignore || {
    echo "error: cosign.key must remain ignored" >&2
    exit 1
}

echo "static validation passed"
