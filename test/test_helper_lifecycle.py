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
        return subprocess.CompletedProcess(args, 0, self.ps_output if args[0] == '/bin/ps' else b'', b'')

    def invoke(self, action):
        with mock.patch.dict(os.environ, {'OPENCLAW_TEAMS_HOME': str(self.state)}), \
             mock.patch.object(pathlib.Path, 'home', return_value=self.home), \
             mock.patch.object(helper, 'command', self.command), \
             mock.patch.object(helper, '__file__', str(self.script)), \
             mock.patch.object(helper.os, 'kill', side_effect=AssertionError('Unexpected process signal')), \
             mock.patch.object(sys, 'platform', 'darwin'), \
             mock.patch.object(sys, 'argv', ['helper.py', action, '--no-launch']), \
             contextlib.redirect_stderr(io.StringIO()) as errors, contextlib.redirect_stdout(io.StringIO()):
            try:
                helper.main()
            except SystemExit as error:
                self.errors = errors.getvalue()
                return error.code
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

if __name__ == '__main__':
    unittest.main()
