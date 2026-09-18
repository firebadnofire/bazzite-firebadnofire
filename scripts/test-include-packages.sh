#!/usr/bin/bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
readonly helper="${root}/build_files/include-packages.sh"

workdir="$(mktemp -d)"
readonly workdir
trap 'rm -rf -- "${workdir}"' EXIT

mkdir -p "${workdir}/bin"

cat > "${workdir}/bin/dnf5" <<'EOF'
#!/usr/bin/bash
set -Eeuo pipefail
printf '%s\n' "$@" > "${DNF_LOG:?}"
for argument in "$@"; do
    if [[ "${argument}" == "package-that-does-not-exist" ]]; then
        echo "error: no matching package: ${argument}" >&2
        exit 42
    fi
done
EOF

cat > "${workdir}/bin/rpm" <<'EOF'
#!/usr/bin/bash
set -Eeuo pipefail
printf '%s\n' "$@" >> "${RPM_LOG:?}"
EOF

chmod 0755 "${workdir}/bin/dnf5" "${workdir}/bin/rpm"

export PATH="${workdir}/bin:${PATH}"
export DNF_LOG="${workdir}/dnf.log"
export RPM_LOG="${workdir}/rpm.log"

cat > "${workdir}/normal.txt" <<'EOF'
alpha

    # An indented comment is ignored.
 beta-package  
	
gamma_package
EOF

"${helper}" install "${workdir}/normal.txt"

cat > "${workdir}/expected-dnf.log" <<'EOF'
-y
install
alpha
beta-package
gamma_package
EOF
diff -u "${workdir}/expected-dnf.log" "${DNF_LOG}"

cat > "${workdir}/expected-rpm.log" <<'EOF'
-q
--whatprovides
alpha
-q
--whatprovides
beta-package
-q
--whatprovides
gamma_package
EOF
diff -u "${workdir}/expected-rpm.log" "${RPM_LOG}"

: > "${workdir}/empty.txt"
rm -f -- "${DNF_LOG}" "${RPM_LOG}"
"${helper}" install "${workdir}/empty.txt"
[[ ! -e "${DNF_LOG}" && ! -e "${RPM_LOG}" ]] || {
    echo "error: an empty include file invoked the package manager" >&2
    exit 1
}

printf '%s\n' 'package-that-does-not-exist' > "${workdir}/invalid.txt"
if "${helper}" install "${workdir}/invalid.txt"; then
    echo "error: an unresolvable package did not fail installation" >&2
    exit 1
fi
[[ ! -e "${RPM_LOG}" ]] || {
    echo "error: package verification ran after installation failed" >&2
    exit 1
}

printf '%s\n' 'two packages' > "${workdir}/malformed.txt"
if "${helper}" install "${workdir}/malformed.txt"; then
    echo "error: multiple package names on one line were accepted" >&2
    exit 1
fi

echo "include package tests passed"
