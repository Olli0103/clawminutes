#!/usr/bin/env python3
import pathlib,subprocess,time,json,hashlib
base=pathlib.Path(__file__).resolve().parents[1]
binary=pathlib.Path.home()/'.openclaw/teams-transcribe/ocmh.app/Contents/MacOS/ocmh'
root=base/'evidence/interrupted-hardware'
root.mkdir(exist_ok=True)
log=(base/'evidence/interrupted-capture.log').open('w')
p=subprocess.Popen([str(binary),'capture-fixture','--seconds','60','--out',str(root)],stdout=log,stderr=log)
playback=None
try:
 deadline=time.time()+15
 while time.time()<deadline:
  dirs=[d for d in root.iterdir() if (d/'mic.caf').exists()]
  if dirs: break
  if p.poll() is not None: raise RuntimeError('Capture did not start')
  time.sleep(.2)
 else: raise RuntimeError('Capture did not become ready')
 playback=subprocess.Popen(['/usr/bin/afplay',str(base/'evidence/three-voice-fixture/system.caf')],stdout=log,stderr=log)
 time.sleep(10)
 p.kill(); p.wait(timeout=5)
finally:
 if p.poll() is None: p.terminate();p.wait()
 if playback and playback.poll() is None: playback.terminate();playback.wait()
 log.close()
before={str(a):hashlib.sha256(a.read_bytes()).hexdigest() for d in dirs for a in d.glob('*.caf')}
result=subprocess.run(['/usr/bin/sandbox-exec','-f',str(base/'evidence/deny-network.sb'),str(binary),'recover-sessions','--out',str(root)],capture_output=True,text=True,timeout=240)
(base/'evidence/recovery-offline.log').write_text(result.stdout+result.stderr)
assert result.returncode==0
for d in dirs:
 assert (d/'transcript.json').exists(),'No recovered transcript'
 assert json.loads((d/'meta.json').read_text())['status']=='interrupted'
 for a in d.glob('*.caf'): assert before[str(a)]==hashlib.sha256(a.read_bytes()).hexdigest(),'Raw recording changed'
 print(json.dumps({'recovered':str(d),'audioPreserved':True,'network':'denied','transcript':json.loads((d/'transcript.json').read_text())}))
