#!/usr/bin/env python3
"""Verify code seals and compare declared identity. Never grants permissions."""
import argparse
import pathlib
import plistlib
import subprocess

BUNDLE_ID = 'ai.openclaw.teams-transcribe'


class SignatureError(Exception):
    pass


def command(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True)
    except OSError:
        raise SignatureError('Code-signing tools are unavailable. Nothing changed.') from None
    if result.returncode:
        raise SignatureError('Code signature could not be verified. Inspect locally; nothing changed.')
    return result.stdout + result.stderr


def requirement(app, run=command):
    if app.is_symlink():
        raise SignatureError('A linked application requires review.')
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    except (OSError, ValueError):
        raise SignatureError('Application metadata could not be verified.') from None
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise SignatureError('The application is not the ClawMinutes helper.')
    # Displaying a requirement alone says nothing about the current code seal.
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '= identifier "' + BUNDLE_ID + '"', str(app))
    display = run('/usr/bin/codesign', '-d', '-r-', str(app))
    lines = [line.strip() for line in display.splitlines() if line.startswith('designated =>')]
    if len(lines) != 1 or 'cdhash' in lines[0].lower():
        raise SignatureError('No stable designated requirement. Permissions may need new grants after updates.')
    return lines[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, default=pathlib.Path.home() / '.openclaw/teams-transcribe/ocmh.app')
    parser.add_argument('--reference', type=pathlib.Path, help='Earlier app to verify and compare, without modifying either build.')
    args = parser.parse_args()
    try:
        current = requirement(args.app)
        if args.reference and requirement(args.reference) != current:
            raise SignatureError('The verified builds have different designated requirements. Permission continuity is unproven.')
    except SignatureError as error:
        parser.error(str(error))
    print('PASS: code seals verified; ' + ('both builds have the same designated requirement.' if args.reference else 'no changing code-hash requirement found.'))
    print('needs_evidence: actual macOS permission continuity across updates.')


if __name__ == '__main__':
    main()
