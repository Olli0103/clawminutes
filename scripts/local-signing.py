#!/usr/bin/env python3
"""Create a stable, private local code-signing identity. Never shipped in the plugin."""
import json, os, pathlib, secrets, subprocess, tempfile
if os.geteuid() == 0:
    raise SystemExit('Run local-signing.py as your login user, without sudo. A keychain password cannot be overridden by root.')
state=pathlib.Path.home()/'.openclaw/teams-transcribe/signing'
state.mkdir(parents=True,exist_ok=True,mode=0o700)
identity='ocmh local signing'
keychain=state/'ocmh-signing.keychain-db'
recovered=state/'ocmh-signing-recovered.keychain-db'
# An existing recovery copy must not shadow the original working keychain.
# macOS can reject the copy even when the original accepts the saved password.
if not keychain.exists() and recovered.exists(): keychain=recovered
password_file=state/'keychain-password'
def run(*args):
    result=subprocess.run(args,capture_output=True,text=True)
    if result.returncode: raise RuntimeError(f'{args[0]} failed: {result.stderr.strip()}')
    return result.stdout
if not keychain.exists():
    password=secrets.token_urlsafe(32)
    password_file.write_text(password); password_file.chmod(0o600)
    with tempfile.TemporaryDirectory(dir=state) as temporary:
        root=pathlib.Path(temporary)
        config=root/'openssl.conf'
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=ocmh local signing\n[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:FALSE\n')
        run('/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','3650','-config',str(config),'-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem'))
        run('/usr/bin/openssl','pkcs12','-export','-name',identity,'-inkey',str(root/'key.pem'),'-in',str(root/'cert.pem'),'-out',str(root/'identity.p12'),'-passout','pass:'+password)
        run('/usr/bin/security','create-keychain','-p',password,str(keychain))
        run('/usr/bin/security','import',str(root/'identity.p12'),'-k',str(keychain),'-P',password,'-T','/usr/bin/codesign')
        run('/usr/bin/security','set-key-partition-list','-S','apple-tool:,apple:','-l',identity,'-t','private','-k',password,str(keychain))
password=password_file.read_text()
try:
    run('/usr/bin/security','unlock-keychain','-p',password,str(keychain))
except RuntimeError:
    raise SystemExit('The saved signing password could not unlock the selected keychain. '
                     'The certificate and keychain were preserved. Do not retry with sudo or reset your login keychain. '
                     'Recover the existing signing credential before updating the helper.') from None
print(json.dumps({'identity':identity,'keychain':str(keychain),'scope':'Local build signing only. Not Apple notarization; not a permission grant.'}))
