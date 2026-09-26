#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-only
"""Unprivileged lifecycle/failure tests. Never invoke a real Host operation."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'system_files/usr/libexec/bazzite-firebadnofire-vfio/v1/vfio.py'
spec = importlib.util.spec_from_file_location('vfio', SOURCE)
vfio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vfio)
A = '11111111-1111-1111-1111-111111111111'
B = '22222222-2222-2222-2222-222222222222'
BOOT = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
BDF = '0000:01:00.0'


def xml(name='debian-gpu', ident=A, extra=''):
    return f'''<domain type="kvm"><name>{name}</name><uuid>{ident}</uuid><devices>
<hostdev mode="subsystem" type="pci" managed="yes"><source><address domain="0x0000"
bus="0x01" slot="0x00" function="0x0"/></source></hostdev>{extra}</devices></domain>'''.encode()


class FakeHost:
    def __init__(self):
        self.events = []
        self.fail = None
        self.fail_undo = False
        self.changed = []
        self.at = 0
        self.inhibited = False
        self.users = False
        self.active_guest = False
        self.unavailable = False
        self.boot_id = BOOT
        self.healthy = True
        self.before_evidence = None
        self.drivers = {BDF: 'nvidia'}
        self.snap = dict(devices=dict(self.drivers), gpu=BDF,
                         modules=['nvidia_uvm', 'nvidia_drm', 'nvidia_modeset', 'nvidia'],
                         services=['nvidia-persistenced.service'], display=True,
                         sessions=[{'id': '2', 'scope': 'session-2.scope', 'uid': '1000'}], service_scopes=[],
                         desktop_units=[{'uid': '1000', 'unit': 'app-flatpak-browser.scope'}],
                         user_managers=['1000'],
                         consoles=['/sys/class/vtconsole/vtcon0/bind'], frames=[{'driver': 'efi-framebuffer', 'device': 'efi-framebuffer.0'}])

    def boot(self):
        return self.boot_id

    def snapshot(self, dom):
        if not dom['devices'].get(BDF):
            raise vfio.Unsafe('missing managed GPU')
        return copy.deepcopy(self.snap)

    def event(self, value):
        self.events.append(value)
        self.at += 1
        if self.fail == self.at:
            raise vfio.Failure('injected failure')

    def inhibitor_present(self):
        return self.inhibited

    def inhibit(self):
        self.inhibited = True
        self.event('inhibit')

    def uninhibit(self):
        self.inhibited = False
        self.events.append('uninhibit')

    def sessions(self):
        return self.snap['sessions']

    def apply(self, action):
        self.changed.append((action['kind'], str(action['value'])))
        self.event('apply:' + action['kind'] + ':' + str(action['value']))

    def undo(self, action):
        self.events.append('undo:' + action['kind'] + ':' + str(action['value']))
        if self.fail_undo:
            raise vfio.Failure('restore failed')
        key = (action['kind'], str(action['value']))
        if key in self.changed:
            self.changed.remove(key)

    def gpu_users(self, snapshot):
        raise AssertionError('startup must not veto host GPU processes')

    def vfio(self):
        self.event('vfio')

    def no_vfio_users(self):
        if self.users or self.active_guest:
            raise vfio.Unsafe('active device holder')

    def restore_bindings(self, snapshot):
        self.events.append('bindings')
        self.drivers = dict(snapshot['devices'])

    def verify_host(self, snapshot, resources=True):
        self.events.append('verify')
        if not self.healthy:
            raise vfio.Failure('driver restoration failed')

    def bindings(self, devices):
        return {k: self.drivers[k] for k in devices}

    def guest_evidence(self, devices):
        if self.before_evidence:
            self.before_evidence()
        if self.unavailable:
            raise vfio.Unsafe('libvirt unavailable')
        self.no_vfio_users()
        return self.bindings(devices)

    def fresh_boot_healthy(self):
        if not self.healthy or self.drivers[BDF] != 'nvidia':
            raise vfio.Unsafe('current boot hardware unhealthy')
        self.events.append('fresh-boot')

    def current_gpu_devices(self):
        return [BDF]


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = vfio.Store(Path(self.tmp.name) / 'state', Path(self.tmp.name) / 'run')
        self.host = FakeHost()
        self.engine = vfio.Engine(self.store, self.host, check=lambda: None)

    def tearDown(self):
        self.tmp.cleanup()

    def hook(self, op, name='debian-gpu', ident=A):
        self.engine.hook(name, op, 'end' if op == 'release' else 'begin', xml(name, ident))

    def test_suffix_and_normal_vm(self):
        for name in ('debian1', 'debian-GPU', 'debian-gpu-more'):
            self.engine.hook(name, 'prepare', 'begin', b'')
        self.assertEqual(self.host.events, [])
        self.hook('prepare')
        self.assertEqual(self.store.load()['phase'], 'prepared')

    def test_competitor_release_cannot_touch_owner(self):
        self.hook('prepare')
        with self.assertRaises(vfio.Unsafe):
            self.hook('prepare', 'debian2-gpu', B)
        events = list(self.host.events)
        self.hook('release', 'debian2-gpu', B)
        self.assertEqual(self.host.events, events)
        self.assertEqual(self.store.load()['uuid'], A)

    def test_lifetime_release_and_next_owner(self):
        self.hook('prepare')
        self.hook('start')
        self.hook('started')
        self.assertTrue(self.host.inhibited)
        self.hook('release')
        self.assertIsNone(self.store.load())
        self.assertFalse(self.host.inhibited)
        last_undo = [e for e in self.host.events if e.startswith('undo:')][-1]
        self.assertEqual(last_undo, 'undo:service:display-manager.service')
        self.hook('release')
        self.hook('prepare', 'debian2-gpu', B)
        self.assertEqual(self.store.load()['uuid'], B)

    def test_desktop_teardown_precedes_module_unload_without_process_veto(self):
        self.hook('prepare')
        events = self.host.events
        display = events.index('apply:service:display-manager.service')
        session = events.index('apply:session:2')
        manager = events.index('apply:user-manager:1000')
        module = events.index('apply:module:nvidia_uvm')
        self.assertLess(display, session)
        self.assertLess(session, manager)
        self.assertLess(manager, module)
        self.assertEqual(self.store.load()['phase'], 'prepared')

    def test_every_preparation_failure_immediately_rolls_back(self):
        # Count inhibitor, checks, each destructive operation, and VFIO load.
        self.hook('prepare')
        total = self.host.at
        self.hook('release')
        for stage in range(1, total + 1):
            with self.subTest(stage=stage):
                self.host = FakeHost()
                self.host.fail = stage
                self.engine.host = self.host
                with self.assertRaises(vfio.Failure):
                    self.hook('prepare')
                self.assertIsNone(self.store.load())
                self.assertFalse(self.host.inhibited)
                self.assertEqual(self.host.changed, [])

    def test_intent_is_durable_before_apply(self):
        old = self.host.apply
        def apply(action):
            state = self.store.load()
            self.assertEqual(state['actions'][-1], action)
            self.assertFalse(state['actions'][-1]['done'])
            old(action)
        self.host.apply = apply
        self.hook('prepare')

    def test_failed_rollback_retains_ownership(self):
        self.host.fail = 3
        self.host.fail_undo = True
        with self.assertRaises(vfio.Failure):
            self.hook('prepare')
        self.assertEqual(self.store.load()['phase'], 'recovery-required')
        self.assertTrue(self.host.inhibited)
        self.host.fail = None
        self.host.fail_undo = False
        self.engine.recover()
        self.assertIsNone(self.store.load())

    def test_failed_qemu_and_later_hook_release(self):
        for failure in ('QEMU startup', 'later prepare hook', 'later start hook'):
            with self.subTest(failure=failure):
                self.hook('prepare')
                self.host.drivers[BDF] = 'vfio-pci'
                self.host.users = True  # libvirt still holds resources
                before = len(self.host.events)
                with self.assertRaises(vfio.Unsafe):
                    self.engine.recover(automatic=True)
                self.assertFalse(any(e.startswith('undo:') for e in self.host.events[before:]))
                self.host.users = False
                self.hook('release')
                self.assertIsNone(self.store.load())

    def test_missing_release_requires_positive_evidence(self):
        self.hook('prepare')
        self.host.unavailable = True
        with self.assertRaises(vfio.Unsafe):
            self.engine.recover(automatic=True)
        self.assertIsNotNone(self.store.load())
        self.host.unavailable = False
        self.engine.recover(automatic=True)
        self.assertIsNone(self.store.load())

    def test_reconnect_valid_missing_stale_conflicting(self):
        for kind in ('valid', 'missing', 'stale', 'conflicting'):
            with self.subTest(kind=kind):
                self.store.init()
                self.store.clear()
                self.hook('prepare')
                state = self.store.load()
                if kind == 'missing':
                    self.store.clear()
                elif kind == 'stale':
                    state['boot'] = str(uuid.uuid4())
                    self.store.save(state)
                elif kind == 'conflicting':
                    state['uuid'] = B
                    self.store.save(state)
                before = len(self.host.events)
                self.hook('reconnect')
                self.assertEqual(self.host.events[before:], ['inhibit'])
                self.assertEqual(bool(self.store.claims()), kind != 'valid')
                with self.assertRaises(vfio.Unsafe):
                    self.hook('prepare', 'debian2-gpu', B)

    def test_reconnect_corrupt_state_is_nonfatal(self):
        self.store.init()
        (self.store.base / 'owner.json').write_text('{broken')
        self.hook('reconnect')
        self.assertTrue(self.store.claims())
        self.assertTrue(self.host.inhibited)
        self.host.inhibited = False
        with self.assertRaises(vfio.Unsafe):
            self.engine.recover(automatic=True)
        self.assertTrue(self.host.inhibited)
        self.assertEqual(self.host.events, ['inhibit', 'inhibit'])

    def test_inhibitor_reacquired_after_crash_or_stop(self):
        self.hook('prepare')
        self.host.active_guest = True
        for reason in ('crash', 'stop'):
            with self.subTest(reason=reason):
                self.host.inhibited = False
                with self.assertRaises(vfio.Unsafe):
                    self.engine.recover(automatic=True)
                self.assertTrue(self.host.inhibited)
                self.assertIsNotNone(self.store.load())
        self.host.inhibited = False
        self.hook('reconnect')
        self.assertTrue(self.host.inhibited)

    def test_orphan_inhibitor_requires_live_guest_evidence(self):
        self.host.inhibited = True
        self.host.active_guest = True
        with self.assertRaises(vfio.Unsafe):
            self.engine.recover()
        self.assertTrue(self.host.inhibited)
        self.host.active_guest = False
        self.engine.recover()
        self.assertFalse(self.host.inhibited)
        self.assertFalse(self.store.claims())

    def test_recovery_refuses_running_guest(self):
        self.hook('prepare')
        self.host.active_guest = True
        with self.assertRaises(vfio.Unsafe):
            self.engine.recover()
        self.assertIsNotNone(self.store.load())

    def test_recovery_generation_revalidation(self):
        self.hook('prepare')
        def change():
            # Query runs without mutex: a callback can update ownership.
            with self.store.lock():
                state = self.store.load()
                state['generation'] = str(uuid.uuid4())
                self.store.save(state)
        self.host.before_evidence = change
        with self.assertRaises(vfio.Unsafe):
            self.engine.recover()
        self.assertIsNotNone(self.store.load())

    def test_repeated_recovery_after_restore_interruption(self):
        self.hook('prepare')
        self.host.fail_undo = True
        with self.assertRaises(vfio.Failure):
            self.hook('release')
        self.assertEqual(self.store.load()['phase'], 'recovery-required')
        self.host.fail_undo = False
        self.engine.recover()
        self.engine.recover()
        self.assertIsNone(self.store.load())

    def test_partial_modules_inactive_services(self):
        self.host.snap['modules'] = ['nvidia_drm', 'nvidia_modeset', 'nvidia']
        self.host.snap['services'] = []
        self.hook('prepare')
        self.hook('release')
        self.assertFalse(any('nvidia_uvm' in e or 'persistenced' in e for e in self.host.events))

    def test_previous_boot_never_replays_actions(self):
        for phase in ('preparing', 'running', 'restoring'):
            with self.subTest(phase=phase):
                self.hook('prepare')
                state = self.store.load()
                state['phase'] = phase
                self.store.save(state)
                self.host.boot_id = str(uuid.uuid4())
                self.host.healthy = False
                with self.assertRaises(vfio.Unsafe):
                    self.engine.recover()
                self.assertIsNotNone(self.store.load())
                self.host.healthy = True
                before = len(self.host.events)
                self.engine.recover()
                self.assertFalse(any(e.startswith('undo:') for e in self.host.events[before:]))
                self.assertIsNone(self.store.load())

    def test_old_orphan_claim_requires_healthy_boot_and_guest_evidence(self):
        self.store.claim(A, 'missing state')
        self.host.boot_id = str(uuid.uuid4())
        self.host.unavailable = True
        with self.assertRaises(vfio.Unsafe):
            self.engine.recover()
        self.assertTrue(self.store.claims())
        self.host.unavailable = False
        self.engine.recover()
        self.assertFalse(self.store.claims())

    def test_interruption_after_each_host_change_before_completion_write(self):
        self.hook('prepare')
        original = self.store.load()
        self.hook('release')
        for index in range(len(original['actions'])):
            with self.subTest(index=index):
                state = copy.deepcopy(original)
                state['phase'] = 'preparing'
                state['actions'] = state['actions'][:index + 1]
                state['actions'][-1]['done'] = False
                self.store.save(state)
                self.engine.recover()
                self.assertIsNone(self.store.load())

    def test_recovery_revalidates_uuid_boot_revision_claims_and_bindings(self):
        for field in ('uuid', 'boot', 'revision', 'claims', 'bindings'):
            with self.subTest(field=field):
                self.store.init()
                self.store.clear()
                self.host = FakeHost()
                self.engine.host = self.host
                self.hook('prepare')
                before = len(self.host.events)
                def evidence(devices):
                    bindings = self.host.bindings(devices)
                    with self.store.lock():
                        state = self.store.load()
                        if field == 'claims':
                            self.store.claim(B, 'new reconnect')
                        elif field == 'bindings':
                            self.host.drivers[BDF] = 'vfio-pci'
                        else:
                            state[field] = state[field] + 1 if field == 'revision' else B
                            self.store.save(state)
                    return bindings
                self.host.guest_evidence = evidence
                with self.assertRaises(vfio.Unsafe):
                    self.engine.recover()
                self.assertFalse(any(e.startswith('undo:') for e in self.host.events[before:]))

    def test_failed_restoration_never_starts_display(self):
        self.hook('prepare')
        self.host.healthy = False
        before = len(self.host.events)
        with self.assertRaises(vfio.Failure):
            self.hook('release')
        self.assertNotIn('undo:service:display-manager.service', self.host.events[before:])
        self.assertEqual(self.store.load()['phase'], 'recovery-required')

    def test_inhibitor_reacquisition_failure_quarantines_without_restoring(self):
        self.hook('prepare')
        self.host.fail = self.host.at + 1
        before = len(self.host.events)
        with self.assertRaises(vfio.Failure):
            self.engine.recover()
        self.assertEqual(self.store.load()['phase'], 'recovery-required')
        self.assertFalse(any(e.startswith('undo:') for e in self.host.events[before:]))

    def test_activation_receipt_requires_matching_pending_boot(self):
        self.store.init()
        name = 'vfio-hook-probe-' + A
        path = self.store.run / ('probe-' + A + '.pending')
        path.write_text('old-boot')
        self.engine.hook(name, 'prepare', 'begin', xml(name))
        self.assertFalse(path.with_suffix('.seen').exists())
        path.write_text(BOOT)
        with self.assertRaises(vfio.Unsafe):
            self.engine.hook(name, 'prepare', 'begin', xml(name))
        self.assertTrue(path.with_suffix('.seen').exists())
        self.assertEqual(self.host.events, [])

    def test_nonblocking_lock(self):
        with self.store.lock():
            with self.assertRaises(vfio.Unsafe):
                self.hook('prepare')

    def test_malformed_and_unsupported_xml(self):
        for data in (b'', b'<!DOCTYPE domain><domain/>', xml().replace(b'0x01', b'0x100')):
            with self.assertRaises(vfio.Unsafe):
                self.engine.hook('debian-gpu', 'prepare', 'begin', data)
        for operation in ('migrate', 'restore', 'attach'):
            with self.assertRaises(vfio.Unsafe):
                self.hook(operation)
        self.assertEqual(self.host.events, [])


class Deployment(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.hooks = Path(self.tmp.name) / 'hooks'
        self.adapter = self.hooks / 'qemu.d/90-bazzite-firebadnofire-vfio'
        self.adapter.parent.mkdir(parents=True)
        self.template = ROOT / 'system_files/usr/share/bazzite-firebadnofire/vfio/adapter'
        self.adapter.write_bytes(self.template.read_bytes())
        self.adapter.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def check(self):
        vfio.deployment_check(self.adapter, self.template)

    def test_stable_adapter_local_comments_survive_new_implementation(self):
        self.adapter.write_text(self.adapter.read_text() + '\n# local operator note\n')
        before = self.adapter.read_bytes()
        self.check()
        self.assertEqual(before, self.adapter.read_bytes())

    def test_modified_adapter_is_preserved_but_blocks_acquisition(self):
        self.adapter.write_text(self.adapter.read_text().replace('hook "$@"', 'hook "$1"'))
        before = self.adapter.read_bytes()
        with self.assertRaises(vfio.Unsafe):
            self.check()
        self.assertEqual(before, self.adapter.read_bytes())

    def test_existing_hooks_and_duplicates(self):
        existing = self.hooks / 'qemu'
        existing.write_text('#!/bin/sh\nexit 0\n')
        existing.chmod(0o755)
        self.check()
        duplicate = self.adapter.with_name('99-duplicate')
        duplicate.write_bytes(self.adapter.read_bytes())
        duplicate.chmod(0o755)
        with self.assertRaises(vfio.Unsafe):
            self.check()

    def test_reconnect_adapter_shields_helper_failure(self):
        # Substitute only the entrypoint to simulate an unavailable implementation.
        self.adapter.write_text(self.adapter.read_text().replace('/usr/libexec/bazzite-firebadnofire-vfio-run', '/usr/bin/false'))
        result = subprocess.run([str(self.adapter), 'debian-gpu', 'reconnect', 'begin', '-'],
                                input=xml(), capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        self.assertIn(b'preserving guest', result.stderr)

    def test_xml_filter_chain_preserves_predecessor_output(self):
        # libvirt virHookCall retains prior nonempty output when this hook emits
        # nothing. Exercise real subprocess invocation and an existing transformer.
        predecessor = self.hooks / 'qemu'
        predecessor.write_text('#!/usr/bin/python3\nimport sys\nsys.stdout.write(sys.stdin.read().replace("ORIGINAL", "TRANSFORMED"))\n')
        predecessor.chmod(0o755)
        data = xml('debian1', extra='<metadata>ORIGINAL</metadata>')
        transformed = subprocess.check_output([str(predecessor)], input=data)
        # Importing main as a module avoids the root requirement in this mock.
        runner = Path(self.tmp.name) / 'runner'
        runner.write_text(f'#!/usr/bin/python3\nimport runpy,sys\nv=runpy.run_path({str(SOURCE)!r})\nv["Engine"]().hook(*sys.argv[2:5],sys.stdin.buffer.read())\n')
        runner.chmod(0o755)
        self.adapter.write_text(self.adapter.read_text().replace('/usr/libexec/bazzite-firebadnofire-vfio-run', str(runner)))
        result = subprocess.run([str(self.adapter), 'debian1', 'restore', 'begin', '-'], input=transformed, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        downstream_input = result.stdout or transformed
        self.assertEqual(downstream_input, transformed)
        self.assertIn(b'TRANSFORMED', downstream_input)
        self.assertNotIn(b'ORIGINAL', downstream_input)


class Backend(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.original_path = vfio.Path
        def mapped(value):
            value = str(value)
            if value.startswith(('/proc', '/sys', '/dev')):
                return self.root / value.lstrip('/')
            return Path(value)
        self.mapping = patch.object(vfio, 'Path', mapped)
        self.mapping.start()
        (self.root / 'proc').mkdir()
        self.host = vfio.Host()
        self.host.pci = self.root / 'sys/bus/pci/devices'
        self.host.pci.mkdir(parents=True)

    def tearDown(self):
        self.mapping.stop()
        self.tmp.cleanup()

    def test_unavailable_libvirt_never_establishes_safe_evidence(self):
        def failed(*args, **kwargs):
            raise vfio.Failure('daemon unavailable')
        self.host.command = failed
        with self.assertRaises(vfio.Failure):
            self.host.guest_evidence([BDF])

    def test_active_guest_with_non_gpu_name_still_blocks_recovery(self):
        self.host.command = lambda *args, **kwargs: A if 'list' in args else xml('debian1').decode()
        with self.assertRaises(vfio.Unsafe):
            self.host.guest_evidence([BDF])

    def test_orphan_qemu_without_vfio_fds_blocks_recovery(self):
        proc = self.root / 'proc/123'
        proc.mkdir()
        (proc / 'fd').mkdir()
        (proc / 'cmdline').write_bytes(b'/usr/bin/qemu-system-x86_64\0-name\0untracked')
        self.host.command = lambda *args, **kwargs: ''
        with self.assertRaises(vfio.Unsafe):
            self.host.guest_evidence([BDF])

    def test_vfio_handle_even_without_qemu_name_blocks_recovery(self):
        proc = self.root / 'proc/123/fd'
        proc.mkdir(parents=True)
        (proc / '4').symlink_to('/dev/vfio/12')
        with self.assertRaises(vfio.Unsafe):
            self.host.no_vfio_users()

    def test_normal_file_named_vfio_is_not_a_device_holder(self):
        proc = self.root / 'proc/123/fd'
        proc.mkdir(parents=True)
        (proc / '4').symlink_to('/var/log/vfio.log')
        self.host.no_vfio_users()

    def test_user_manager_stopped_and_not_resurrected(self):
        calls = []
        self.host.command = lambda *args, **kwargs: calls.append(args) or 'inactive'
        action = {'kind': 'user-manager', 'value': '1000'}
        self.host.apply(action)
        self.host.undo(action)
        self.assertEqual(calls, [('systemctl', 'stop', 'user@1000.service'),
                                ('systemctl', 'show', 'user@1000.service', '-p', 'ActiveState', '--value')])

    def test_user_manager_stop_failure_propagates(self):
        def failed(*args, **kwargs):
            raise vfio.Failure('stop failed')
        self.host.command = failed
        with self.assertRaises(vfio.Failure):
            self.host.apply({'kind': 'user-manager', 'value': '1000'})

    def test_desktop_unit_stops_without_resurrection(self):
        calls = []
        self.host.command = lambda *args, **kwargs: calls.append(args) or 'inactive'
        action = {'kind': 'desktop-unit', 'value': {'uid': '1000', 'unit': 'app-browser.scope'}}
        self.host.apply(action)
        self.host.undo(action)
        self.assertEqual(calls[0], ('systemctl', '--user', '--machine=1000@.host',
                                   'stop', '--', 'app-browser.scope'))
        self.assertEqual(len(calls), 2)

    def test_console_write_and_readback(self):
        file = self.root / 'sys/class/vtconsole/vtcon0/bind'
        file.parent.mkdir(parents=True)
        file.write_text('1')
        action = {'kind': 'console', 'value': '/sys/class/vtconsole/vtcon0/bind'}
        self.host.apply(action)
        self.assertEqual(file.read_text(), '0')
        self.host.undo(action)
        self.assertEqual(file.read_text(), '1')

    def test_module_command_failure_is_not_suppressed(self):
        calls = []
        def failed(*args, **kwargs):
            calls.append(args)
            raise vfio.Failure('module busy')
        self.host.command = failed
        for op in (self.host.apply, self.host.undo):
            with self.assertRaises(vfio.Failure):
                op({'kind': 'module', 'value': 'nvidia'})
        self.assertEqual(calls, [('modprobe', '-r', 'nvidia'), ('modprobe', 'nvidia')])

    def test_live_service_with_missing_inhibitor_is_reacquired(self):
        calls = []
        self.host.command = lambda *args, **kwargs: calls.append(args)
        present = iter([False, True])
        self.host.inhibitor_present = lambda: next(present)
        self.host.inhibit()
        self.assertEqual(calls, [('systemctl', 'start', vfio.INHIBITOR),
                                 ('systemctl', 'restart', vfio.INHIBITOR)])
        self.host.inhibitor_present = lambda: False
        with self.assertRaises(vfio.Failure):
            self.host.inhibit()

    def test_bounded_wait_does_not_claim_success(self):
        with self.assertRaises(vfio.Failure):
            self.host.wait(lambda: False, 'never reached', seconds=0)


if __name__ == '__main__':
    unittest.main()
