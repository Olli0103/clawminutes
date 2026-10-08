#!/usr/bin/env python3
"""Lifecycle installer shipped by the teams-transcribe plugin. No OpenClaw CLI."""
import argparse, contextlib, fcntl, hashlib, json, os, pathlib, plistlib, shutil, stat, subprocess, sys, signal, tempfile, time

LABEL = 'ai.openclaw.teams-transcribe'
NAME = 'ocmh.app'
PENDING = 'installation-pending.json'


def present(path):
    return os.path.lexists(path)


def file_snapshot(path):
    """Reject links and special files; preserve exact bytes and permission bits."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode): raise RuntimeError('Installer file is not a regular file.')
        return stream.read(), stat.S_IMODE(info.st_mode)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


def atomic_file(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix='.ocmh-write-', dir=path.parent)
    temporary = pathlib.Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def directory_identity(path):
    try: info = path.lstat()
    except FileNotFoundError: return None
    if not stat.S_ISDIR(info.st_mode): raise RuntimeError('Installer application path is not a directory.')
    return info.st_dev, info.st_ino


def require_resolved_install(root, parser):
    leftovers = [root/PENDING, root/(NAME+'.next'), root/(NAME+'.previous')]
    leftovers.extend(root.glob('.ocmh-install-*'))
    if any(present(path) for path in leftovers):
        parser.error('An interrupted helper update needs review. Application, backups and recordings were left untouched. See installation-pending.json and the installer recovery guide.')

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
    def read_settings():
        try:
            snapshot = file_snapshot(root/'config.json')
            settings = json.loads(snapshot[0]) if snapshot else {}
            if not isinstance(settings, dict): raise ValueError('Configuration must be an object')
            return settings
        except (OSError, ValueError, RuntimeError):
            parser.error('Could not verify helper configuration. Helper left running.')
    require_resolved_install(root, parser)
    settings = read_settings()
    with installation_lease(root, settings, parser) as allow_orphans:
        require_resolved_install(root, parser)
        perform(args, root, read_settings(), parser, allow_orphans=allow_orphans)


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
    directory_identity(root)
    descriptor = os.open(root/'lifecycle.lock', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a+b') as lease:
        if not stat.S_ISREG(os.fstat(lease.fileno()).st_mode): parser.error('Invalid lifecycle lock. Helper left running.')
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


def unload_job(domain):
    result = command('/bin/launchctl', 'bootout', f'{domain}/{LABEL}', check=False)
    if result.returncode and not command('/bin/launchctl', 'print', f'{domain}/{LABEL}', check=False).returncode:
        raise RuntimeError('The helper job did not unload. Application and recordings preserved.')


def verify_agent(snapshot, app, legacy, parser):
    if not snapshot: return
    old_agent = plistlib.loads(snapshot[0])
    arguments = old_agent.get('ProgramArguments', [])
    allowed = {str(folder/'Contents/MacOS'/name) for folder in [app, legacy] for name in ['ocmh', 'quill']}
    if old_agent.get('Label') != LABEL or not isinstance(arguments, list) or not arguments or arguments[0] not in allowed:
        parser.error('An unrelated LaunchAgent occupies the helper path. It was left untouched.')


def install_candidate(args, root, source, agent, domain, stop_owned_app, parser, allow_orphans):
    """Ordinary failures roll back. Crash/rollback uncertainty retains private backups."""
    app, legacy = root/NAME, root/'OpenClaw Teams Transcription.app'
    paths = [root/'config.json', agent, root/'installation-receipt.json']
    before = {path: file_snapshot(path) for path in paths}
    # Derive edits from the same bytes backed up by this transaction, rather
    # than a configuration read before acquiring installer ownership.
    settings = json.loads(before[paths[0]][0]) if before[paths[0]] else {}
    if not isinstance(settings, dict): parser.error('Configuration must be an object. Helper left running.')
    if args.gateway: settings['gateway'] = {'url': args.gateway, 'authentication': args.authentication}
    settings.setdefault('recordings_dir', str(root/'recordings'))
    settings.setdefault('transcription', {'enabled': True, 'engine': 'parakeet'})
    settings.setdefault('speaker_voice_memory', False)
    settings.setdefault('auto_meeting_captions', False)
    settings.setdefault('post_processing', {'mode': 'off'})
    app_ids = {path: directory_identity(path) for path in [app, legacy]}
    verify_agent(before[agent], app, legacy, parser)
    loaded = command('/bin/launchctl', 'print', f'{domain}/{LABEL}', check=False).returncode == 0
    if loaded and not before[agent]: parser.error('A helper job is loaded without a verifiable LaunchAgent. It was left untouched.')
    stage = pathlib.Path(tempfile.mkdtemp(prefix='.ocmh-install-', dir=root))
    candidate = stage/NAME
    pending = root/PENDING
    marker = None
    marker_created = False
    candidate_id = None
    replacements = {}
    launch_attempted = False
    job_unloaded = False
    stop_confirmed = False
    committed = False
    try:
        shutil.copytree(source, candidate)
        command('/usr/bin/codesign', '--verify', '--strict', str(candidate))
        info = plistlib.loads((candidate/'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != LABEL or info.get('OCMHUsesLifecycleLock') is not True:
            raise RuntimeError('The bundled helper lacks the required identity or lifecycle protection.')
        candidate_id = directory_identity(candidate)
        plist = {'Label': LABEL, 'ProgramArguments': [str(app/'Contents/MacOS/ocmh'), 'run', '--out', settings['recordings_dir']],
                 'EnvironmentVariables': {'OPENCLAW_TEAMS_HOME': str(root)}, 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 10,
                 'StandardErrorPath': str(root/'helper.log'), 'StandardOutPath': str(root/'helper.stdout.log')}
        gateway = settings.get('gateway')
        receipt = {'pluginOwner': 'teams-transcribe', 'version': info['CFBundleShortVersionString'],
                   'helperSHA256': hashlib.sha256((candidate/'Contents/MacOS/ocmh').read_bytes()).hexdigest(),
                   'gatewayConfigured': isinstance(gateway, dict) and bool(gateway.get('url')),
                   'localOpenClawRequired': False, 'launched': not args.no_launch}
        replacements = {paths[0]: (json.dumps(settings, indent=2).encode(), 0o600),
                        agent: (plistlib.dumps(plist), 0o600), paths[2]: (json.dumps(receipt, indent=2).encode(), 0o600)}
        manifest_files = []
        for index, path in enumerate(paths):
            snapshot = before[path]
            if snapshot: atomic_file(stage/f'file-{index}.before', snapshot[0])
            atomic_file(stage/f'file-{index}.after', replacements[path][0])
            manifest_files.append({'path': str(path), 'existed': snapshot is not None,
                                   'mode': snapshot[1] if snapshot else None,
                                   'backup': f'file-{index}.before' if snapshot else None,
                                   'beforeSHA256': hashlib.sha256(snapshot[0]).hexdigest() if snapshot else None,
                                   'afterSHA256': hashlib.sha256(replacements[path][0]).hexdigest()})
        manifest = {'schemaVersion': 1, 'stage': str(stage), 'previousJobLoaded': loaded,
                    'launchRequested': not args.no_launch, 'files': manifest_files,
                    'apps': [{'path': str(path), 'existed': identity is not None, 'backup': f'app-{index}.before'}
                             for index, (path, identity) in enumerate(app_ids.items())]}
        marker = json.dumps(manifest, indent=2).encode()
        # Publish a durable marker before changing anything in the installation.
        descriptor = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        marker_created = True
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(marker); stream.flush(); os.fsync(stream.fileno())
        sync_directory(root)
        check_recording_metadata(root, settings, parser, allow_orphans=allow_orphans)
        if any(file_snapshot(path) != snapshot for path, snapshot in before.items()) or any(directory_identity(path) != identity for path, identity in app_ids.items()):
            raise RuntimeError('Installation changed during preparation. Update stopped.')
        unload_job(domain); job_unloaded = True
        stop_owned_app()
        stop_confirmed = True
        if any(file_snapshot(path) != snapshot for path, snapshot in before.items()) or any(directory_identity(path) != identity for path, identity in app_ids.items()):
            raise RuntimeError('Installation changed while the previous helper stopped. Review required.')
        for index, (path, identity) in enumerate(app_ids.items()):
            if identity is not None: path.rename(stage/f'app-{index}.before')
        candidate.rename(app)
        for path, (data, mode) in replacements.items():
            if file_snapshot(path) != before[path]: raise RuntimeError('Installation file changed before replacement.')
            atomic_file(path, data, mode)
        if not args.no_launch:
            launch_attempted = True
            command('/bin/launchctl', 'bootstrap', domain, str(agent))
        # A launched process cannot acquire its work lease until this function
        # commits and releases the exclusive installer lease.
        if file_snapshot(pending) != (marker, 0o600): raise RuntimeError('Installation marker changed. Review required.')
        pending.unlink()
        committed = True
        sync_directory(root)
    except BaseException as failure:
        if committed:
            raise RuntimeError('Installation files and launch were published, but completion could not be confirmed. Private backup stage retained for review.') from None
        if not marker_created:
            # Preparation failed before publication. No installation was changed.
            shutil.rmtree(stage)
            raise
        try:
            if file_snapshot(pending) != (marker, 0o600):
                raise RuntimeError('Installation marker is missing or changed. Backups require review.')
            if job_unloaded and not stop_confirmed:
                raise RuntimeError('Previous helper exit was not confirmed. Automatic relaunch is unsafe.')
            if launch_attempted:
                unload_job(domain)
                stop_owned_app()
            # Refuse to overwrite a settings edit or a replacement application.
            for path, snapshot in before.items():
                if file_snapshot(path) not in [snapshot, replacements.get(path)]:
                    raise RuntimeError('An installation file changed outside this update.')
            current_id = directory_identity(app)
            if current_id not in [app_ids[app], candidate_id, None]: raise RuntimeError('Application identity changed outside this update.')
            for index, (path, identity) in enumerate(app_ids.items()):
                backup = stage/f'app-{index}.before'
                if present(backup):
                    if directory_identity(backup) != identity: raise RuntimeError('Application backup identity changed.')
                    if present(path):
                        if path != app or directory_identity(path) != candidate_id: raise RuntimeError('Application destination changed.')
                        path.rename(stage/'failed-candidate.app')
                    backup.rename(path)
                elif identity is None and path == app and directory_identity(path) == candidate_id:
                    path.rename(stage/'failed-candidate.app')
                elif directory_identity(path) != identity:
                    raise RuntimeError('Previous application cannot be verified.')
            for path, snapshot in before.items():
                if file_snapshot(path) == snapshot: continue
                if snapshot: atomic_file(path, *snapshot)
                else: path.unlink(missing_ok=True); sync_directory(path.parent)
            if loaded and job_unloaded and not args.no_launch:
                command('/bin/launchctl', 'bootstrap', domain, str(agent))
            if file_snapshot(pending) != (marker, 0o600): raise RuntimeError('Installation marker changed.')
            pending.unlink(); sync_directory(root)
        except BaseException:
            raise RuntimeError('Helper update and rollback could not be completed. Installation is blocked for review. Private backups and recordings are preserved; see installation-pending.json and the installer recovery guide.') from None
        shutil.rmtree(stage)
        raise RuntimeError('Helper update failed. Previous application, configuration, LaunchAgent and receipt restored. Recordings preserved.') from failure
    if committed:
        # Cleanup failure must not undo a committed, possibly running install.
        try: shutil.rmtree(stage)
        except OSError: print('Installation committed; backup cleanup needs review.', file=sys.stderr)
        print(json.dumps(receipt))


def perform(args, root, settings, parser, *, allow_orphans=False):
    app, agent = root/NAME, pathlib.Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    legacy = root/'OpenClaw Teams Transcription.app'
    if legacy.exists():
        identity = plistlib.loads((legacy/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
        if identity != LABEL: parser.error('An unrelated application occupies the old helper path. It was left untouched.')
    domain = f'gui/{os.getuid()}'
    def stop_owned_app():
        # LaunchServices owns the app process; stop only this exact plugin binary.
        pids = list(set(owned_pids(app) + owned_pids(legacy)))
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

    if args.action in ['remove', 'run']:
        agent_snapshot = file_snapshot(agent)
        verify_agent(agent_snapshot, app, legacy, parser)
        if args.action == 'run' and agent_snapshot is None:
            parser.error('Install the bundled helper before running it. No LaunchAgent was changed.')
    if args.action == 'remove':
        unload_job(domain)
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
    if args.gateway:
        from urllib.parse import urlsplit
        url = urlsplit(args.gateway)
        if url.username or url.password or url.query or url.fragment or url.path not in ['', '/'] or (url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ['localhost', '127.0.0.1', '::1'])):
            parser.error('Use an HTTPS Gateway origin or loopback HTTP without credentials.')
    install_candidate(args, root, source, agent, domain, stop_owned_app, parser, allow_orphans)

if __name__ == '__main__':
    main()
