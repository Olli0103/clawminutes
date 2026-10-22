#!/usr/bin/env python3
"""Stage the plugin-owned helper. Never install, launch or modify a keychain."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

BUNDLE_ID = 'ai.openclaw.teams-transcribe'


class PackagingError(Exception):
    pass


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Commands can print private build paths and certificate/profile names.
        raise PackagingError(f'{pathlib.Path(args[0]).name} failed. Previous distribution preserved.')
    return result.stdout + result.stderr


class Signing:
    def __init__(self, mode, identity=None, keychain=None, team=None, profile=None):
        self.mode, self.identity, self.keychain = mode, identity, keychain
        self.team, self.profile = team, profile
        if mode not in ['ad-hoc', 'local', 'developer-id']:
            raise PackagingError('Select an explicit signing mode: ad-hoc, local or developer-id.')
        if mode == 'ad-hoc':
            if identity or keychain or team or profile:
                raise PackagingError('Ad-hoc mode cannot carry signing or notarization credentials.')
            self.identity = '-'
        elif not identity or identity == '-' or any(c in identity for c in '\n\r\0'):
            raise PackagingError('This mode requires an explicit signing identity. No ad-hoc fallback is allowed.')
        if mode == 'developer-id':
            if not team or not re.fullmatch(r'[A-Z0-9]{10}', team) or not profile:
                raise PackagingError('Developer ID distribution requires a Team ID and an existing notarytool keychain profile.')
        elif team or profile:
            raise PackagingError('Notarization is available only in developer-id mode.')

    def sign(self, path, run, entitlements=None):
        args = ['/usr/bin/codesign', '--force', '--sign', self.identity]
        if self.keychain:
            args += ['--keychain', str(self.keychain)]
        if self.mode == 'developer-id':
            args += ['--options', 'runtime', '--timestamp']
        if entitlements is not None:
            args += ['--entitlements', str(entitlements)]
        run(*args, str(path))

    def verify(self, app, run):
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
        requirement = run('/usr/bin/codesign', '-d', '-r-', str(app))
        if self.mode != 'ad-hoc' and ('cdhash' in requirement.lower() or 'designated =>' not in requirement):
            raise PackagingError('The helper has no stable designated requirement. Previous distribution preserved.')
        if self.mode == 'developer-id':
            # Verify the chain/type/team, not merely a printed certificate name.
            expected = (f'anchor apple generic and certificate leaf[subject.OU] = "{self.team}" '
                        'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
            for path in [app, app / 'Contents/Resources/cloudflared']:
                run('/usr/bin/codesign', '--verify', '--strict', '-R', '= ' + expected, str(path))
        return requirement.strip()

    def notarize(self, app, stage, run):
        if self.mode != 'developer-id':
            return
        submission = stage / 'notary-submission.zip'
        run('/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(submission))
        response = run('/usr/bin/xcrun', 'notarytool', 'submit', str(submission), '--keychain-profile', self.profile,
                       '--wait', '--output-format', 'json')
        try:
            accepted = json.loads(response).get('status') == 'Accepted'
        except (ValueError, AttributeError):
            accepted = False
        if not accepted:
            raise PackagingError('Apple notarization did not return Accepted. Previous distribution preserved.')
        run('/usr/bin/xcrun', 'stapler', 'staple', str(app))
        run('/usr/bin/xcrun', 'stapler', 'validate', str(app))
        self.verify(app, run)
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', str(app))


def regular(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise PackagingError('Packaging inputs must be regular files, without symbolic links.')
    return path


def copy_tree(source, destination):
    # Signing a copy must never reach files outside the declared input tree.
    if source.is_symlink() or any(p.is_symlink() for p in source.rglob('*')):
        raise PackagingError('A linked packaging input requires review.')
    shutil.copytree(source, destination)


def zip_distribution(distribution, archive):
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as output:
        for path in sorted(distribution.rglob('*')):
            if path.is_file():
                regular(path)
                output.write(path, path.relative_to(distribution).as_posix())
    with zipfile.ZipFile(archive) as check:
        if check.testzip() is not None:
            raise PackagingError('Distribution ZIP failed its integrity check.')


def validate_previous(app, archive):
    if app.is_symlink() or archive.is_symlink():
        raise PackagingError('Linked output paths require review; nothing replaced.')
    if app.exists():
        if any(p.is_symlink() for p in app.rglob('*')):
            raise PackagingError('Linked contents in the previous application require review.')
        try:
            info = plistlib.loads(regular(app / 'Contents/Info.plist').read_bytes())
        except (OSError, ValueError):
            raise PackagingError('Previous application cannot be verified; nothing replaced.') from None
        if info.get('CFBundleIdentifier') != BUNDLE_ID:
            raise PackagingError('An unrelated application occupies the output path; nothing replaced.')
    if archive.exists():
        regular(archive)


def publish(app, archive, output, stage, replace=os.replace):
    """Rollback both artifacts on ordinary errors; never delete prior builds first."""
    targets = [(app, output / 'ocmh.app'), (archive, output / 'recording-mac.zip')]
    saved, installed = [], []
    try:
        for source, destination in targets:
            if destination.exists():
                backup = stage / ('previous-' + destination.name)
                replace(destination, backup)
                saved.append((backup, destination))
            replace(source, destination)
            installed.append(destination)
    except OSError:
        for destination in reversed(installed):
            if destination.is_dir():
                shutil.rmtree(destination)
            else:
                destination.unlink()
        for backup, destination in reversed(saved):
            replace(backup, destination)
        raise PackagingError('Could not publish the distribution. Previous artifacts restored.') from None


@contextlib.contextmanager
def staging_directory(output):
    stage = pathlib.Path(tempfile.mkdtemp(prefix='.ocmh-package-', dir=output))
    try:
        yield stage
    except BaseException:
        # A rollback error must never erase the only remaining prior build.
        if not any(stage.glob('previous-*')):
            shutil.rmtree(stage)
        raise
    else:
        shutil.rmtree(stage)


def protect_installed_output(output):
    installed = pathlib.Path(os.environ.get('OPENCLAW_TEAMS_HOME', pathlib.Path.home() / '.openclaw/teams-transcribe')).expanduser().resolve()
    candidate = output.resolve()
    if candidate == installed or installed in candidate.parents or any((output / name).exists() for name in ['config.json', 'lifecycle.lock', 'installation-receipt.json']):
        raise PackagingError('Packaging cannot target an installed helper. Use a separate build-output directory.')


def package(root, output, signing, binary, cloudflared, run=command):
    # Validate before making or replacing any output. No keychain helper is run.
    protect_installed_output(output)
    regular(binary); regular(cloudflared)
    version = json.loads((root / 'package.json').read_text())['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise PackagingError('Package version must contain three numeric components.')
    info = plistlib.loads((root / 'native/Sources/quill/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('OCMHUsesLifecycleLock') is not True:
        raise PackagingError('Native helper identity or lifecycle protection is invalid.')
    if output.is_symlink():
        raise PackagingError('Linked output directory requires review.')
    output.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output / '.packaging.lock', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a+b') as lease:
        if not stat.S_ISREG(os.fstat(lease.fileno()).st_mode):
            raise PackagingError('Invalid packaging lock.')
        try:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PackagingError('Another packager owns this output. Existing artifacts preserved.') from None
        if any(output.glob('.ocmh-package-*')):
            raise PackagingError('An interrupted packaging stage requires review before another build.')
        validate_previous(output / 'ocmh.app', output / 'recording-mac.zip')
        with staging_directory(output) as stage:
            distribution = stage / 'distribution'
            app = distribution / 'helper/ocmh.app'
            resources = app / 'Contents/Resources'
            executable = app / 'Contents/MacOS/ocmh'
            executable.parent.mkdir(parents=True); resources.mkdir()
            shutil.copy2(binary, executable); executable.chmod(0o755)
            run('/usr/bin/strip', '-S', str(executable))
            if str(root).encode() in executable.read_bytes():
                raise PackagingError('Packaged executable still contains the private build directory.')
            for path in [executable, cloudflared]:
                if 'arm64' not in run('/usr/bin/lipo', '-archs', str(path)).split():
                    raise PackagingError('The helper and cloudflared must contain arm64 code.')
            for name in ['ocmh-light.png', 'ocmh-dark.png']:
                shutil.copy2(regular(root / 'native/Sources/quill/Resources' / name), resources / name)
            shutil.copy2(cloudflared, resources / 'cloudflared'); (resources / 'cloudflared').chmod(0o755)
            copy_tree(root / 'notices', resources / 'notices')
            info.update(CFBundleShortVersionString=version, CFBundleVersion=version, CFBundleIconFile='ocmh')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            icons = stage / 'ocmh.iconset'; icons.mkdir()
            for dimension in [16, 32, 128, 256, 512]:
                for scale in [1, 2]:
                    name = f'icon_{dimension}x{dimension}{"@2x" if scale == 2 else ""}.png'
                    # Invoke only the explicit icon-export subcommand, never run/capture.
                    run(str(binary), 'export-icon', '--size', str(dimension * scale), '--output', str(icons / name))
            run('/usr/bin/iconutil', '-c', 'icns', str(icons), '-o', str(resources / 'ocmh.icns'))
            signing.sign(resources / 'cloudflared', run)
            entitlement_path = None
            if signing.mode == 'developer-id':
                entitlement_path = regular(root / 'native/Helper.entitlements')
                if plistlib.loads(entitlement_path.read_bytes()) != {'com.apple.security.device.audio-input': True}:
                    raise PackagingError('Release entitlements must contain only the required audio-input capability.')
            signing.sign(app, run, entitlements=entitlement_path)
            signing.verify(app, run)
            signing.notarize(app, stage, run)
            scripts = distribution / 'scripts'; scripts.mkdir()
            shutil.copy2(regular(root / 'scripts/helper.py'), scripts / 'helper.py')
            archive = stage / 'recording-mac.zip'
            if signing.mode == 'developer-id':
                # ditto preserves the stapled ticket/resource metadata in the ZIP.
                run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', str(distribution), str(archive))
                with zipfile.ZipFile(archive) as check:
                    if check.testzip() is not None or 'helper/ocmh.app/Contents/Info.plist' not in check.namelist():
                        raise PackagingError('Notarized distribution ZIP failed verification.')
            else:
                zip_distribution(distribution, archive)
            validate_previous(output / 'ocmh.app', output / 'recording-mac.zip')
            publish(app, archive, output, stage)
    return {'bundleID': BUNDLE_ID, 'version': version, 'signingMode': signing.mode,
            'notarized': signing.mode == 'developer-id',
            'helperSHA256': hashlib.sha256((output / 'ocmh.app/Contents/MacOS/ocmh').read_bytes()).hexdigest(),
            'archiveSHA256': hashlib.sha256((output / 'recording-mac.zip').read_bytes()).hexdigest()}


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', required=True, choices=['ad-hoc', 'local', 'developer-id'])
    parser.add_argument('--output', type=pathlib.Path, default=root / 'helper')
    parser.add_argument('--binary', type=pathlib.Path, default=root / 'native/.build/release/ocmh')
    parser.add_argument('--cloudflared', type=pathlib.Path, default=os.environ.get('OPENCLAW_TEAMS_CLOUDFLARED') or shutil.which('cloudflared'))
    parser.add_argument('--identity', default=os.environ.get('OPENCLAW_TEAMS_SIGNING_IDENTITY'))
    parser.add_argument('--keychain', default=os.environ.get('OPENCLAW_TEAMS_SIGNING_KEYCHAIN'))
    parser.add_argument('--team-id', default=os.environ.get('OPENCLAW_TEAMS_TEAM_ID'))
    parser.add_argument('--notary-profile', default=os.environ.get('OPENCLAW_TEAMS_NOTARY_PROFILE'), help='Existing profile. Developer ID mode uploads the staged app to Apple.')
    args = parser.parse_args()
    try:
        signing = Signing(args.mode, args.identity, args.keychain, args.team_id, args.notary_profile)
        if not args.cloudflared:
            raise PackagingError('Supply --cloudflared or install cloudflared on PATH.')
        report = package(root, args.output.absolute(), signing, args.binary.absolute(), args.cloudflared.resolve())
    except (PackagingError, OSError, ValueError, KeyError) as error:
        # Do not echo raw OS errors containing build or credential paths.
        parser.error(str(error) if isinstance(error, PackagingError) else 'Packaging input/output could not be verified. Inspect locally; previous distribution preserved.')
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    main()
