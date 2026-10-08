"""Exercise the installer entry point in isolated homes without launchctl or signals."""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/helper.py'
spec = importlib.util.spec_from_file_location('clawminutes_helper', SCRIPT)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='clawminutes-installer-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.state = self.root / 'state'
        self.state.mkdir()
        self.recordings = self.root / 'custom-recordings'
        self.recordings.mkdir()
        (self.state / 'config.json').write_text(json.dumps({'recordings_dir': str(self.recordings)}))
        self.commands = []
        self.fail_bootstrap = False
        self.bootstrap_calls = 0
        self.job_loaded = False
        self.ps_output = b''
        self.distribution = self.root / 'distribution'
        self.script = self.distribution / 'scripts/helper.py'
        self.script.parent.mkdir(parents=True)
        self.script.write_text('fixture')
        self.source = self.distribution / 'helper/ocmh.app'
        (self.source / 'Contents/MacOS').mkdir(parents=True)
        (self.source / 'Contents/MacOS/ocmh').write_bytes(b'fixture')
        (self.source / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': helper.LABEL, 'CFBundleShortVersionString': '0.2.9', 'OCMHUsesLifecycleLock': True}))

    def command(self, *args, **kwargs):
        self.commands.append(args)
        if args[:2] == ('/bin/launchctl', 'bootstrap'):
            self.bootstrap_calls += 1
            if self.fail_bootstrap and self.bootstrap_calls == 1:
                raise subprocess.CalledProcessError(1, args)
            self.job_loaded = True
        if args[:2] == ('/bin/launchctl', 'bootout'): self.job_loaded = False
        if args[:2] == ('/bin/launchctl', 'print'):
            return subprocess.CompletedProcess(args, 0 if self.job_loaded else 1, b'', b'')
        return subprocess.CompletedProcess(args, 0, self.ps_output if args[0] == '/bin/ps' else b'', b'')

    def invoke(self, action, *, launch=False, gateway=None):
        arguments = ["helper.py", action] + ([] if launch else ["--no-launch"])
        if gateway: arguments += ["--gateway", gateway]
        with mock.patch.dict(os.environ, {'OPENCLAW_TEAMS_HOME': str(self.state)}), \
             mock.patch.object(pathlib.Path, 'home', return_value=self.home), \
             mock.patch.object(helper, 'command', self.command), \
             mock.patch.object(helper, '__file__', str(self.script)), \
             mock.patch.object(helper.os, 'kill', side_effect=AssertionError('Unexpected process signal')), \
             mock.patch.object(sys, 'platform', 'darwin'), \
             mock.patch.object(sys, 'argv', arguments), \
             contextlib.redirect_stderr(io.StringIO()) as errors, contextlib.redirect_stdout(io.StringIO()) as output:
            try:
                helper.main()
            except SystemExit as error:
                self.errors = errors.getvalue()
                return error.code
            finally:
                self.output = output.getvalue()
        return 0

    def test_remove_refuses_active_recording_in_configured_folder(self):
        session = self.recordings / 'meeting'
        session.mkdir()
        (session / 'meta.json').write_text('{"status":"recording"}')
        before = (self.state / 'config.json').read_bytes()
        self.assertEqual(self.invoke('remove'), 2)
        self.assertFalse(any(c[0] == '/bin/launchctl' for c in self.commands))
        self.assertEqual((self.state / 'config.json').read_bytes(), before)
        self.assertTrue((session / 'meta.json').exists())

    def test_update_refuses_active_recording_in_configured_folder(self):
        session = self.recordings / 'meeting'
        session.mkdir()
        (session / 'meta.json').write_text('{"status":"recording"}')
        self.assertEqual(self.invoke('update'), 2)
        self.assertIn('recording is active or unfinished', self.errors)
        self.assertEqual(self.commands, [])

    def test_protected_idle_helper_can_update_with_orphan_metadata(self):
        shutil.copytree(self.source, self.state / helper.NAME)
        session = self.recordings / 'orphan'
        session.mkdir()
        (session / 'meta.json').write_text('{"status":"recording"}')
        before = (session / 'meta.json').read_bytes()
        self.assertEqual(self.invoke('update'), 0)
        self.assertEqual((session / 'meta.json').read_bytes(), before)
        agent = self.home / 'Library/LaunchAgents' / f'{helper.LABEL}.plist'
        plist = plistlib.loads(agent.read_bytes())
        self.assertEqual(plist['ProgramArguments'][0], str(self.state / helper.NAME / 'Contents/MacOS/ocmh'))
        self.assertEqual(plist['KeepAlive'], {'SuccessfulExit': False})
        self.assertGreaterEqual(plist['ThrottleInterval'], 10)

    def test_update_refuses_live_processing_without_recording_metadata(self):
        with (self.state / 'lifecycle.lock').open('a+b') as lease:
            fcntl.flock(lease.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
            self.assertEqual(self.invoke('update'), 2)
        self.assertIn('transcription, archiving', self.errors)
        self.assertEqual(self.commands, [])

    def test_remove_refuses_live_shared_work_lock_without_recording_metadata(self):
        with (self.state / 'lifecycle.lock').open('a+b') as lease:
            fcntl.flock(lease.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
            self.assertEqual(self.invoke('remove'), 2)
        self.assertFalse(any(c[0] == '/bin/launchctl' for c in self.commands))

    def test_run_cannot_bootstrap_while_processing_or_installer_owns_lease(self):
        for mode in [fcntl.LOCK_SH, fcntl.LOCK_EX]:
            with (self.state / 'lifecycle.lock').open('a+b') as lease:
                fcntl.flock(lease.fileno(), mode | fcntl.LOCK_NB)
                self.assertEqual(self.invoke('run'), 2)
        self.assertEqual(self.commands, [])

    def test_running_legacy_helper_is_not_signalled(self):
        app = self.state / helper.NAME
        shutil.copytree(self.source, app)
        info = app / 'Contents/Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': helper.LABEL, 'CFBundleShortVersionString': '0.2.8'}))
        self.ps_output = f'99999 {app}/Contents/MacOS/ocmh run\n'.encode()
        self.assertEqual(self.invoke('update'), 2)
        self.assertIn('predates lifecycle protection', self.errors)
        self.assertEqual(self.commands, [('/bin/ps', '-axo', 'pid=,command=')])
        self.assertEqual(plistlib.loads(info.read_bytes())['CFBundleShortVersionString'], '0.2.8')

    def test_idle_update_preserves_existing_preferences_and_releases_lease(self):
        settings = {'recordings_dir': str(self.recordings), 'transcription': {'enabled': True, 'engine': 'parakeet'},
                    'speaker_voice_memory': True, 'auto_meeting_captions': False,
                    'post_processing': {'mode': 'off'}, 'notes_mode': 'ai'}
        (self.state / 'config.json').write_text(json.dumps(settings))
        self.assertEqual(self.invoke('update'), 0)
        self.assertEqual(json.loads((self.state / 'config.json').read_text()), settings)
        self.assertTrue((self.state / helper.NAME / 'Contents/MacOS/ocmh').exists())
        with (self.state / 'lifecycle.lock').open('a+b') as lease:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_remove_refuses_concurrent_installer(self):
        with (self.state / 'lifecycle.lock').open('a+b') as lease:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.invoke('remove'), 2)
        self.assertFalse(any(c[0] == '/bin/launchctl' for c in self.commands))

    def test_remove_fails_closed_on_unreadable_metadata(self):
        session = self.recordings / 'meeting'
        session.mkdir()
        (session / 'meta.json').write_text('{broken')
        self.assertEqual(self.invoke('remove'), 2)
        self.assertFalse(any(c[0] == '/bin/launchctl' for c in self.commands))

    def test_idle_removal_preserves_configuration_and_recordings(self):
        session = self.recordings / 'meeting'
        session.mkdir()
        (session / 'meta.json').write_text('{"status":"stopped"}')
        before = (self.state / 'config.json').read_bytes()
        self.assertEqual(self.invoke('remove'), 0)
        self.assertEqual((self.state / 'config.json').read_bytes(), before)
        self.assertTrue((session / 'meta.json').exists())
        with (self.state / 'lifecycle.lock').open('a+b') as lease:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def previous_install(self):
        self.job_loaded = True
        app = self.state / helper.NAME
        shutil.copytree(self.source, app)
        (app / 'Contents/MacOS/ocmh').write_bytes(b'old helper')
        config = self.state / 'config.json'
        config.write_bytes(b'{ "recordings_dir": ' + json.dumps(str(self.recordings)).encode() + b', "gateway": {"url": "https://old.example", "token":"PRIVATE-old-token"} }\n')
        config.chmod(0o640)
        agent = self.home / 'Library/LaunchAgents' / f'{helper.LABEL}.plist'
        agent.parent.mkdir(parents=True)
        agent.write_bytes(plistlib.dumps({'Label': helper.LABEL, 'ProgramArguments': [str(app / 'Contents/MacOS/ocmh'), 'run'], 'EnvironmentVariables': {'OLD': 'preserved'}, 'KeepAlive': False}))
        agent.chmod(0o640)
        receipt = self.state / 'installation-receipt.json'
        receipt.write_bytes(b'{"version":"old","marker":"PRIVATE-prior"}\n'); receipt.chmod(0o600)
        return {path: (path.read_bytes(), path.stat().st_mode & 0o777) for path in [config, agent, receipt]}

    def test_failed_bootstrap_restores_exact_prior_app_config_agent_and_receipt(self):
        before = self.previous_install(); self.fail_bootstrap = True
        with self.assertRaises(RuntimeError): self.invoke('update', launch=True, gateway='https://new.example')
        self.assertEqual((self.state / helper.NAME / 'Contents/MacOS/ocmh').read_bytes(), b'old helper')
        for path, (data, mode) in before.items():
            with self.subTest(path=path.name):
                self.assertEqual(path.read_bytes(), data)
                self.assertEqual(path.stat().st_mode & 0o777, mode)
        self.assertEqual(self.bootstrap_calls, 2)

    def test_failed_fresh_install_restores_absent_config_agent_and_receipt(self):
        (self.state / 'config.json').unlink(); self.fail_bootstrap = True
        with self.assertRaises(RuntimeError): self.invoke('install', launch=True)
        for path in [self.state / helper.NAME, self.state / 'config.json', self.state / 'installation-receipt.json', self.home / 'Library/LaunchAgents' / f'{helper.LABEL}.plist']:
            with self.subTest(path=path.name): self.assertFalse(path.exists())

    def assert_prior_files(self, before):
        for path, (data, mode) in before.items():
            with self.subTest(path=path.name):
                self.assertEqual(path.read_bytes(), data)
                self.assertEqual(path.stat().st_mode & 0o777, mode)
        self.assertEqual((self.state / helper.NAME / 'Contents/MacOS/ocmh').read_bytes(), b'old helper')

    def test_receipt_write_failure_rolls_back_without_launching_in_no_launch_mode(self):
        before = self.previous_install()
        write = helper.atomic_file
        def fail_receipt(path, *args):
            if path == self.state / 'installation-receipt.json': raise OSError('fixture disk failure')
            return write(path, *args)
        with mock.patch.object(helper, 'atomic_file', side_effect=fail_receipt), self.assertRaises(RuntimeError):
            self.invoke('update', gateway='https://new.example')
        self.assert_prior_files(before)
        self.assertEqual(self.bootstrap_calls, 0)
        self.assertFalse((self.state / helper.PENDING).exists())
        self.assertEqual(list(self.state.glob('.ocmh-install-*')), [])

    def test_receipt_failure_resumes_previously_loaded_job_only(self):
        before = self.previous_install()
        write = helper.atomic_file
        failed = False
        def fail_once(path, *args):
            nonlocal failed
            if path == self.state / 'installation-receipt.json' and not failed:
                failed = True
                raise OSError('fixture disk failure')
            return write(path, *args)
        with mock.patch.object(helper, 'atomic_file', side_effect=fail_once), self.assertRaises(RuntimeError):
            self.invoke('update', launch=True)
        self.assert_prior_files(before)
        self.assertEqual(self.bootstrap_calls, 1, 'Only the prior job is launched after restoration')
        self.assertTrue(self.job_loaded)

    def test_write_failure_after_replacement_still_restores_exact_config(self):
        before = self.previous_install()
        write = helper.atomic_file
        failed = False
        def fail_after_replace(path, *args):
            nonlocal failed
            write(path, *args)
            if path == self.state / 'config.json' and not failed:
                failed = True
                raise OSError('fixture directory sync failure')
        with mock.patch.object(helper, 'atomic_file', side_effect=fail_after_replace), self.assertRaises(RuntimeError):
            self.invoke('update', launch=True, gateway='https://new.example')
        self.assert_prior_files(before)
        self.assertEqual(self.bootstrap_calls, 1)
        self.assertFalse((self.state / helper.PENDING).exists())

    def test_failed_update_does_not_launch_previously_unloaded_job(self):
        before = self.previous_install(); self.job_loaded = False; self.fail_bootstrap = True
        with self.assertRaises(RuntimeError): self.invoke('update', launch=True)
        self.assert_prior_files(before)
        self.assertEqual(self.bootstrap_calls, 1)
        self.assertFalse(self.job_loaded)

    def test_failed_legacy_migration_preserves_both_previous_apps(self):
        before = self.previous_install()
        legacy = self.state / 'OpenClaw Teams Transcription.app'
        shutil.copytree(self.source, legacy)
        (legacy / 'Contents/MacOS/ocmh').write_bytes(b'legacy helper')
        self.fail_bootstrap = True
        with self.assertRaises(RuntimeError): self.invoke('update', launch=True)
        self.assert_prior_files(before)
        self.assertEqual((legacy / 'Contents/MacOS/ocmh').read_bytes(), b'legacy helper')

    def test_failed_restore_retains_backups_and_blocks_all_lifecycle_actions(self):
        before = self.previous_install()
        original = self.command
        def fail_all_bootstraps(*args, **kwargs):
            if args[:2] == ('/bin/launchctl', 'bootstrap'):
                self.commands.append(args)
                raise subprocess.CalledProcessError(1, args)
            return original(*args, **kwargs)
        with mock.patch.object(self, 'command', side_effect=fail_all_bootstraps), self.assertRaisesRegex(RuntimeError, 'blocked for review'):
            self.invoke('update', launch=True)
        self.assert_prior_files(before)
        pending = self.state / helper.PENDING
        self.assertEqual(pending.stat().st_mode & 0o777, 0o600)
        stage = pathlib.Path(json.loads(pending.read_text())['stage'])
        self.assertEqual(stage.stat().st_mode & 0o777, 0o700)
        self.assertTrue((stage / 'file-0.before').exists())
        self.assertEqual((stage / 'file-0.before').stat().st_mode & 0o777, 0o600)
        self.commands.clear()
        for action in ['run', 'update', 'install', 'remove']:
            self.assertEqual(self.invoke(action), 2)
        self.assertEqual(self.commands, [])
        self.assertTrue(stage.exists())

    def test_terminated_installer_leaves_reviewable_backup_and_blocks_next_run(self):
        before = self.previous_install()
        # Execute the real installer in a child with every OS command stubbed.
        # Abrupt exit bypasses Python rollback and context-manager cleanup.
        program = '''
import importlib.util, os, pathlib, subprocess, sys
spec = importlib.util.spec_from_file_location('installer', sys.argv[1])
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
root, home, script = map(pathlib.Path, sys.argv[2:5])
os.environ['OPENCLAW_TEAMS_HOME'] = str(root)
pathlib.Path.home = classmethod(lambda cls: home)
helper.__file__ = str(script)
def command(*args, **kwargs):
    if args[:2] == ('/bin/launchctl', 'bootstrap'): os._exit(77)
    return subprocess.CompletedProcess(args, 0, b'', b'')
helper.command = command
def reject_signal(*args): raise AssertionError('Unexpected signal')
helper.os.kill = reject_signal
sys.platform = 'darwin'; sys.argv = ['helper.py', 'update', '--gateway', 'https://new.example']
helper.main()
'''
        result = subprocess.run([sys.executable, '-c', program, str(SCRIPT), str(self.state), str(self.home), str(self.script)], capture_output=True)
        self.assertEqual(result.returncode, 77, result.stderr.decode())
        marker = self.state / helper.PENDING
        stage = pathlib.Path(json.loads(marker.read_text())['stage'])
        self.assertEqual((stage / 'app-0.before/Contents/MacOS/ocmh').read_bytes(), b'old helper')
        self.assertEqual((stage / 'file-0.before').read_bytes(), before[self.state / 'config.json'][0])
        with (self.state / 'lifecycle.lock').open('a+b') as lease:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.commands.clear()
        self.assertEqual(self.invoke('run'), 2)
        self.assertEqual(self.commands, [])
        self.assertTrue(marker.exists())
        self.assertEqual(list(self.recordings.iterdir()), [])

    def test_concurrent_config_edit_is_preserved_and_blocks_rollback(self):
        before = self.previous_install()
        original = self.command
        edited = b'{"external":"fixture change"}'
        def fail_after_edit(*args, **kwargs):
            if args[:2] == ('/bin/launchctl', 'bootstrap'):
                (self.state / 'config.json').write_bytes(edited)
                raise subprocess.CalledProcessError(1, args)
            return original(*args, **kwargs)
        with mock.patch.object(self, 'command', side_effect=fail_after_edit), self.assertRaisesRegex(RuntimeError, 'blocked for review'):
            self.invoke('update', launch=True)
        self.assertEqual((self.state / 'config.json').read_bytes(), edited)
        stage = pathlib.Path(json.loads((self.state / helper.PENDING).read_text())['stage'])
        self.assertEqual((stage / 'file-0.before').read_bytes(), before[self.state / 'config.json'][0])
        self.assertEqual((stage / 'app-0.before/Contents/MacOS/ocmh').read_bytes(), b'old helper')

    def test_config_edit_during_old_helper_exit_is_not_overwritten(self):
        self.previous_install()
        original = self.command
        edited = b'{"external":"shutdown edit"}'
        def edit(*args, **kwargs):
            if args[0] == '/bin/ps': (self.state / 'config.json').write_bytes(edited)
            return original(*args, **kwargs)
        with mock.patch.object(self, 'command', side_effect=edit), self.assertRaisesRegex(RuntimeError, 'blocked for review'):
            self.invoke('update', launch=True)
        self.assertEqual((self.state / 'config.json').read_bytes(), edited)
        self.assertEqual((self.state / helper.NAME / 'Contents/MacOS/ocmh').read_bytes(), b'old helper')
        self.assertEqual(self.bootstrap_calls, 0)
        self.assertTrue((self.state / helper.PENDING).exists())

    def test_removed_pending_marker_does_not_discard_previous_app_backup(self):
        self.previous_install()
        original = self.command
        def remove_marker(*args, **kwargs):
            if args[:2] == ('/bin/launchctl', 'bootstrap'):
                (self.state / helper.PENDING).unlink()
                raise subprocess.CalledProcessError(1, args)
            return original(*args, **kwargs)
        with mock.patch.object(self, 'command', side_effect=remove_marker), self.assertRaisesRegex(RuntimeError, 'blocked for review'):
            self.invoke('update', launch=True)
        stages = list(self.state.glob('.ocmh-install-*'))
        self.assertEqual(len(stages), 1)
        self.assertEqual((stages[0] / 'app-0.before/Contents/MacOS/ocmh').read_bytes(), b'old helper')
        self.commands.clear()
        self.assertEqual(self.invoke('update'), 2)
        self.assertEqual(self.commands, [])

    def test_old_staging_paths_are_not_deleted_or_reused(self):
        for name in ['ocmh.app.next', 'ocmh.app.previous', '.ocmh-install-interrupted']:
            with self.subTest(name=name):
                stage = self.state / name; stage.mkdir()
                (stage / 'keep').write_bytes(b'backup')
                self.assertEqual(self.invoke('update'), 2)
                self.assertEqual((stage / 'keep').read_bytes(), b'backup')
                shutil.rmtree(stage)
        self.assertEqual(self.commands, [])

    def test_malformed_and_dangling_pending_markers_block_run(self):
        pending = self.state / helper.PENDING
        pending.write_bytes(b'{broken')
        self.assertEqual(self.invoke('run'), 2)
        pending.unlink(); pending.symlink_to(self.state / 'absent')
        self.assertEqual(self.invoke('run'), 2)
        self.assertTrue(pending.is_symlink())
        self.assertEqual(self.commands, [])

    def test_failed_code_verification_preserves_install_and_leaves_no_stage(self):
        before = self.previous_install()
        original = self.command
        def reject(*args, **kwargs):
            if args[0] == '/usr/bin/codesign': raise subprocess.CalledProcessError(1, args)
            return original(*args, **kwargs)
        with mock.patch.object(self, 'command', side_effect=reject), self.assertRaises(subprocess.CalledProcessError):
            self.invoke('update')
        self.assert_prior_files(before)
        self.assertFalse(any(c[:2] == ('/bin/launchctl', 'bootout') for c in self.commands))
        self.assertEqual(list(self.state.glob('.ocmh-install-*')), [])

    def test_bootout_failure_does_not_replace_or_signal_helper(self):
        before = self.previous_install()
        original = self.command
        def reject(*args, **kwargs):
            if args[:2] == ('/bin/launchctl', 'bootout'): return subprocess.CompletedProcess(args, 1, b'', b'')
            return original(*args, **kwargs)
        with mock.patch.object(self, 'command', side_effect=reject), self.assertRaises(RuntimeError): self.invoke('update', launch=True)
        self.assert_prior_files(before)
        self.assertEqual(self.bootstrap_calls, 0)
        self.assertTrue(self.job_loaded)
        self.assertFalse(any(c[0] == '/bin/ps' for c in self.commands))

    def test_unconfirmed_process_exit_blocks_relaunch_and_preserves_install(self):
        before = self.previous_install()
        # invoke's signal stub raises instead of touching an actual process.
        with mock.patch.object(helper, 'owned_pids', return_value=[99999]), self.assertRaisesRegex(RuntimeError, 'blocked for review'):
            self.invoke('update', launch=True)
        self.assert_prior_files(before)
        self.assertEqual(self.bootstrap_calls, 0)
        self.assertTrue((self.state / helper.PENDING).exists())

    def test_receipt_is_private_and_omits_gateway_credentials_and_url(self):
        self.previous_install()
        self.assertEqual(self.invoke('update'), 0)
        receipt = self.state / 'installation-receipt.json'
        self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
        self.assertTrue(json.loads(receipt.read_text())['gatewayConfigured'])
        for value in ['PRIVATE-old-token', 'old.example', 'token', 'PRIVATE-prior']:
            self.assertNotIn(value, receipt.read_text())
            self.assertNotIn(value, self.output)

    def test_linked_config_and_unrelated_agent_are_preserved(self):
        before = self.previous_install()
        config = self.state / 'config.json'
        config.rename(self.state / 'config-target')
        config.symlink_to(self.state / 'config-target')
        self.assertEqual(self.invoke('update'), 2)
        self.assertTrue(config.is_symlink())
        self.assertEqual((self.state / 'config-target').read_bytes(), before[config][0])
        config.unlink(); (self.state / 'config-target').rename(config)
        agent = self.home / 'Library/LaunchAgents' / f'{helper.LABEL}.plist'
        agent.write_bytes(plistlib.dumps({'Label': helper.LABEL, 'ProgramArguments': ['/bin/sh']}))
        data = agent.read_bytes()
        self.assertEqual(self.invoke('update'), 2)
        self.assertEqual(self.invoke('remove'), 2)
        self.assertEqual(self.invoke('run'), 2)
        self.assertEqual(agent.read_bytes(), data)
        self.assertEqual(self.commands, [])

if __name__ == '__main__':
    unittest.main()
