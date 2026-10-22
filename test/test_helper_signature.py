"""Read-only signature checks use stub tools, never a real keychain or app."""
import contextlib
import importlib.util
import io
import pathlib
import plistlib
import tempfile
import subprocess
import sys
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/check-signature.py'
spec = importlib.util.spec_from_file_location('clawminutes_signature', SCRIPT)
signature = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signature)


class SignatureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='clawminutes-signature-test-')
        self.addCleanup(self.temporary.cleanup)
        self.app = pathlib.Path(self.temporary.name) / 'ocmh.app'
        (self.app / 'Contents').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': signature.BUNDLE_ID}))
        self.commands = []

    def test_code_seal_is_verified_before_identity_is_displayed(self):
        def tool(*args):
            self.commands.append(args)
            return 'Executable=PRIVATE-PATH\ndesignated => identifier "ai.openclaw.teams-transcribe" and anchor trusted\n'
        result = signature.requirement(self.app, run=tool)
        self.assertEqual(self.commands[0][1:4], ('--verify', '--deep', '--strict'))
        self.assertTrue(result.startswith('designated =>')); self.assertNotIn('PRIVATE', result)

    def test_broken_signature_cannot_pass_by_displaying_a_stable_requirement(self):
        def tool(*args):
            if '--verify' in args: raise signature.SignatureError('broken code seal')
            self.fail('Must not reach requirement display after failed verification')
        with self.assertRaises(signature.SignatureError): signature.requirement(self.app, run=tool)

    def test_hash_identity_missing_requirement_and_wrong_bundle_are_rejected(self):
        for display in ['designated => cdhash abcdef', 'no designated requirement']:
            with self.assertRaises(signature.SignatureError): signature.requirement(self.app, run=lambda *args: display)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unrelated'}))
        with self.assertRaises(signature.SignatureError): signature.requirement(self.app, run=lambda *args: self.fail('Unexpected tool'))

    def test_cli_compares_verified_reference_and_preserves_permission_uncertainty(self):
        previous = self.app.parent / 'previous.app'
        (previous / 'Contents').mkdir(parents=True)
        (previous / 'Contents/Info.plist').write_bytes((self.app / 'Contents/Info.plist').read_bytes())
        for changed in [False, True]:
            calls = []
            def tool(args, **kwargs):
                calls.append(args)
                anchor = 'changed' if changed and args[-1] == str(previous) else 'same'
                return subprocess.CompletedProcess(args, 0, '', f'designated => identifier "ai.openclaw.teams-transcribe" and anchor {anchor}')
            output, errors = io.StringIO(), io.StringIO()
            with mock.patch.object(signature.subprocess, 'run', side_effect=tool), mock.patch.object(sys, 'argv', ['check-signature.py', '--app', str(self.app), '--reference', str(previous)]), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                if changed:
                    with self.assertRaises(SystemExit) as failure: signature.main()
                    self.assertEqual(failure.exception.code, 2)
                else:
                    signature.main()
                    self.assertIn('same designated requirement', output.getvalue())
                    self.assertIn('needs_evidence', output.getvalue())
            self.assertEqual(len([args for args in calls if '--verify' in args]), 2)
            self.assertTrue(all('-R' in args for args in calls if '--verify' in args))


if __name__ == '__main__': unittest.main()
