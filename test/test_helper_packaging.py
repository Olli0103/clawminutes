"""Packaging uses private fixtures and stub OS tools. No signing/keychain/network."""
import importlib.util
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/package-helper.py'
spec = importlib.util.spec_from_file_location('clawminutes_packager', SCRIPT)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='clawminutes-packaging-test-')
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name)
        self.root = self.base / 'checkout'; self.root.mkdir()
        self.output = self.base / 'output'
        self.binary = self.root / 'binary'; self.binary.write_bytes(b'synthetic arm64 helper')
        self.cloud = self.root / 'cloudflared'; self.cloud.write_bytes(b'synthetic arm64 tunnel')
        (self.root / 'package.json').write_text('{"version":"0.2.16"}')
        resources = self.root / 'native/Sources/quill/Resources'; resources.mkdir(parents=True)
        for name in ['ocmh-light.png', 'ocmh-dark.png']:
            (resources / name).write_bytes(b'fixture icon')
        info = {'CFBundleIdentifier': packager.BUNDLE_ID, 'OCMHUsesLifecycleLock': True, 'LSMinimumSystemVersion': '15.0'}
        (resources.parent / 'Info.plist').write_bytes(plistlib.dumps(info))
        (self.root / 'native/Helper.entitlements').write_bytes(plistlib.dumps({'com.apple.security.device.audio-input': True}))
        (self.root / 'notices').mkdir(); (self.root / 'notices/LICENSE').write_text('fixture notice')
        (self.root / 'scripts').mkdir(); (self.root / 'scripts/helper.py').write_text('fixture installer')
        self.commands = []
        self.notary_status = 'Accepted'
        self.fail_at = None

    def tool(self, *args):
        self.commands.append(args)
        if self.fail_at and self.fail_at(args):
            raise packager.PackagingError('Injected packaging tool failure')
        if args[0].endswith('/lipo'):
            return 'arm64'
        if '-r-' in args:
            return 'designated => identifier "ai.openclaw.teams-transcribe" and anchor trusted'
        if args[0] == str(self.binary):
            pathlib.Path(args[-1]).write_bytes(b'fixture image')
        if args[0].endswith('/iconutil'):
            pathlib.Path(args[-1]).write_bytes(b'fixture icns')
        if args[0].endswith('/ditto'):
            source, destination = pathlib.Path(args[-2]), pathlib.Path(args[-1])
            if '--keepParent' in args:
                source = source.parent
            packager.zip_distribution(source, destination)
        if 'notarytool' in args:
            return json.dumps({'status': self.notary_status})
        return ''

    def package(self, mode='ad-hoc'):
        signing = packager.Signing(mode) if mode == 'ad-hoc' else packager.Signing(mode, 'fixture-identity', team='ABCDEFGHIJ' if mode == 'developer-id' else None, profile='fixture-profile' if mode == 'developer-id' else None)
        return packager.package(self.root, self.output, signing, self.binary, self.cloud, run=self.tool)

    def prior(self):
        app = self.output / 'ocmh.app'; (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': packager.BUNDLE_ID}))
        (app / 'original').write_bytes(b'previous app')
        (self.output / 'recording-mac.zip').write_bytes(b'previous zip')

    def assert_prior(self):
        self.assertEqual((self.output / 'ocmh.app/original').read_bytes(), b'previous app')
        self.assertEqual((self.output / 'recording-mac.zip').read_bytes(), b'previous zip')

    def test_missing_input_and_failed_signature_preserve_both_previous_outputs(self):
        self.prior()
        self.binary.unlink()
        with self.assertRaises(OSError): self.package()
        self.assert_prior(); self.assertEqual(self.commands, [])
        self.binary.write_bytes(b'fixture')
        self.fail_at = lambda args: '--verify' in args
        with self.assertRaises(packager.PackagingError): self.package()
        self.assert_prior()
        self.assertFalse(list(self.output.glob('.ocmh-package-*')))

    def test_modes_fail_closed_before_any_tools(self):
        for args in [('local',), ('developer-id', 'identity'), ('ad-hoc', 'identity'), ('developer-id', '-', None, 'ABCDEFGHIJ', 'profile')]:
            with self.assertRaises(packager.PackagingError): packager.Signing(*args)
        self.assertEqual(self.commands, [])
        self.assertFalse(self.output.exists())

    def test_local_build_is_staged_versioned_and_contains_only_distribution_files(self):
        self.prior()
        result = self.package('local')
        self.assertEqual(result['version'], '0.2.16'); self.assertFalse(result['notarized'])
        app = self.output / 'ocmh.app'
        self.assertFalse((app / 'original').exists())
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleVersion'], '0.2.16')
        self.assertEqual(info['CFBundleIdentifier'], packager.BUNDLE_ID)
        self.assertEqual((app / 'Contents/MacOS/ocmh').stat().st_mode & 0o777, 0o755)
        with zipfile.ZipFile(self.output / 'recording-mac.zip') as archive:
            self.assertIn('scripts/helper.py', archive.namelist())
            self.assertIn('helper/ocmh.app/Contents/Resources/notices/LICENSE', archive.namelist())
            self.assertTrue(all(name.startswith(('helper/ocmh.app/', 'scripts/')) for name in archive.namelist()))
            self.assertEqual(archive.getinfo('helper/ocmh.app/Contents/MacOS/ocmh').external_attr >> 16 & 0o777, 0o755)
        self.assertFalse(list(self.output.glob('.ocmh-package-*')))
        self.assertFalse(any('security' in args[0] or 'local-signing.py' in ' '.join(args) or 'launchctl' in args[0] for args in self.commands))
        self.assertTrue(all(args[1] == 'export-icon' for args in self.commands if args[0] == str(self.binary)))

    def test_rejected_notarization_preserves_previous_distribution(self):
        self.prior(); self.notary_status = 'Invalid'
        with self.assertRaises(packager.PackagingError): self.package('developer-id')
        self.assert_prior()
        self.assertFalse(any('stapler' in args for args in self.commands))

    def test_developer_id_requires_runtime_audio_entitlement_chain_and_stapled_ticket(self):
        result = self.package('developer-id')
        self.assertTrue(result['notarized'])
        signing = [args for args in self.commands if '--sign' in args]
        self.assertEqual(len(signing), 2)
        for args in signing:
            self.assertIn('--timestamp', args); self.assertIn('runtime', args)
        self.assertIn('--entitlements', signing[-1]); self.assertNotIn('--entitlements', signing[0])
        chain_checks = [args for args in self.commands if '-R' in args]
        self.assertEqual(len(chain_checks), 4)
        self.assertTrue(all('ABCDEFGHIJ' in args[-2] and '100.6.1.13' in args[-2] for args in chain_checks))
        self.assertTrue(any('stapler' in args and 'validate' in args for args in self.commands))
        self.assertTrue(any(args[0].endswith('/spctl') for args in self.commands))
        self.assertTrue(any('--sequesterRsrc' in args for args in self.commands))

    def test_ticket_or_gatekeeper_failure_preserves_prior_outputs(self):
        for marker in ['validate', '--assess']:
            with self.subTest(marker=marker):
                if not self.output.exists(): self.prior()
                self.fail_at = lambda args, marker=marker: marker in args
                with self.assertRaises(packager.PackagingError): self.package('developer-id')
                self.assert_prior()

    def test_publication_failure_rolls_back_both_outputs(self):
        self.prior()
        stage = self.base / 'stage'; stage.mkdir()
        app = stage / 'new.app'; app.mkdir(); (app / 'new').write_text('new')
        archive = stage / 'new.zip'; archive.write_bytes(b'new zip')
        def replace(source, destination):
            if source == archive: raise OSError('injected publication failure')
            os.replace(source, destination)
        with self.assertRaises(packager.PackagingError):
            packager.publish(app, archive, self.output, stage, replace=replace)
        self.assert_prior()

    def test_rollback_failure_keeps_prior_backups_for_manual_recovery(self):
        self.prior()
        with self.assertRaises(OSError):
            with packager.staging_directory(self.output) as stage:
                app = stage / 'new.app'; app.mkdir()
                archive = stage / 'new.zip'; archive.write_bytes(b'new')
                def replace(source, destination):
                    if source == archive or source.name.startswith('previous-'): raise OSError('injected')
                    os.replace(source, destination)
                packager.publish(app, archive, self.output, stage, replace=replace)
        self.assertTrue((stage / 'previous-ocmh.app/original').exists())
        self.assertTrue((stage / 'previous-recording-mac.zip').exists())
        with self.assertRaises(packager.PackagingError): self.package()

    def test_installed_root_and_links_and_unrelated_apps_are_not_replaced(self):
        self.output.mkdir()
        (self.output / 'config.json').write_text('private configuration')
        with self.assertRaises(packager.PackagingError): self.package()
        self.assertEqual(self.commands, [])
        (self.output / 'config.json').unlink()
        target = self.base / 'outside'; target.mkdir()
        (target / 'kept').write_text('kept')
        (self.output / 'ocmh.app').symlink_to(target, target_is_directory=True)
        with self.assertRaises(packager.PackagingError): self.package()
        self.assertEqual((target / 'kept').read_text(), 'kept')
        (self.output / 'ocmh.app').unlink()
        shutil.rmtree(self.output); self.prior()
        info = self.output / 'ocmh.app/Contents/Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unrelated'}))
        with self.assertRaises(packager.PackagingError): self.package()
        self.assertEqual(plistlib.loads(info.read_bytes())['CFBundleIdentifier'], 'unrelated')

    def test_npm_whitelist_excludes_interrupted_stages_signing_and_caches(self):
        manifest = json.loads((SCRIPT.parent.parent / 'package.json').read_text())
        manifest = {key: manifest[key] for key in ['name', 'version', 'files']}
        checkout = self.base / 'pack-audit'; checkout.mkdir()
        (checkout / 'package.json').write_text(json.dumps(manifest))
        included = ['helper/ocmh.app/Contents/Info.plist', 'helper/recording-mac.zip', 'native/Helper.entitlements', 'scripts/helper.py']
        excluded = ['helper/.packaging.lock', 'helper/.ocmh-package-stale/previous-ocmh.app/private', 'helper/signing/keychain-password', 'scripts/__pycache__/helper.pyc', 'signing/secret.pem', 'evidence/private.json', 'config.json']
        for name in included + excluded:
            path = checkout / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('synthetic sentinel')
        result = subprocess.run(['npm', 'pack', '--dry-run', '--ignore-scripts', '--json', '--cache', str(self.base / 'npm-cache')], cwd=checkout, capture_output=True, text=True, check=True)
        files = {entry['path'] for entry in json.loads(result.stdout)[0]['files']}
        self.assertTrue(set(included).issubset(files))
        self.assertFalse(set(excluded) & files)


if __name__ == '__main__': unittest.main()
