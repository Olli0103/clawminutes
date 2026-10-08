#!/usr/bin/env python3
import pathlib,plistlib,shutil,subprocess,os,zipfile,tempfile,json
root=pathlib.Path(__file__).resolve().parents[1]
app=root/'helper/ocmh.app'
if app.exists(): shutil.rmtree(app)
(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
(app/'Contents/Resources').mkdir(parents=True,exist_ok=True)
shutil.copy2(root/'native/.build/release/ocmh',app/'Contents/MacOS/ocmh')
# Xcode release builds retain linker debug symbols containing build-host paths.
# Strip only debug symbols before signing; executable symbols remain available.
subprocess.run(['/usr/bin/strip','-S',str(app/'Contents/MacOS/ocmh')],check=True)
if str(root).encode() in (app/'Contents/MacOS/ocmh').read_bytes():
    raise SystemExit('Packaged helper still contains the private build directory.')
for name in ['ocmh-light.png', 'ocmh-dark.png']:
    shutil.copy2(root/'native/Sources/quill/Resources'/name,app/'Contents/Resources'/name)
cloudflared_path=os.environ.get('OPENCLAW_TEAMS_CLOUDFLARED') or shutil.which('cloudflared')
if not cloudflared_path:
    raise SystemExit('Install cloudflared or set OPENCLAW_TEAMS_CLOUDFLARED to its executable path.')
cloudflared=pathlib.Path(cloudflared_path).resolve()
shutil.copy2(cloudflared,app/'Contents/Resources/cloudflared')
identity=os.environ.get('OPENCLAW_TEAMS_SIGNING_IDENTITY')
keychain=os.environ.get('OPENCLAW_TEAMS_SIGNING_KEYCHAIN')
local_keychain=pathlib.Path.home()/'.openclaw/teams-transcribe/signing/ocmh-signing.keychain-db'
if not identity and local_keychain.exists():
    local_signing=json.loads(subprocess.check_output(['python3',str(root/'scripts/local-signing.py')],text=True))
    identity=local_signing['identity']
    keychain=local_signing['keychain']
identity=identity or '-'
signing=['codesign','--force','--sign',identity]
if keychain: signing += ['--keychain',keychain]
subprocess.run(signing+[str(app/'Contents/Resources/cloudflared')],check=True)
info=plistlib.loads((root/'native/Sources/quill/Info.plist').read_bytes())
info.update(CFBundleIdentifier='ai.openclaw.teams-transcribe',CFBundleShortVersionString=json.loads((root/'package.json').read_text())['version'],CFBundleVersion=json.loads((root/'package.json').read_text())['version'],CFBundleIconFile='ocmh')
with tempfile.TemporaryDirectory() as temporary:
    icons=pathlib.Path(temporary)/'ocmh.iconset'
    icons.mkdir()
    for dimension in [16,32,128,256,512]:
        for scale in [1,2]:
            filename=icons/f'icon_{dimension}x{dimension}{"@2x" if scale==2 else ""}.png'
            subprocess.run([str(root/'native/.build/release/ocmh'),'export-icon','--size',str(dimension*scale),'--output',str(filename)],check=True)
    subprocess.run(['/usr/bin/iconutil','-c','icns',str(icons),'-o',str(app/'Contents/Resources/ocmh.icns')],check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
shutil.copytree(root/'notices',app/'Contents/Resources/notices',dirs_exist_ok=True)
subprocess.run(signing+[str(app)],check=True)
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
print(app)
with zipfile.ZipFile(root/'helper/recording-mac.zip','w',compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(app.rglob('*')):
        if file.is_file(): archive.write(file,'helper/'+str(file.relative_to(root/'helper')))
    archive.write(root/'scripts/helper.py','scripts/helper.py')
