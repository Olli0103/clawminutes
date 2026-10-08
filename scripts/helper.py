#!/usr/bin/env python3
"""Lifecycle installer shipped by the teams-transcribe plugin. No OpenClaw CLI."""
import argparse, contextlib, fcntl, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys, signal, time

LABEL = 'ai.openclaw.teams-transcribe'
NAME = 'ocmh.app'

def command(*args, check=True):
    return subprocess.run(args, check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def main():
    parser = argparse.ArgumentParser(description='Install, run, update or remove the plugin-owned Mac helper. Recordings are preserved.')
    parser.add_argument('action', choices=['install', 'update', 'run', 'remove'])
    parser.add_argument('--gateway')
    parser.add_argument('--authentication', choices=['cloudflare', 'token'], default='cloudflare')
    parser.add_argument('--no-launch', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin': parser.error('The recording helper requires macOS 15 or later.')
    root = pathlib.Path(os.environ.get('OPENCLAW_TEAMS_HOME', pathlib.Path.home()/'.openclaw/teams-transcribe')).expanduser()
    try:
        settings = json.loads((root/'config.json').read_text()) if (root/'config.json').exists() else {}
        if not isinstance(settings, dict): raise ValueError('Configuration must be an object')
    except (OSError, ValueError):
        parser.error('Could not verify helper configuration. Helper left running.')
    if args.action == 'run':
        perform(args, root, settings, parser)
    else:
        with installation_lease(root, settings, parser) as allow_orphans:
            perform(args, root, settings, parser, allow_orphans=allow_orphans)


def owned_pids(app):
    expected = [str(app/'Contents/MacOS'/name) for name in ['ocmh', 'quill']]
    rows = command('/bin/ps', '-axo', 'pid=,command=').stdout.decode().splitlines()
    result = []
    for row in rows:
        pieces = row.strip().split(None, 1)
        if len(pieces) == 2 and any(pieces[1] == executable or pieces[1].startswith(executable + ' ') for executable in expected):
            result.append(int(pieces[0]))
    return result


def check_recording_metadata(root, settings, parser, *, allow_orphans=False):
    folders = {root/'recordings'}
    if settings.get('recordings_dir'):
        folders.add(pathlib.Path(settings['recordings_dir']).expanduser())
    for folder in folders:
        for metadata in folder.glob('*/meta.json'):
            try:
                status = json.loads(metadata.read_text())
                if not isinstance(status, dict): raise ValueError('Metadata must be an object')
            except (OSError, ValueError):
                parser.error('Could not verify recording status. Helper left running.')
            if status.get('status') == 'recording' and not allow_orphans:
                parser.error('A recording is active or unfinished. Finish or recover it before updating or removing the helper. Recording left running.')


@contextlib.contextmanager
def installation_lease(root, settings, parser):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(root/'lifecycle.lock', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a+b') as lease:
        try:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error('Recording, transcription, archiving or another installer is active. Try again after it finishes. Helper left running.')
        allow_orphans = False
        # Older helpers cannot participate in this lock. Refuse to interrupt a
        # running copy whose idle state cannot be established by this protocol.
        for app in [root/NAME, root/'OpenClaw Teams Transcription.app']:
            if not app.exists(): continue
            try:
                info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
                if info.get('CFBundleIdentifier') != LABEL: parser.error('An unrelated application occupies the helper path. It was left untouched.')
                supports_lease = info.get('OCMHUsesLifecycleLock') is True
                allow_orphans = allow_orphans or supports_lease
            except (OSError, ValueError):
                parser.error('Could not verify installed helper capabilities. Helper left running.')
            if not supports_lease and owned_pids(app):
                parser.error('This running helper predates lifecycle protection. Once recording and transcription finish, quit it before this first protected update or removal.')
        # An exclusive work lease proves that protected captures/processing
        # have ended. Stale metadata alone must not prevent a recovery update.
        # Without a known protected install, retain the conservative legacy gate.
        check_recording_metadata(root, settings, parser, allow_orphans=allow_orphans)
        yield allow_orphans


def perform(args, root, settings, parser, *, allow_orphans=False):
    app, agent = root/NAME, pathlib.Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    legacy = root/'OpenClaw Teams Transcription.app'
    if legacy.exists():
        identity = plistlib.loads((legacy/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
        if identity != LABEL: parser.error('An unrelated application occupies the old helper path. It was left untouched.')
    domain = f'gui/{os.getuid()}'
    def stop_owned_app():
        # LaunchServices owns the app process; stop only this exact plugin binary.
        pids = owned_pids(app)
        for pid in pids:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        deadline = time.monotonic() + 5
        while pids:
            remaining = []
            for pid in pids:
                try: os.kill(pid, 0); remaining.append(pid)
                except ProcessLookupError: pass
            if not remaining: return
            if time.monotonic() >= deadline:
                parser.error('The idle helper did not exit. Update stopped; application and recordings preserved.')
            pids = remaining
            time.sleep(.05)

    if args.action == 'remove':
        command('/bin/launchctl', 'bootout', domain, str(agent), check=False)
        stop_owned_app()
        agent.unlink(missing_ok=True)
        if app.exists(): shutil.rmtree(app)
        if legacy.exists(): shutil.rmtree(legacy)
        print(json.dumps({'removed': True, 'recordingsPreserved': str(root/'recordings'), 'configurationPreserved': str(root/'config.json')}))
        return
    if args.action == 'run':
        if command('/bin/launchctl', 'print', f'{domain}/{LABEL}', check=False).returncode:
            command('/bin/launchctl', 'bootstrap', domain, str(agent))
        else:
            command('/bin/launchctl', 'kickstart', f'{domain}/{LABEL}')
        print(json.dumps({'running': True, 'pluginOwner': 'teams-transcribe'}))
        return
    base = pathlib.Path(__file__).resolve().parents[1]
    source = base/'helper'/NAME
    if not source.exists(): source = base/NAME
    if not (source/'Contents/MacOS/ocmh').is_file(): parser.error('The plugin-bundled helper is missing.')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = root/'config.json'
    if args.gateway:
        from urllib.parse import urlsplit
        url = urlsplit(args.gateway)
        if url.username or url.password or url.query or url.fragment or url.path not in ['', '/'] or (url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ['localhost', '127.0.0.1', '::1'])):
            parser.error('Use an HTTPS Gateway origin or loopback HTTP without credentials.')
        settings['gateway'] = {'url': args.gateway, 'authentication': args.authentication}
    settings.setdefault('recordings_dir', str(root/'recordings'))
    settings.setdefault('transcription', {'enabled': True, 'engine': 'parakeet'})
    settings.setdefault('speaker_voice_memory', False)
    settings.setdefault('auto_meeting_captions', False)
    settings.setdefault('post_processing', {'mode': 'off'})
    staged = root/(NAME+'.next')
    if staged.exists(): shutil.rmtree(staged)
    shutil.copytree(source, staged)
    command('/usr/bin/codesign', '--verify', '--strict', str(staged))
    # The exclusive lease also prevents a new native operation after this check.
    check_recording_metadata(root, settings, parser, allow_orphans=allow_orphans)
    command('/bin/launchctl', 'bootout', domain, str(agent), check=False)
    stop_owned_app()
    previous = root/(NAME+'.previous')
    if previous.exists(): shutil.rmtree(previous)
    if legacy.exists(): shutil.rmtree(legacy)
    if app.exists(): app.rename(previous)
    staged.rename(app)
    temp = config.with_suffix('.json.next')
    temp.write_text(json.dumps(settings, indent=2)); temp.chmod(0o600); temp.replace(config)
    agent.parent.mkdir(parents=True, exist_ok=True)
    plist = {'Label': LABEL, 'ProgramArguments': [str(app/'Contents/MacOS/ocmh'), 'run', '--out', settings['recordings_dir']],
             'EnvironmentVariables': {'OPENCLAW_TEAMS_HOME': str(root)}, 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 10,
             'StandardErrorPath': str(root/'helper.log'), 'StandardOutPath': str(root/'helper.stdout.log')}
    agent.write_bytes(plistlib.dumps(plist)); agent.chmod(0o600)
    try:
        if not args.no_launch: command('/bin/launchctl', 'bootstrap', domain, str(agent))
    except subprocess.CalledProcessError:
        shutil.rmtree(app)
        if previous.exists(): previous.rename(app)
        raise RuntimeError('Helper launch failed. Previous application restored. Recordings preserved.') from None
    if previous.exists(): shutil.rmtree(previous)
    binary = app/'Contents/MacOS/ocmh'
    receipt = {'pluginOwner': 'teams-transcribe', 'version': plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], 'helperSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
               'gateway': settings.get('gateway', {}), 'localOpenClawRequired': False, 'launched': not args.no_launch}
    (root/'installation-receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))

if __name__ == '__main__':
    main()
