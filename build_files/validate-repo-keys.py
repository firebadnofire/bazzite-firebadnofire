#!/usr/bin/python3
"""Check enabled on-disk repos, conservatively ignoring DNF5 disable overrides."""

import configparser
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def validate(repos, variables):
    checked = 0
    for path in sorted(repos.glob("*.repo")):
        config = configparser.ConfigParser(interpolation=None)
        config.read_string(path.read_text(), source=str(path))
        for name in config.sections():
            repo = config[name]
            if not repo.getboolean("enabled", fallback=True):
                continue
            for url in re.split(r"[\s,]+", repo.get("gpgkey", "").strip()):
                if not url.startswith("file:"):
                    continue
                def expand(match):
                    key = match[1] or match[2]
                    if key not in variables:
                        raise ValueError(f"{path} [{name}]: unknown variable {key}")
                    return variables[key]
                expanded = re.sub(r"\$\{(\w+)\}|\$(\w+)", expand, url)
                parsed = urlsplit(expanded)
                key = Path(unquote(parsed.path))
                if (parsed.netloc not in ("", "localhost") or not key.is_absolute()
                        or not key.is_file() or not os.access(key, os.R_OK)
                        or key.stat().st_size == 0):
                    raise ValueError(f"{path} [{name}]: missing/unreadable local GPG key: {expanded}")
                checked += 1
    return checked


def main():
    # This image is Fedora x86_64; query RPM rather than the build host's OS.
    releasever = subprocess.check_output(["rpm", "--eval", "%{fedora}"], text=True).strip()
    arch = subprocess.check_output(["rpm", "--eval", "%{_arch}"], text=True).strip()
    variables = {"releasever": releasever, "releasever_major": releasever.split(".")[0],
                 "releasever_minor": releasever.partition(".")[2], "basearch": arch, "arch": arch}
    for directory in ("/etc/yum/vars", "/etc/dnf/vars"):
        for path in sorted(Path(directory).glob("*")):
            if path.is_file():
                variables[path.name] = path.read_text().partition("\n")[0].strip()
    count = validate(Path("/etc/yum.repos.d"), variables)
    print(f"Repository GPG key validation passed ({count} local references)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, configparser.Error) as error:
        sys.exit(f"error: {error}")
