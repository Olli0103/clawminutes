import contextlib
import io
import pathlib
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/local-signing.py'


class LocalSigningTests(unittest.TestCase):
    def test_original_keychain_wins_over_rejected_recovery_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            state = home / '.openclaw/teams-transcribe/signing'
            state.mkdir(parents=True)
            original = state / 'ocmh-signing.keychain-db'
            recovered = state / 'ocmh-signing-recovered.keychain-db'
            original.write_bytes(b'original-encrypted-keychain')
            recovered.write_bytes(b'rejected-recovery-copy')
            (state / 'keychain-password').write_text('fixture-only')
            calls = []

            def security(args, **kwargs):
                calls.append(args)
                if args[1] == 'unlock-keychain' and args[-1] == str(recovered):
                    return subprocess.CompletedProcess(args, 1, '', 'incorrect passphrase')
                return subprocess.CompletedProcess(args, 0, '', '')

            with patch('pathlib.Path.home', return_value=home), patch('os.geteuid', return_value=501), patch('subprocess.run', side_effect=security), contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(SCRIPT), run_name='__main__')
            self.assertEqual(calls[0][-1], str(original))
            self.assertEqual(original.read_bytes(), b'original-encrypted-keychain')
            self.assertEqual(recovered.read_bytes(), b'rejected-recovery-copy')

    def test_sudo_is_rejected_before_creating_state(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            with patch('pathlib.Path.home', return_value=home), patch('os.geteuid', return_value=0), patch('subprocess.run') as command:
                with self.assertRaisesRegex(SystemExit, 'without sudo'):
                    runpy.run_path(str(SCRIPT), run_name='__main__')
                command.assert_not_called()
            self.assertFalse((home / '.openclaw').exists())

    def test_failed_unlock_preserves_original_without_copy_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            state = home / '.openclaw/teams-transcribe/signing'
            state.mkdir(parents=True)
            original = state / 'ocmh-signing.keychain-db'
            original.write_bytes(b'encrypted-keychain')
            (state / 'keychain-password').write_text('fixture-only')
            failure = subprocess.CompletedProcess([], 1, '', 'incorrect passphrase')
            with patch('pathlib.Path.home', return_value=home), patch('os.geteuid', return_value=501), patch('subprocess.run', return_value=failure) as command:
                with self.assertRaisesRegex(SystemExit, 'preserved'):
                    runpy.run_path(str(SCRIPT), run_name='__main__')
                self.assertEqual(command.call_count, 1)
            self.assertEqual(original.read_bytes(), b'encrypted-keychain')
            self.assertFalse((state / 'ocmh-signing-recovered.keychain-db').exists())


if __name__ == '__main__':
    unittest.main()
