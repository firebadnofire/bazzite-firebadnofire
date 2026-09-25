# Single-GPU NVIDIA handoff

The image ships an adaptation of RisingPrism's single-GPU handoff. It applies
only to system libvirt (`qemu:///system`) guests whose names end in the exact,
case-sensitive suffix `-gpu`. The host must have exactly one NVIDIA display-class
PCI device, supported by the image's NVIDIA-open driver. Multi-GPU setups, AMD,
migration, external QEMU attachment, and saved-state restoration of GPU guests
are not supported by this integration.

Starting a GPU guest **ends the local graphical session and its applications**.
Shutdown restores the recorded GPU/driver resources and returns to the login
screen if the display manager was originally active. It does not preserve a
locked desktop. Save work first. An unrelated compute workload causes handoff
to fail; the scripts do not kill it. Other PCI passthrough workloads may prevent
recovery: open VFIO/iommufd handles are deliberately treated conservatively.

## Deployment and prerequisites

The implementation is in `/usr/libexec/bazzite-firebadnofire-vfio/v1/`, behind the
stable `/usr/libexec/bazzite-firebadnofire-vfio-run` entrypoint. The small adapter
is `/etc/libvirt/hooks/qemu.d/90-bazzite-firebadnofire-vfio`. Units and the
adapter's reference copy are image-managed. There is no first-boot download or
runtime installation of scripts. Fedora 44's modular `virtqemud.service` and
supporting sockets are enabled; conflicting legacy `libvirtd` defaults are
disabled in the image. The QEMU hook ABI and `qemu:///system` URI are unchanged.
No service is restarted on a running workstation by image construction. Local
systemd customizations are subject to the same bootc `/etc` merge behavior and
must be reconciled if the activation check fails after reboot. The journal is root-only under
`/var/lib/bazzite-firebadnofire/vfio`; the mutex and activation probe receipts
are under `/run/bazzite-firebadnofire-vfio`.

Before use:

1. Enable virtualization/IOMMU in firmware and configure any necessary
   machine-specific kernel arguments using the supported Bazzite procedure.
   Verify actual IOMMU groups. Do not add universal `vfio-pci.ids` bindings or
   blacklist NVIDIA: the GPU must initially belong to the host NVIDIA driver.
2. Configure each GPU guest's PCI host devices explicitly in virt-manager or
   domain XML, with `managed='yes'`. Include **every PCI function of the GPU's
   slot**, such as HDMI audio and USB controllers. The helper rejects IOMMU
   groups containing unrelated non-bridge devices. Guest drivers, optional ROMs,
   USB input, and guest firmware remain the operator's responsibility.
3. Ensure administrative access from SSH or another recovery route. Libvirt
   authorization is privileged: naming a VM `-gpu` authorizes disruptive host
   handoff for anyone already allowed to start that system VM.
4. Deploy the image with the README's bootc update procedure and reboot. Do not
   restart libvirt to discover newly installed hooks while guests are running.
5. On the booted deployment run:

   ```bash
   sudo /usr/libexec/bazzite-firebadnofire-vfio-run check-deployment
   sudo vfio-host-check
   systemctl is-enabled bazzite-firebadnofire-vfio-reconcile.timer
   ```

`vfio-host-check` proves that **the running daemon executes the adapter**. It
requests a randomly named, diskless transient probe, whose prepare hook records
a receipt and deliberately rejects startup. It never requests PCI devices or
restarts libvirt. If no hook executes and QEMU does start, the probe is paused
and the command removes only that newly generated transient guest. An error or
missing receipt is a failed activation test, not success based on file presence.
If probe cleanup itself fails, the error identifies the generated UUID; inspect
and remove that paused probe before retrying.

Bootc performs a three-way merge of `/etc`. A locally edited adapter will not
necessarily update. Comment-only edits remain compatible; executable changes
are preserved but fail the deployment check. Compare against
`/usr/share/bazzite-firebadnofire/vfio/adapter`, back up local edits, and reconcile
them manually. Do not run the upstream `install_hooks.sh` alongside this
integration. Existing RisingPrism or duplicate project adapters are diagnosed;
unrelated hooks retain their names and relative order. Do not rename/copy this
adapter to add another invocation. Arbitrary locally written hooks remain the
operator's responsibility.

## Operating guests

For correctly configured guests:

```bash
sudo virsh -c qemu:///system start debian1
sudo virsh -c qemu:///system start debian-gpu
# While debian-gpu owns the GPU, this fails with an ownership error:
sudo virsh -c qemu:///system start debian2-gpu
sudo virsh -c qemu:///system shutdown debian-gpu
# Wait for shutdown and verified host restoration, then:
sudo virsh -c qemu:///system start debian2-gpu
```

Normal guests receive no handoff actions. The suffix is an operational
convention, not a security boundary against someone assigning PCI devices
manually outside this integration. Guest reboot does not release ownership.
Forced poweroff and failed startup use the same release path; prefer orderly
shutdown because forced poweroff can lose guest data.

One UUID owns the GPU throughout preparation, guest execution, and restoration.
A rejected competing guest's release callback cannot restore the current owner's
GPU. Prepare failures roll back immediately. Failures after prepare wait for
libvirt's resource release or guarded independent recovery. Recovery never treats
a timeout or missing callback alone as proof that devices are free.

The helper consumes supplied XML and never emits XML or diagnostics on stdout.
For libvirt's filter-capable calls, empty output preserves upstream hook output.
Prepare/start hooks do not edit VM XML through stdout. No hook calls libvirt APIs
or `virsh`; doing that can deadlock the daemon.

### GPU holder diagnostics

`GPU device held by PID ... (fd ...)` identifies a real device descriptor that
blocks preparation. Metadata-only `O_PATH` descriptors are ignored because they
do not open the device driver; PID 1 is otherwise subject to the same checks as
all processes. Do not stop PID 1 or bypass the workload check. Inspect the reported
descriptor with `sudo readlink /proc/PID/fd/FD` and
`sudo cat /proc/PID/fdinfo/FD`, substituting the reported numbers.
Older images can incorrectly report metadata-only descriptors as GPU workloads.
Deploy an image containing the corrected helper through bootc and reboot before
retrying; changing the stable `/etc` adapter is unnecessary.

## Inhibition, daemon restarts, and recovery

The inhibitor service acquires a logind **sleep/block** file descriptor and
signals readiness only after acquisition. Preparation additionally checks
`ListInhibitors` against the service's PID. The service holds the descriptor
independently of hook lifetime and restarts after a crash. The reconciliation
timer checks every 15 seconds after each check finishes, including unexpected
service stops. A process crash creates a possible protection gap until restart;
privileged forced sleep can bypass inhibition. Neither is claimed to be covered
by an uninterrupted guarantee.

Reconnect never repeats host preparation and returns success even if state is
missing or contradictory: libvirt can kill a guest when a reconnect hook fails.
It records unresolved claims, blocks new acquisition, and attempts to restore
inhibition. The adapter also shields a missing/failed helper during reconnect.
Unrelated local hooks can still fail their own reconnect calls.

Inspect from SSH or a TTY:

```bash
sudo vfio-host-recover --status
sudo journalctl -b -u virtqemud -u libvirtd -u bazzite-firebadnofire-vfio-reconcile \
  -u bazzite-firebadnofire-vfio-inhibit
sudo virsh -c qemu:///system list --all
sudo virsh -c qemu:///system dumpxml debian-gpu
sudo lspci -nnk
```

After the owning guest has stopped:

```bash
sudo vfio-host-recover
```

The timer and manual command use the same guarded recovery code. It requires a
successful system-libvirt query, no relevant active domain, no possible orphan
GPU QEMU process, and no open VFIO/IOMMU device handles. It then reacquires the
mutex and compares UUID, generation/revision, boot ID, reconnect claims, and PCI
bindings before restoring. An unavailable daemon or inaccessible process state
is **unknown ownership** and refuses restoration. The helper never force-stops
a guest or runs a libvirt query while holding a lock needed by a hook.

Recovery is repeatable. Restoration reloads only recorded, changed modules and
services, checks resulting PCI bindings and resource state, and starts the
display manager last. Failed restoration retains ownership and inhibition.
Exit codes are `0` healthy/recovered, `1` operation failed/incomplete, `2`
unsafe or indeterminate ownership, and `3` invalid invocation. `--status` is
read-only and reports records/bindings; it does not certify guest inactivity.

A previous-boot journal is historical: **no old restoration action is replayed**.
It can be retired only after successful live guest checks and verification that
the current GPU is NVIDIA-bound, `nvidia-smi` succeeds, and the display manager
is active. Unresolved previous-boot records stay intact. Missing original state
on the same boot requires manual investigation and usually a clean reboot after
stopping guests; it is not reconstructed from guesses.

If recovery fails:

1. Save the status, journal, `lspci -nnk`, and guest state for diagnosis.
2. Establish whether the owning guest is running, using libvirt **outside** hooks.
   If the daemon is unavailable, restore its availability or use the normal host
   reboot procedure after accounting for all guest workloads. Do not equate a
   failed query with an inactive guest.
3. Stop the owning guest normally and retry recovery. Resolve compute/device
   holders explicitly; recovery will not kill them.
4. If driver reset/reload or framebuffer restoration remains impossible, reboot
   the host through the normal operator recovery procedure. After reboot, run
   the status, recovery, and activation checks again. A hardware fault or
   unsupported GPU reset may require a power cycle.

Never delete an ownership journal or manually unbind/rebind PCI devices merely
to force a second VM to start. Unknown/corrupt journal formats require manual
inspection; there is intentionally no `--force` option.

## Validation and remaining hardware requirements

`just validate` runs unprivileged mocked lifecycle/deployment tests. They never
execute the production hardware backend. Image builds verify the adapter,
entrypoint, Python D-Bus dependency, units, licenses, and the bootc container
contract. After building, run the optional real-daemon integration test:

```bash
bash scripts/test-vfio-container.sh localhost/bazzite-firebadnofire:vfio-test
```

It runs the built image in a disposable rootless Podman container, starts system
libvirt there, and verifies adapter execution alongside an existing hook and a
comment-modified adapter. It exposes KVM when available but never exposes host
GPUs or the host libvirt socket. This tests real hook execution, not bootc's
three-way merge, systemd boot, or the deployed host's SELinux domain. None of
these tests demonstrates physical GPU reset or reattachment.

Before treating a release as hardware-tested, record these distinct results:

- **Static/mocked:** syntax, journal/failure injection, reconnect, locking,
  XML interoperability, inhibitor/recovery, and adapter compatibility tests.
- **Built:** full OCI build, image inspection, and `bootc container lint`.
- **Booted:** update from the previous image; check stock and locally modified
  `/etc` adapters, unrelated hooks, duplicate detection, and `vfio-host-check`
  against the actual running daemon. Repeat after rollback. Keep SELinux enforcing
  and inspect AVC denials; never substitute permissive mode for this test.
- **Physical hardware:** with `debian1` running, start `debian-gpu`, verify GPU
  operation in the guest, reject `debian2-gpu`, shut down the owner, verify host
  login and NVIDIA acceleration, then start `debian2-gpu`. Repeat with forced
  shutdown, QEMU startup failure, a later hook's startup failure, and libvirt
  daemon restart while the GPU guest remains running. On a dedicated test host,
  exercise inhibitor failures and interrupted reboots during preparation,
  ownership, and restoration.

The checked upstream lifecycle is libvirt 12.0.0; in that implementation PCI
reattachment precedes `release/end` and the transition to inactive state. The
image build records installed package versions. The Fedora policy normally
labels `/etc/libvirt/hooks` as `virt_hook_t`; that is not proof that every sysfs,
module, process-inspection, or systemd operation is permitted. Enforcing-policy
execution, graphical-session teardown, kernel framebuffer behavior, IOMMU
isolation, NVIDIA module combinations, and GPU reset/rebind remain deployment
and physical-hardware acceptance gates. No blanket SELinux exceptions are added.

## Attribution and reference behavior

Based on [RisingPrism single-gpu-passthrough](https://gitlab.com/risingprismtv/single-gpu-passthrough)
commit `fa22cf6c0a5f5aba0c2fbb8c888a6821ad7154d3` and its supplied wiki.
Credits: RisingPrism, Lily (PixelQubed), Void, .Chris., WORMS, and the VFIO
community. The adapted components use GPL-3.0-only; the image ships `COPYING`
and `NOTICE` under `/usr/share/licenses/bazzite-firebadnofire-vfio/`.

See [libvirt hooks](https://libvirt.org/hooks.html), the
[libvirt 12 hook runner](https://github.com/libvirt/libvirt/blob/v12.0.0/src/util/virhook.c),
[QEMU lifecycle](https://github.com/libvirt/libvirt/blob/v12.0.0/src/qemu/qemu_process.c),
and [bootc filesystem semantics](https://bootc.dev/bootc/filesystem.html).
