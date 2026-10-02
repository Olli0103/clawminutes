#!/usr/bin/env python3
"""Lifecycle installer shipped by the teams-transcribe plugin. No OpenClaw CLI."""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys, signal

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
    root = pathlib.Path(os.environ.get('OPENCLAW_TEAMS_HOME', pathlib.Path.home()/'.openclaw/teams-transcribe'))
    app, agent = root/NAME, pathlib.Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    legacy = root/'OpenClaw Teams Transcription.app'
    if legacy.exists():
        identity = plistlib.loads((legacy/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
        if identity != LABEL: parser.error('An unrelated application occupies the old helper path. It was left untouched.')
    domain = f'gui/{os.getuid()}'
    def stop_owned_app():
        # LaunchServices owns the app process; stop only this exact plugin binary.
        rows=command('/bin/ps','-axo','pid=,command=').stdout.decode().splitlines()
        expected=str(app/'Contents/MacOS/ocmh')
        for row in rows:
            pieces=row.strip().split(None,1)
            if len(pieces)==2 and (pieces[1]==expected or pieces[1].startswith(expected+' run')):
                try: os.kill(int(pieces[0]),signal.SIGTERM)
                except ProcessLookupError: pass

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
    # Do not replace a running recorder. The unfinished files remain owned by
    # the current helper until it writes the completed metadata.
    for metadata in (root/'recordings').glob('*/meta.json'):
        try: capture_status = json.loads(metadata.read_text()).get('status')
        except (OSError, ValueError): continue
        if capture_status == 'recording':
            parser.error('A recording is active. Finish it before updating the helper. Recording left running.')
    source = base/'helper'/NAME
    if not source.exists(): source = base/NAME
    if not (source/'Contents/MacOS/ocmh').is_file(): parser.error('The plugin-bundled helper is missing.')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = root/'config.json'
    settings = json.loads(config.read_text()) if config.exists() else {}
    if args.gateway:
        from urllib.parse import urlsplit
        url = urlsplit(args.gateway)
        if url.username or url.password or url.query or url.fragment or url.path not in ['', '/'] or (url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ['localhost', '127.0.0.1', '::1'])):
            parser.error('Use an HTTPS Gateway origin or loopback HTTP without credentials.')
        settings['gateway'] = {'url': args.gateway, 'authentication': args.authentication}
    settings.setdefault('recordings_dir', str(root/'recordings'))
    settings.setdefault('transcription', {'enabled': True, 'engine': 'parakeet'})
    settings.update(speaker_voice_memory=False, auto_meeting_captions=False, post_processing={'mode': 'off'})
    staged = root/(NAME+'.next')
    if staged.exists(): shutil.rmtree(staged)
    shutil.copytree(source, staged)
    command('/usr/bin/codesign', '--verify', '--strict', str(staged))
    # Recheck after staging and signing, immediately before replacing the running app.
    for metadata in (root/'recordings').glob('*/meta.json'):
        try: capture_status = json.loads(metadata.read_text()).get('status')
        except (OSError, ValueError): parser.error('Could not verify recording status. Helper left running.')
        if capture_status == 'recording':
            parser.error('A recording is active. Finish it before updating the helper. Recording left running.')
    command('/bin/launchctl', 'bootout', domain, str(agent), check=False)
    stop_owned_app()
    import time
    time.sleep(.3)
    previous = root/(NAME+'.previous')
    if previous.exists(): shutil.rmtree(previous)
    if legacy.exists(): shutil.rmtree(legacy)
    if app.exists(): app.rename(previous)
    staged.rename(app)
    temp = config.with_suffix('.json.next')
    temp.write_text(json.dumps(settings, indent=2)); temp.chmod(0o600); temp.replace(config)
    agent.parent.mkdir(parents=True, exist_ok=True)
    plist = {'Label': LABEL, 'ProgramArguments': ['/usr/bin/open', '-W', '-g', '-a', str(app), '--args', 'run', '--out', settings['recordings_dir']],
             'EnvironmentVariables': {'OPENCLAW_TEAMS_HOME': str(root)}, 'RunAtLoad': True, 'KeepAlive': False,
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
    receipt = {'pluginOwner': 'teams-transcribe', 'version': '0.2.5', 'helperSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
               'gateway': settings.get('gateway', {}), 'localOpenClawRequired': False, 'launched': not args.no_launch}
    (root/'installation-receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))

if __name__ == '__main__':
    main()
