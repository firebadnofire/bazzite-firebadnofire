# Hyprland verifier crash in image inspection

## Diagnosis

Run 148's supplied log shows `hyprland-0.57.0-2.fc44.x86_64` crashing after
`postConfigReload` disables stdout logging. The public run API was unavailable
during this investigation, so its complete logs and exact image were not
retrieved. The failure was reproduced locally in WSL/Podman by upgrading the
cached Bazzite-derived image's Hyprland and required dependencies from the
same GPG-checked COPR. No runner-host changes were made.

The cached image's `hyprland-0.56.2-3.fc44` passed root verification. With
`0.57.0-2.fc44`, both minimal Lua (a newline) and the custom config crash when
`/.socket2.sock` does not already exist. GDB reports:

```text
#0 add_source () from /usr/lib64/libwayland-server.so.0
#1 IPC::Socket2::CUnixImpl::CUnixImpl()
#2 IPC::Socket2::sock()
#3 Config::Lua::CConfigManager::postConfigReload()
#4 Config::Lua::CConfigManager::reload()
#5 CCompositor::initServer(...)
#6 main()
```

The upstream [0.57.0 config reload code](https://github.com/hyprwm/Hyprland/blob/v0.57.0/src/config/lua/ConfigManager.cpp)
calls `IPC::Socket2::sock()` at the end of `postConfigReload`. The
[Socket 2 constructor](https://github.com/hyprwm/Hyprland/blob/v0.57.0/src/ipc/s2/Unix.cpp)
binds `<instancePath>/.socket2.sock` and registers an event source against
`g_pCompositor->m_wlEventLoop`. In verification mode the instance path is empty
and that event loop is not initialized. A successful root-level bind therefore
reaches Wayland's `add_source` with no event loop.

A stale socket makes subsequent root runs misleadingly pass: bind fails before
event-source registration. Use a fresh disposable container for comparisons;
do not depend on a socket left behind by an earlier crash. This is an upstream
verifier initialization bug exposed by root execution, rather than evidence
of invalid workstation configuration, missing graphics hardware, or a broken
Forgejo runner. The exact remote image/library set remains unexamined.

## Scoped remediation and guarantees

Both inspection entrypoints invoke the same installed helper. Verification
runs as numeric UID/GID 65534, with groups/capabilities dropped and
`no-new-privs`. Root-level socket creation is denied, so 0.57.0 returns from
the constructor before touching the missing event loop. The expected IPC
diagnostic is visible; no exit status is converted from failure to success.
This does not modify the Lua configuration, compositor binary, or runtime
session launcher. It does not require a compositor, GPU, privileged inspection
container, system D-Bus, or a running graphical session.

The real Hyprland parser checks the shipped config's Lua and registered options.
Every inspection also checks a valid control, invalid Lua, and an invalid
option type. A parser that crashes or stops rejecting errors blocks publication.
Exit zero alone is insufficient: an exact `config ok` line is required.
Controls are not a replacement for the shipped configuration's own validation.
There is no version-wide allowance for exit 139 or fallback to syntax-only
validation. Future versions run the same parser and controls and fail closed.

The workaround is specifically motivated and tested by the 0.57.0 RPM above.
Least-privilege verification can remain with newer versions. Once upstream
guards IPC construction in verification mode, test a fresh container with the
new RPM: minimal, upstream sample, and custom configs must pass; syntax and
semantic errors must fail, without IPC initialization warnings. Then remove
the version-specific warning/documentation. Do not remove the negative controls
or restore root execution merely because the package version changed.

## Reproducing and diagnosing

In a disposable container with the affected RPM and GDB installed, root can
reproduce the original crash with:

```bash
export XDG_RUNTIME_DIR="$(mktemp -d)"
gdb -q -batch -ex run -ex 'thread apply all bt' --args \
  Hyprland --verify-config --i-am-really-stupid \
  --config /usr/share/bazzite-firebadnofire/hyprland.lua
```

The fixed path is:

```bash
/usr/libexec/bazzite-firebadnofire-verify-hyprland
```

For an unexpected crash of the fixed path, reproduce GDB with the same
unprivileged UID, private writable home and mode-0700 runtime directory used
by the helper. Container ptrace restrictions may limit GDB; do not change the
production runner's security configuration to obtain a trace. CI retains
stdout/stderr as an artifact; raw core dumps and user/session data are not
uploaded. Artifact upload itself still needs validation on Forgejo.

## Validation performed for this change

- Repository static gate passed in a Linux-filesystem mirror with checkout
  CRLF normalized there: Bash syntax, ShellCheck, YAML/TOML parsing, workflow
  shell checks, publication regression checks, and verifier policy tests.
- The complete image-contract shell body from the modified workflow passed in
  the disposable upgraded container with the current system overlay; bootc
  reported 13 checks passed and one skipped. Reproduction-only DNF caches,
  logs, and temporary files were removed before lint, matching the production
  build's temporary mounts. This was not a fresh production Containerfile build.
- The real helper passed on 0.57.0-2.fc44 and the cached 0.56.2-3.fc44 image.
  On 0.57.0 it rejected supplied invalid Lua, invalid option types, unknown
  options, and missing files. It created no root-level IPC socket.
- Policy tests additionally reject simulated SIGSEGV, timeout, missing-library
  status, zero status without `config ok`, and a verifier accepting bad controls.
- No Forgejo run was dispatched, no image was published or signed, and no VM
  or physical desktop was booted. The uploader's source pin was retrieved, but
  actual Forgejo artifact transport remains untested.
