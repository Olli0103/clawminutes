#!/usr/bin/env python3
"""Explicit hardware test: local synthetic playback, bounded capture, then interruption."""
import pathlib, subprocess, time, json, hashlib, os, signal, argparse
base=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out',type=pathlib.Path,default=base/'evidence/hardware-sck-capture')
args=parser.parse_args()
binary=pathlib.Path.home()/'.openclaw/teams-transcribe/ocmh.app/Contents/MacOS/ocmh'
fixture=base/'evidence/three-voice-fixture/system.caf'
root=args.out
root.mkdir(exist_ok=True)
existing=set(root.iterdir())
log=(root/'capture.log').open('w')
p=subprocess.Popen([str(binary),'capture-fixture','--seconds','48','--out',str(root)],stdout=log,stderr=log)
try:
    deadline=time.time()+20
    while time.time()<deadline:
        sessions=[d for d in root.iterdir() if d not in existing and (d/'meta.json').exists()]
        if sessions and (sessions[-1]/'mic.caf').exists(): break
        if p.poll() is not None: raise RuntimeError('Capture exited before writing metadata')
        time.sleep(.2)
    else: raise RuntimeError('Capture did not start')
    playback=subprocess.Popen(['/usr/bin/afplay',str(fixture)],stdout=log,stderr=log)
    p.wait(timeout=65)
    if playback.poll() is None: playback.terminate(); playback.wait()
    if p.returncode: raise RuntimeError('Capture failed; inspect log')
finally:
    if p.poll() is None: p.terminate(); p.wait()
log.close()
for session in sessions:
    for audio in session.glob('*.caf'):
        result=subprocess.run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','format=duration:stream=codec_name,sample_rate,channels','-of','json',str(audio)],capture_output=True,text=True)
        info=json.loads(result.stdout)
        assert result.returncode==0 and float(info['format']['duration'])>0
        print(json.dumps({'track':audio.name,'bytes':audio.stat().st_size,'probe':info}))
    print(json.dumps({'meta':json.loads((session/'meta.json').read_text())}))
