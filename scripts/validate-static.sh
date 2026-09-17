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

bash -n \
    build_files/build.sh \
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
    build_files/build.sh \
    scripts/validate-static.sh \
    system_files/usr/libexec/bazzite-firebadnofire-screenshot \
    system_files/usr/libexec/bazzite-firebadnofire-start-hyprland

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
