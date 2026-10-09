"""Select an installed Xcode 27+ without assuming its beta app filename."""
import os
from pathlib import Path
import plistlib
import re

candidates = []
for app in Path('/Applications').glob('Xcode*.app'):
    try:
        with (app / 'Contents/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        version = tuple(int(part) for part in re.findall(r'\d+', info['CFBundleShortVersionString']))
        developer = app / 'Contents/Developer'
        if version >= (27,) and (developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift').is_file():
            candidates.append((version, str(developer)))
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
        continue
if not candidates:
    raise SystemExit('No installed Xcode 27+ toolchain found. Native checks cannot run.')
version, developer = max(candidates)
with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
    output.write(f'DEVELOPER_DIR={developer}\n')
print(f'Selected Xcode {".".join(map(str, version))}: {developer}')
