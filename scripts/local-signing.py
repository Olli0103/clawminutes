#!/usr/bin/env python3
"""Create a stable, private local code-signing identity. Never shipped in the plugin."""
import json, os, pathlib, secrets, subprocess, tempfile, shutil
state=pathlib.Path.home()/'.openclaw/teams-transcribe/signing'
state.mkdir(parents=True,exist_ok=True,mode=0o700)
identity='ocmh local signing'
keychain=state/'ocmh-signing.keychain-db'
recovered=state/'ocmh-signing-recovered.keychain-db'
if recovered.exists(): keychain=recovered
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
    # A stale macOS keychain access state can reject a valid password. A private
    # byte-for-byte copy is a fresh handle; preserve the original and identity.
    if keychain == recovered or recovered.exists(): raise
    shutil.copy2(keychain,recovered); recovered.chmod(0o600)
    try:
        run('/usr/bin/security','unlock-keychain','-p',password,str(recovered))
        original_cert=run('/usr/bin/security','find-certificate','-c',identity,'-p',str(keychain))
        copied_cert=run('/usr/bin/security','find-certificate','-c',identity,'-p',str(recovered))
        if original_cert != copied_cert: raise RuntimeError('Signing recovery changed certificate; original preserved.')
    except Exception:
        recovered.unlink(missing_ok=True)
        raise
    keychain=recovered
print(json.dumps({'identity':identity,'keychain':str(keychain),'scope':'Local build signing only. Not Apple notarization; not a permission grant.'}))
