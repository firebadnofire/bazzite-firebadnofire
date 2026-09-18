#!/usr/bin/bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
cd "${root}"

required_files=(
    bazzite-firebadnofire.env
    cosign.pub
    disk_config/disk.toml
    disk_config/iso.toml
    scripts/sign-release-artifacts.sh
    system_files/usr/lib/tmpfiles.d/bazzite-firebadnofire.conf
    system_files/usr/share/bazzite-firebadnofire/hyprland.lua
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
    scripts/sign-release-artifacts.sh \
    scripts/validate-static.sh \
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
    scripts/sign-release-artifacts.sh \
    scripts/validate-static.sh \
    system_files/usr/libexec/bazzite-firebadnofire-screenshot \
    system_files/usr/libexec/bazzite-firebadnofire-start-hyprland

PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-repo-keys.py
bash scripts/test-include-packages.sh

python3 - <<'PY'
from pathlib import Path
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
    "github.event_name == 'schedule'",
    "--format '{{json .Manifest}}'",
    "cosign verify --key cosign.pub",
):
    if required not in image_workflow:
        raise ValueError(f"build.yml: missing production contract: {required}")
if "--raw | sha256sum" in image_workflow:
    raise ValueError("build.yml: registry digest must not be reconstructed by hashing raw output")

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
    "actions/forgejo-release@98265452477dafb3f0f27ba9c462c90b18cb44fd",
):
    if required not in disk_workflow:
        raise ValueError(f"build-disk.yml: missing release contract: {required}")

disk_document = yaml.safe_load(disk_workflow)
if "upload-artifact@" in disk_workflow or "download-artifact@" in disk_workflow:
    raise ValueError("build-disk.yml: disk payloads must not round-trip through Actions artifacts")
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
