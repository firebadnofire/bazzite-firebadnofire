#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-only
# Adapted from risingprismtv/single-gpu-passthrough, fa22cf6c0a5f5aba0c2fbb8c888a6821ad7154d3.
# Original handoff sequence: RisingPrism and Lily (PixelQubed); see NOTICE.
# 2026 bazzite-firebadnofire: transactional state, recovery, NVIDIA-only backend.
"""Privileged single-GPU handoff. No environment-controlled paths or shell commands.

Backend injection is exclusively a Python test interface. Hooks never query libvirt.
Only recover() queries libvirt, outside both hook execution and the state mutex.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

BASE = Path('/var/lib/bazzite-firebadnofire/vfio')
RUN = Path('/run/bazzite-firebadnofire-vfio')
ADAPTER = Path('/etc/libvirt/hooks/qemu.d/90-bazzite-firebadnofire-vfio')
TEMPLATE = Path('/usr/share/bazzite-firebadnofire/vfio/adapter')
INHIBITOR = 'bazzite-firebadnofire-vfio-inhibit.service'
WHO = 'bazzite-firebadnofire-vfio'
PCI = re.compile(r'^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$')


class Failure(Exception):
    code = 1


class Unsafe(Failure):
    code = 2


def log(message):
    print(f'vfio: {message}', file=sys.stderr, flush=True)


def domain(data, name=None):
    if len(data) > 1024 * 1024 or b'<!DOCTYPE' in data or b'<!ENTITY' in data:
        raise Unsafe('oversized XML or DTD/entity declaration')
    try:
        root = ET.fromstring(data)
        ident = str(uuid.UUID(root.findtext('uuid', '')))
        actual = root.findtext('name', '')
        if root.tag != 'domain' or not actual or (name is not None and actual != name):
            raise ValueError('domain name mismatch')
        devices = {}
        for node in root.findall('./devices/hostdev'):
            if node.get('type') != 'pci':
                continue
            address = node.find('./source/address')
            if address is None:
                raise ValueError('missing PCI source')
            fields = [int(address.get(k, ''), 0) for k in ('domain', 'bus', 'slot', 'function')]
            if any(v < 0 or v > limit for v, limit in zip(fields, (65535, 255, 31, 7))):
                raise ValueError('PCI source out of range')
            bdf = '%04x:%02x:%02x.%x' % tuple(fields)
            if bdf in devices:
                raise ValueError('duplicate PCI source')
            devices[bdf] = node.get('managed') == 'yes'
        return {'uuid': ident, 'name': actual, 'devices': devices}
    except (ET.ParseError, ValueError, TypeError) as exc:
        raise Unsafe(f'invalid domain XML: {exc}') from exc


class Store:
    def __init__(self, base=BASE, run=RUN):
        self.base, self.run = Path(base), Path(run)

    def init(self):
        for directory in (self.base, self.run):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            if directory.is_symlink() or directory.stat().st_uid != os.geteuid():
                raise Unsafe(f'unsafe state directory {directory}')
            if directory.stat().st_mode & 0o077:
                raise Unsafe(f'state directory must be private: {directory}')

    @contextlib.contextmanager
    def lock(self):
        self.init()
        with (self.run / 'lock').open('a') as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise Unsafe('another VFIO transition is in progress; retry later') from exc
            yield

    def write(self, name, value):
        self.init()
        with tempfile.NamedTemporaryFile(mode='w', dir=self.base, prefix='.' + name, delete=False) as stream:
            tmp = Path(stream.name)
            try:
                json.dump(value, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            except BaseException:
                tmp.unlink(missing_ok=True)
                raise
        try:
            tmp.replace(self.base / name)
            self.sync()
        finally:
            tmp.unlink(missing_ok=True)

    def sync(self):
        fd = os.open(self.base, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def load(self):
        try:
            state = json.loads((self.base / 'owner.json').read_text())
            if state['schema'] != 1 or state['phase'] not in (
                    'preparing', 'prepared', 'running', 'restoring', 'recovery-required'):
                raise ValueError('unknown schema/phase')
            uuid.UUID(state['uuid'])
            uuid.UUID(state['generation'])
            uuid.UUID(state['boot'])
            if not isinstance(state['actions'], list) or not isinstance(state['snapshot'], dict):
                raise ValueError('invalid journal')
            snap = state['snapshot']
            if not snap['devices'] or any(not PCI.fullmatch(bdf) for bdf in snap['devices']):
                raise ValueError('invalid device journal')
            if any(driver is not None and not re.fullmatch(r'[A-Za-z0-9_-]+', driver)
                   for driver in snap['devices'].values()):
                raise ValueError('invalid PCI driver journal')
            if any(not re.fullmatch(r'[A-Za-z0-9_-]*', value) for value in snap.get('overrides', {}).values()):
                raise ValueError('invalid PCI override journal')
            if any(not re.fullmatch(r'[A-Za-z0-9_-]+', m) for m in snap['modules']):
                raise ValueError('invalid module journal')
            for action in state['actions']:
                kind, value = action['kind'], action['value']
                if kind == 'module' and value in snap['modules']:
                    continue
                if kind == 'service' and value in snap['services'] + ['display-manager.service']:
                    continue
                if kind == 'console' and value in snap['consoles'] and re.fullmatch(r'/sys/class/vtconsole/vtcon[0-9]+/bind', value):
                    continue
                if kind == 'frame' and value in snap['frames'] and value['driver'] in ('efi-framebuffer', 'simple-framebuffer') and re.fullmatch(r'[A-Za-z0-9_.:-]+', value['device']):
                    continue
                if (kind == 'desktop-unit' and value in snap.get('desktop_units', [])
                        and re.fullmatch(r'[0-9]+', value['uid'])
                        and re.fullmatch(r'[A-Za-z0-9_@.\\:-]+\.(service|scope)', value['unit'])):
                    continue
                if (kind == 'user-manager' and value in snap.get('user_managers', [])
                        and re.fullmatch(r'[0-9]+', value)):
                    continue
                if kind == 'session' and value in [x['id'] for x in snap['sessions']]:
                    continue
                raise ValueError('invalid action journal')
            return state
        except FileNotFoundError:
            return None
        except (ValueError, KeyError, TypeError) as exc:
            raise Unsafe('invalid ownership journal; inspect it before manual recovery') from exc

    def save(self, state):
        state['revision'] = state.get('revision', 0) + 1
        self.write('owner.json', state)

    def claims(self):
        return list(self.base.glob('claim-*.json'))

    def claim(self, ident, reason, kind='reconnect'):
        # Independent files permit a nonfatal reconnect to quarantine even if
        # another transition owns the mutex. Never erase another UUID's claim.
        try:
            ident = str(uuid.UUID(ident))
        except ValueError:
            ident = 'unknown'
        self.write(f'claim-{ident}.json', {'uuid': ident, 'reason': reason, 'kind': kind, 'boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip()})

    def clear(self):
        (self.base / 'owner.json').unlink(missing_ok=True)
        for path in self.claims():
            path.unlink()
        self.sync()


def deployment_check(adapter=ADAPTER, template=TEMPLATE):
    """Recognize the stable ABI, allowing comments/blank-line local edits only."""
    def content(path):
        return '\n'.join(line.strip() for line in path.read_text().splitlines()
                         if line.strip() and not line.lstrip().startswith('#'))
    if not adapter.is_file() or not os.access(adapter, os.X_OK) or content(adapter) != content(template):
        raise Unsafe('missing/incompatible VFIO adapter; compare it with ' + str(template))
    for path in adapter.parent.parent.rglob('*'):
        if path == adapter or not path.is_file() or not os.access(path, os.X_OK):
            continue
        text = path.read_text(errors='replace')
        if 'bazzite-firebadnofire-vfio' in text or re.search(r'vfio-(startup|teardown)', text):
            raise Unsafe(f'conflicting VFIO hook {path}; reconcile local hooks before starting')


class Host:
    pci = Path('/sys/bus/pci/devices')

    def command(self, *args, timeout=30):
        try:
            result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=timeout, check=False,
                                    env={'PATH': '/usr/sbin:/usr/bin', 'LC_ALL': 'C'})
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Failure(f'{args[0]}: {exc}') from exc
        if result.returncode:
            raise Failure(f'{" ".join(args)}: {result.stderr.strip() or result.stdout.strip()}')
        return result.stdout.strip()

    def boot(self):
        return Path('/proc/sys/kernel/random/boot_id').read_text().strip()

    def binding(self, bdf):
        path = self.pci / bdf / 'driver'
        return path.resolve().name if path.exists() else None

    def bindings(self, devices):
        return {bdf: self.binding(bdf) for bdf in devices}

    def active(self, service):
        value = self.command('systemctl', 'show', service, '-p', 'ActiveState', '--value')
        if value in ('activating', 'deactivating', 'reloading'):
            raise Unsafe(f'{service} is transitioning')
        return value == 'active'

    def wait(self, predicate, message, seconds=10):
        end = time.monotonic() + seconds
        while not predicate():
            if time.monotonic() >= end:
                raise Failure(message)
            time.sleep(0.1)

    def sessions(self):
        answer = []
        for line in self.command('loginctl', 'list-sessions', '--no-legend', '--no-pager').splitlines():
            ident = line.split()[0]
            props = dict(line.split('=', 1) for line in self.command(
                'loginctl', 'show-session', ident, '-p', 'Type', '-p', 'Remote', '-p', 'Scope', '-p', 'User').splitlines())
            if props.get('Type') in ('x11', 'wayland') and props.get('Remote') == 'no':
                answer.append({'id': ident, 'scope': props['Scope'], 'uid': str(int(props['User']))})
        return answer

    def snapshot(self, dom):
        gpus = [p for p in self.pci.iterdir() if int((p / 'class').read_text(), 16) >> 16 == 3]
        if len(gpus) != 1 or (gpus[0] / 'vendor').read_text().strip() != '0x10de':
            raise Unsafe('requires exactly one NVIDIA display-class PCI device')
        gpu = gpus[0]
        if self.binding(gpu.name) != 'nvidia':
            raise Unsafe('host GPU is not bound to NVIDIA; recover existing ownership first')
        devices = sorted(p.name for p in self.pci.glob(gpu.name.rsplit('.', 1)[0] + '.*'))
        for bdf in devices:
            if not dom['devices'].get(bdf):
                raise Unsafe(f'VM requires managed=yes PCI assignment for {bdf}')
            group = self.pci / bdf / 'iommu_group/devices'
            if not group.is_dir():
                raise Unsafe(f'{bdf}: no IOMMU group; configure firmware/kernel first')
            for member in group.iterdir():
                is_bridge = int((member / 'class').read_text(), 16) >> 8 == 0x0604
                if not is_bridge and member.name not in devices:
                    raise Unsafe(f'{bdf}: IOMMU group includes unrelated device {member.name}')
        # Capture only relevant modules actually loaded, sorted by live holder graph.
        modules = {m for m in ('nvidia', 'nvidia_modeset', 'nvidia_drm', 'nvidia_uvm',
                              'nvidia_peermem', 'i2c_nvidia_gpu') if (Path('/sys/module') / m).exists()}
        order = []
        while modules:
            ready = sorted(m for m in modules if not any(
                p.name in modules for p in (Path('/sys/module') / m / 'holders').iterdir()))
            if not ready:
                raise Unsafe('unresolvable NVIDIA module dependency graph')
            order.extend(ready)
            modules.difference_update(ready)
        services = [s for s in ('nvidia-persistenced.service', 'nvidia-powerd.service') if self.active(s)]
        display = self.active('display-manager.service')
        scopes = [self.command('systemctl', 'show', s, '-p', 'ControlGroup', '--value').rsplit('/', 1)[-1]
                  for s in services + (['display-manager.service'] if display else [])]
        consoles = [str(p / 'bind') for p in Path('/sys/class/vtconsole').glob('vtcon*')
                    if 'frame buffer' in (p / 'name').read_text() and (p / 'bind').read_text().strip() == '1']
        frames = []
        for driver in ('efi-framebuffer', 'simple-framebuffer'):
            directory = Path('/sys/bus/platform/drivers') / driver
            if directory.exists():
                frames.extend({'driver': driver, 'device': p.name} for p in directory.iterdir()
                              if p.is_symlink() and p.name not in ('module', 'subsystem'))
        overrides = {bdf: (self.pci / bdf / 'driver_override').read_text().strip().replace('(null)', '')
                     for bdf in devices}
        snap = {'devices': self.bindings(devices), 'overrides': overrides, 'gpu': gpu.name, 'modules': order,
                'services': services, 'display': display, 'sessions': self.sessions(),
                'service_scopes': scopes, 'consoles': consoles, 'frames': frames}
        # End the user managers belonging to local graphical logins as well:
        # Flatpak applications and portals are outside the logind session scope.
        snap['user_managers'] = sorted({s['uid'] for s in snap['sessions']
                                        if self.active(f"user@{s['uid']}.service")})
        self.no_vfio_users()
        return snap

    def inhibitor_present(self):
        import dbus
        rows = dbus.Interface(dbus.SystemBus().get_object('org.freedesktop.login1', '/org/freedesktop/login1'),
                              'org.freedesktop.login1.Manager').ListInhibitors(timeout=10)
        pid = int(self.command('systemctl', 'show', INHIBITOR, '-p', 'MainPID', '--value') or 0)
        return any(str(row[1]) == WHO and str(row[3]) == 'block' and 'sleep' in str(row[0]).split(':')
                   and int(row[5]) == pid and pid > 0 for row in rows)

    def inhibit(self):
        self.command('systemctl', 'start', INHIBITOR)
        if not self.inhibitor_present():
            # A live holder can retain a stale descriptor after logind loss.
            # Starting an already-active unit is a no-op; explicitly reacquire
            # only when no effective inhibitor for this holder was verified.
            self.command('systemctl', 'restart', INHIBITOR)
            if not self.inhibitor_present():
                raise Failure('logind sleep inhibitor not acquired')

    def uninhibit(self):
        self.command('systemctl', 'stop', INHIBITOR)
        if self.active(INHIBITOR):
            raise Failure('inhibitor service did not stop')

    def apply(self, action):
        kind, value = action['kind'], action['value']
        if kind == 'user-manager':
            service = f'user@{value}.service'
            self.command('systemctl', 'stop', service)
            self.wait(lambda: not self.active(service), f'{service} did not stop')
        elif kind == 'service':
            self.command('systemctl', 'stop', value)
            self.wait(lambda: not self.active(value), f'{value} did not stop')
        elif kind == 'desktop-unit':
            args = ('systemctl', '--user', f"--machine={value['uid']}@.host")
            self.command(*args, 'stop', '--', value['unit'])
            self.wait(lambda: self.command(*args, 'show', value['unit'], '-p', 'ActiveState',
                                          '--value') in ('inactive', 'failed'),
                      f"desktop unit {value['unit']} did not stop")
        elif kind == 'session':
            session = next((s for s in self.sessions() if s['id'] == value), None)
            if session is None:
                return
            scope = session['scope']
            if not re.fullmatch(r'session-[A-Za-z0-9_]+\.scope', scope):
                raise Unsafe('invalid graphical session scope')
            def stopped():
                return self.command('systemctl', 'show', scope, '-p', 'ActiveState',
                                    '--value') in ('inactive', 'failed')
            self.command('loginctl', 'terminate-session', value)
            # A previously released session can remain abandoned: logind's
            # termination request alone need not finish its surviving scope.
            if not stopped():
                try:
                    self.command('systemctl', 'kill', '--signal=SIGKILL', '--kill-whom=all', scope)
                except Failure:
                    if not stopped():
                        raise
            self.wait(stopped, f'graphical session scope {scope} did not stop')
        elif kind == 'console':
            Path(value).write_text('0')
            self.wait(lambda: Path(value).read_text().strip() == '0', 'console did not unbind')
        elif kind == 'frame':
            path = Path('/sys/bus/platform/drivers') / value['driver']
            (path / 'unbind').write_text(value['device'])
            self.wait(lambda: not (path / value['device']).exists(), 'framebuffer did not unbind')
        elif kind == 'module':
            self.command('modprobe', '-r', value)
            self.wait(lambda: not (Path('/sys/module') / value).exists(), f'{value} did not unload')

    def undo(self, action):
        kind, value = action['kind'], action['value']
        if kind == 'service':
            self.command('systemctl', 'start', value)
            self.wait(lambda: self.active(value), f'{value} did not start')
        elif kind == 'console':
            Path(value).write_text('1')
            self.wait(lambda: Path(value).read_text().strip() == '1', 'console did not bind')
        elif kind == 'frame':
            path = Path('/sys/bus/platform/drivers') / value['driver']
            if not (path / value['device']).exists():
                (path / 'bind').write_text(value['device'])
            self.wait(lambda: (path / value['device']).exists(), 'framebuffer did not bind')
        elif kind == 'module':
            self.command('modprobe', value)
            self.wait(lambda: (Path('/sys/module') / value).exists(), f'{value} did not load')
        # Ended graphical sessions and user managers are not resurrected.
        # The display manager starts a fresh user manager on the next login.

    def vfio(self):
        self.command('modprobe', 'vfio_pci')
        if not Path('/sys/module/vfio_pci').exists():
            raise Failure('vfio_pci unavailable')

    def no_vfio_users(self):
        # Conservative with iommufd and unrelated passthrough: never guess which
        # opaque IOMMU fd belongs to the GPU. Ordinary non-VFIO VMs are unaffected.
        for proc in Path('/proc').iterdir():
            if not proc.name.isdigit():
                continue
            try:
                for fd in (proc / 'fd').iterdir():
                    try:
                        target = os.readlink(fd)
                    except FileNotFoundError:
                        continue
                    if (target.startswith(('/dev/vfio/', '/dev/iommu')) or
                            (target.startswith('anon_inode:') and any(x in target.lower() for x in ('vfio', 'iommufd')))):
                        raise Unsafe(f'VFIO/IOMMU device open by PID {proc.name}; restoration refused')
            except FileNotFoundError:
                continue
            except PermissionError as exc:
                raise Unsafe('cannot inspect VFIO process ownership') from exc

    def restore_bindings(self, snapshot):
        self.no_vfio_users()
        for bdf, original in snapshot['devices'].items():
            device = self.pci / bdf
            override = snapshot.get('overrides', {}).get(bdf, '')
            if self.binding(bdf) == original:
                (device / 'driver_override').write_text(override + '\n')
                continue
            current = self.binding(bdf)
            if current not in (None, 'vfio-pci'):
                raise Unsafe(f'{bdf}: unexpected driver {current}')
            if current:
                (device / 'driver/unbind').write_text(bdf)
            # libvirt normally restores this. Recover its interrupted detach too.
            if not original:
                (device / 'driver_override').write_text(override + '\n')
                continue
            (device / 'driver_override').write_text(original)
            try:
                self.command('modprobe', original)
                Path('/sys/bus/pci/drivers_probe').write_text(bdf)
                self.wait(lambda: self.binding(bdf) == original, f'{bdf}: host driver did not bind')
            finally:
                (device / 'driver_override').write_text(override + '\n')

    def verify_host(self, snapshot, resources=True):
        if self.bindings(snapshot['devices']) != snapshot['devices']:
            raise Failure('PCI bindings do not match the recorded host state')
        for module in snapshot['modules']:
            if not (Path('/sys/module') / module).exists():
                raise Failure(f'original module {module} is absent')
        if resources:
            for path in snapshot['consoles']:
                if Path(path).read_text().strip() != '1':
                    raise Failure(f'console not restored: {path}')
            for frame in snapshot['frames']:
                if not (Path('/sys/bus/platform/drivers') / frame['driver'] / frame['device']).exists():
                    raise Failure('framebuffer binding not restored')
            for service in snapshot['services'] + (['display-manager.service'] if snapshot['display'] else []):
                if not self.active(service):
                    raise Failure(f'original service {service} is inactive')

    def guest_evidence(self, devices):
        """Called ONLY by independent recovery. Unavailable libvirt is unknown."""
        try:
            identifiers = self.command('virsh', '-c', 'qemu:///system', 'list', '--uuid').split()
            active = []
            for ident in identifiers:
                guest = domain(self.command('virsh', '-c', 'qemu:///system', 'dumpxml', ident).encode())
                if guest['name'].endswith('-gpu') or set(devices).intersection(guest['devices']):
                    active.append(guest['uuid'])
            if active:
                raise Unsafe('active GPU guest(s): ' + ', '.join(active))
            self.no_vfio_users()
            # A QEMU process may be between spawn and VFIO open, or orphaned from
            # libvirt. Refuse if it mentions a target BDF or an owning suffix.
            for proc in Path('/proc').iterdir():
                if not proc.name.isdigit():
                    continue
                try:
                    cmd = (proc / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
                    if 'qemu-system' in cmd and (not any(ident in cmd for ident in identifiers)
                            or any(bdf in cmd or bdf[5:] in cmd for bdf in devices) or '-gpu' in cmd):
                        raise Unsafe(f'possible GPU QEMU process {proc.name} remains')
                except FileNotFoundError:
                    continue
            return self.bindings(devices)
        except Failure:
            raise
        except Exception as exc:
            raise Unsafe(f'guest ownership unavailable: {exc}') from exc

    def current_gpu_devices(self):
        gpus = [p for p in self.pci.iterdir() if int((p / 'class').read_text(), 16) >> 16 == 3]
        if len(gpus) != 1:
            raise Unsafe('cannot identify single host GPU')
        return sorted(p.name for p in self.pci.glob(gpus[0].name.rsplit('.', 1)[0] + '.*'))

    def fresh_boot_healthy(self):
        gpus = [p for p in self.pci.iterdir() if int((p / 'class').read_text(), 16) >> 16 == 3]
        if len(gpus) != 1 or self.binding(gpus[0].name) != 'nvidia' or not self.active('display-manager.service'):
            raise Unsafe('previous-boot state: NVIDIA/display manager not demonstrably healthy')
        self.command('nvidia-smi', '--query-gpu=uuid', '--format=csv,noheader')


class Engine:
    def __init__(self, store=None, host=None, check=deployment_check):
        self.store, self.host, self.check = store or Store(), host or Host(), check

    def save_phase(self, state, phase):
        state['phase'] = phase
        self.store.save(state)
        log(f'{state["name"]} ({state["uuid"]}): {phase}')

    def restore(self, state):
        if state['boot'] != self.host.boot():
            raise Unsafe('previous-boot journal; use vfio-host-recover')
        if self.store.claims():
            raise Unsafe('unresolved reconnect claims; use vfio-host-recover')
        self.host.no_vfio_users()
        self.save_phase(state, 'restoring')
        try:
            # Load changed modules before reattaching PCI; restore consoles and
            # services only afterward. The display manager is always last.
            actions = [a for a in reversed(state['actions']) if not a.get('restored')]
            for action in [a for a in actions if a['kind'] == 'module']:
                self.host.undo(action)
                action['restored'] = True
                self.store.save(state)
            self.host.restore_bindings(state['snapshot'])
            self.host.verify_host(state['snapshot'], resources=False)
            rest = [a for a in actions if a['kind'] != 'module']
            rest.sort(key=lambda a: a['kind'] == 'service' and a['value'] == 'display-manager.service')
            for action in rest:
                self.host.undo(action)
                action['restored'] = True
                self.store.save(state)
            self.host.verify_host(state['snapshot'])
            self.store.clear()
            self.host.uninhibit()
        except Exception as exc:
            self.save_phase(state, 'recovery-required')
            log(f'restoration incomplete: {exc}; run vfio-host-recover')
            raise

    def prepare(self, dom):
        with self.store.lock():
            self.check()
            state = self.store.load()
            if state or self.store.claims():
                owner = state['name'] if state else 'unresolved reconnect'
                raise Unsafe(f'GPU reserved by {owner}; recover before another acquisition')
            snapshot = self.host.snapshot(dom)
            state = dict(schema=1, boot=self.host.boot(), uuid=dom['uuid'], name=dom['name'],
                         generation=str(uuid.uuid4()), phase='preparing', snapshot=snapshot, actions=[])
            self.store.save(state)
            try:
                self.host.inhibit()
                actions = [('desktop-unit', unit) for unit in snapshot.get('desktop_units', [])]
                if snapshot['display']:
                    actions.append(('service', 'display-manager.service'))
                # A display-manager stop may already remove its sessions; query
                # remaining sessions before journaling explicit termination.
                self.stage(state, actions)
                self.stage(state, [('session', s['id']) for s in self.host.sessions()
                                   if s['id'] in [x['id'] for x in snapshot['sessions']]])
                self.stage(state, [('service', s) for s in snapshot['services']])
                self.stage(state, [('user-manager', uid) for uid in snapshot.get('user_managers', [])])
                self.stage(state, [('console', p) for p in snapshot['consoles']])
                self.stage(state, [('frame', p) for p in snapshot['frames']])
                self.stage(state, [('module', m) for m in snapshot['modules']])
                self.host.vfio()
                self.save_phase(state, 'prepared')
            except BaseException:
                # Immediate rollback is safe here: prepare has not returned to
                # libvirt, so managed detach/QEMU start cannot have happened.
                try:
                    self.restore(state)
                except Exception as exc:
                    log(f'immediate rollback failed: {exc}')
                    self.save_phase(state, 'recovery-required')
                raise

    def stage(self, state, actions):
        for kind, value in actions:
            action = {'kind': kind, 'value': value, 'done': False, 'restored': False}
            state['actions'].append(action)
            self.store.save(state)  # Write intent BEFORE changing host state.
            self.host.apply(action)
            action['done'] = True
            self.store.save(state)

    def reconnect(self, dom):
        try:
            with self.store.lock():
                state = self.store.load()
                if (not state or state['uuid'] != dom['uuid'] or state['boot'] != self.host.boot()
                        or set(state['snapshot']['devices']) - set(dom['devices'])):
                    self.store.claim(dom['uuid'], 'missing/stale/contradictory ownership on reconnect')
                    if state:
                        self.save_phase(state, 'recovery-required')
                elif state['phase'] != 'recovery-required':
                    self.save_phase(state, 'running')
        except Exception as exc:
            log(f'nonfatal reconnect inconsistency: {exc}')
            self.store.claim(dom['uuid'], str(exc))
        finally:
            # Even a corrupt/unreadable journal or a busy transition must not
            # prevent attempting to protect the existing guest from sleep.
            try:
                self.host.inhibit()
            except Exception as exc:
                log(f'nonfatal reconnect inhibitor failure: {exc}')
                self.store.claim(dom['uuid'], str(exc))
        # Caller/adapter also shields exceptions from libvirt reconnect.

    def hook(self, name, operation, suboperation, xml):
        if name.startswith('vfio-hook-probe-') and (operation, suboperation) == ('prepare', 'begin'):
            dom = domain(xml, name)
            pending = self.store.run / ('probe-' + dom['uuid'] + '.pending')
            if name == 'vfio-hook-probe-' + dom['uuid'] and pending.exists():
                if pending.read_text() == self.host.boot():
                    pending.with_suffix('.seen').write_text('adapter ABI 1; implementation v1\n')
                    raise Unsafe('activation probe observed; intentional pre-QEMU rejection')
        if not name.endswith('-gpu'):
            return
        dom = domain(xml, name)
        if operation == 'reconnect':
            self.reconnect(dom)
            return
        if (operation, suboperation) == ('prepare', 'begin'):
            self.prepare(dom)
        elif operation in ('migrate', 'restore', 'attach'):
            raise Unsafe('GPU migration, saved-state restore, and external attach are unsupported')
        elif (operation, suboperation) in (('start', 'begin'), ('started', 'begin'), ('release', 'end')):
            with self.store.lock():
                state = self.store.load()
                if not state or state['uuid'] != dom['uuid']:
                    if operation == 'release':
                        return  # Rejected competitor MUST NOT restore the owner.
                    raise Unsafe('no matching GPU ownership record')
                if operation == 'release':
                    self.restore(state)
                else:
                    if state['boot'] != self.host.boot() or state['phase'] not in ('prepared', 'running'):
                        raise Unsafe('GPU preparation is not healthy')
                    self.host.inhibit()
                    if operation == 'started':
                        self.save_phase(state, 'running')

    def recover(self, automatic=False):
        with self.store.lock():
            try:
                state = self.store.load()
            except (Unsafe, OSError):
                # Unknown ownership forbids restoration, but not protecting a
                # possibly running guest after loss of its inhibitor process.
                self.host.inhibit()
                raise
            claims = self.store.claims()
            claims_token = {p.name: p.read_text() for p in claims}
            observed_boot = self.host.boot()
            if not state and not claims:
                if not self.host.inhibitor_present():
                    return
                # An inhibitor may outlive a cleared journal, or its journal
                # may have been lost while a guest still runs. Do not stop it
                # without the same positive evidence required by recovery.
                self.store.claim('unknown', 'orphan inhibitor requires live host checks', kind='orphan-inhibitor')
                claims = self.store.claims()
                claims_token = {p.name: p.read_text() for p in claims}
            try:
                self.host.inhibit()
            except Exception:
                if state:
                    self.save_phase(state, 'recovery-required')
                raise
            if not state:
                records = [json.loads(p.read_text()) for p in claims]
                if any((c.get('boot') == self.host.boot() or not c.get('boot'))
                       and c.get('kind') != 'orphan-inhibitor' for c in records):
                    raise Unsafe('missing original host state; stop guest and reboot, then inspect claims')
                # Old-boot orphan claims can be retired only with positive live
                # guest evidence and a healthy current-boot NVIDIA host.
                token = {p.name: p.read_text() for p in claims}
                devices = self.host.current_gpu_devices()
                identity = None
            else:
                identity = tuple(state[k] for k in ('uuid', 'generation', 'revision', 'boot'))
                devices = state['snapshot']['devices']
            # Ownership itself reserves acquisition while the mutex is released.
        # No mutex here: libvirt queries may wait for hook completion.
        evidence = self.host.guest_evidence(devices)
        with self.store.lock():
            current = self.store.load()
            if (self.host.boot() != observed_boot or
                    {p.name: p.read_text() for p in self.store.claims()} != claims_token):
                raise Unsafe('boot or reconnect claims changed during recovery; retry')
            if identity is None:
                if current or {p.name: p.read_text() for p in self.store.claims()} != token:
                    raise Unsafe('claims changed during recovery; retry')
                if self.host.bindings(devices) != evidence:
                    raise Unsafe('PCI bindings changed during recovery; retry')
                self.host.no_vfio_users()
                self.host.fresh_boot_healthy()
                self.store.clear()
                self.host.uninhibit()
                return
            if (not current or tuple(current[k] for k in ('uuid', 'generation', 'revision', 'boot')) != identity
                    or self.host.bindings(devices) != evidence):
                raise Unsafe('ownership or PCI bindings changed during recovery; retry')
            self.host.no_vfio_users()
            if current['boot'] != self.host.boot():
                # Never replay old-boot actions; current boot must be healthy.
                self.host.fresh_boot_healthy()
                self.store.clear()
                self.host.uninhibit()
                log('retired previous-boot journal after current-host and guest checks')
                return
            if claims:
                # Positive external evidence has established no active GPU guest.
                for path in self.store.claims():
                    path.unlink()
                self.store.sync()
            self.restore(current)


def check_activation(engine):
    """Independent, explicitly invoked probe. Never restart a running daemon."""
    deployment_check()
    engine.store.init()
    ident = str(uuid.uuid4())
    pending = engine.store.run / ('probe-' + ident + '.pending')
    pending.write_text(engine.host.boot())
    seen = pending.with_suffix('.seen')
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.xml') as stream:
            stream.write(f'<domain type="qemu"><name>vfio-hook-probe-{ident}</name><uuid>{ident}</uuid>'
                         '<memory unit="KiB">65536</memory><vcpu>1</vcpu><os><type arch="x86_64">hvm</type></os>'
                         '<devices><video><model type="none"/></video></devices></domain>')
            stream.flush()
            created = False
            try:
                engine.host.command('virsh', '-c', 'qemu:///system', 'create', '--paused', stream.name)
                created = True
            except Failure as exc:
                if not seen.exists():
                    log(f'probe UUID {ident}: startup failed or timed out; checking for a paused probe')
                    raise Unsafe(f'libvirt did not execute the adapter: {exc}') from exc
            finally:
                # A timed-out virsh client does not prove QEMU failed to start.
                # Query only our random UUID; report ambiguity without touching
                # any other guest if the daemon is now unreachable.
                try:
                    active_probe = ident in engine.host.command('virsh', '-c', 'qemu:///system', 'list', '--uuid').split()
                except Failure as exc:
                    raise Unsafe(f'cannot confirm probe cleanup for {ident}: {exc}') from exc
                if active_probe:
                    # If the hook was absent, remove only our random, paused,
                    # diskless transient probe. Never touch an existing guest.
                    engine.host.command('virsh', '-c', 'qemu:///system', 'destroy', ident)
            if created or not seen.exists():
                raise Unsafe('adapter activation not verified; inspect daemon discovery and local hooks')
            print('Running libvirt executed VFIO adapter ABI 1 (implementation v1). GPU unchanged.')
    finally:
        pending.unlink(missing_ok=True)
        seen.unlink(missing_ok=True)


def hold_inhibitor():
    import dbus
    manager = dbus.Interface(dbus.SystemBus().get_object('org.freedesktop.login1', '/org/freedesktop/login1'),
                             'org.freedesktop.login1.Manager')
    fd = manager.Inhibit('sleep', WHO, 'Single GPU guest owns host display', 'block', timeout=10).take()
    try:
        address = os.environ['NOTIFY_SOCKET']
        if address.startswith('@'):
            address = '\0' + address[1:]
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notify:
            notify.connect(address)
            notify.sendall(b'READY=1')
        while True:
            signal.pause()
    finally:
        os.close(fd)


def main(argv):
    if os.geteuid() != 0:
        raise Unsafe('run as root')
    os.umask(0o077)
    engine = Engine()
    if argv == ['inhibit']:
        hold_inhibitor()
    elif argv == ['check-activation']:
        check_activation(engine)
    elif argv == ['check-deployment']:
        deployment_check()
    elif argv == ['status']:
        with engine.store.lock():
            state = engine.store.load()
            print(json.dumps({'owner': state, 'claims': [str(p) for p in engine.store.claims()],
                              'bindings': engine.host.bindings(state['snapshot']['devices']) if state else {}}, indent=2))
    elif argv in (['recover'], ['reconcile']):
        engine.recover(automatic=argv == ['reconcile'])
    elif len(argv) == 5 and argv[0] == 'hook':
        _, name, operation, suboperation, _extra = argv
        # Non-GPU hooks are identity filters: no stdout and no host inspection.
        data = sys.stdin.buffer.read(1024 * 1024 + 1)
        if operation == 'reconnect':
            try:
                engine.hook(name, operation, suboperation, data)
            except BaseException as exc:
                log(f'preserving guest after reconnect failure: {exc}')
                if name.endswith('-gpu'):
                    engine.store.claim('unknown', str(exc))
            return
        engine.hook(name, operation, suboperation, data)
    else:
        print('usage: vfio-host-recover [--status] (or internal hook/reconcile/check-deployment/inhibit)', file=sys.stderr)
        return 3
    return 0


if __name__ == '__main__':
    def interrupted(signum, _frame):
        raise Failure(f'interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main(sys.argv[1:]) or 0)
    except Exception as error:
        log(str(error))
        sys.exit(error.code if isinstance(error, Failure) else 1)
