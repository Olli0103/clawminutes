#!/usr/bin/env python3
"""Generate a labelled, synthetic three-voice recording. It is not live Teams evidence."""
import json,pathlib,subprocess,datetime
root=pathlib.Path(__file__).resolve().parents[1]/'evidence/three-voice-fixture'
root.mkdir(parents=True,exist_ok=True)
phrases=[('Samantha','Fixture Alice','This is the first speaker in a local transcription test. The recording stays on this Mac. We are checking that the transcript keeps the correct timestamps and marks any uncertain speaker as unknown.'),('Daniel','Fixture Blair','This is the second speaker. My voice is different from the first speaker. The system audio track contains the remote voices, while the microphone track is separate. No meeting assistant should join the call.'),('Alex','Fixture Casey','This is the third speaker in this recorded fixture. Participant names need evidence from the meeting interface. A voice cluster alone cannot establish a name. Please preserve the recording if transcription or saving fails.')]
origin=datetime.datetime(2026,10,1,10,tzinfo=datetime.timezone.utc)
time=0.0;observations=[];files=[];spans=[]
for i,(voice,name,text) in enumerate(phrases):
 aiff=root/f'{i}.aiff';wav=root/f'{i}.wav'
 subprocess.run(['say','-v',voice,'-r','165','-o',str(aiff),text],check=True)
 subprocess.run(['ffmpeg','-v','error','-y','-i',str(aiff),'-ar','16000','-ac','1',str(wav)],check=True)
 duration=float(subprocess.check_output(['ffprobe','-v','quiet','-show_entries','format=duration','-of','csv=p=0',str(wav)]))
 files.append(f"file '{wav}'")
 spans.append({'name':name,'start':time,'end':time+duration,'text':text})
 for tick in range(int(duration*4)):
  observations.append({'observed_at':origin.timestamp()+time+tick/4,'meeting_id':'synthetic-three-voice-fixture','names':[name], 'source':'accessibility_active_speaker','is_local':False})
 time+=duration
 # Clear speaking evidence between voices.
 observations.append({'observed_at':origin.timestamp()+time,'meeting_id':'synthetic-three-voice-fixture','names':[], 'source':'accessibility_active_speaker','is_local':False})
 # Real silence makes independent turns easier to distinguish.
 silence=root/f'silence-{i}.wav'
 subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','anullsrc=r=16000:cl=mono','-t','1',str(silence)],check=True)
 files.append(f"file '{silence}'");time+=1
(root/'list.txt').write_text('\n'.join(files))
subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(root/'list.txt'),'-c:a','pcm_s16le',str(root/'system.caf')],check=True)
# A separate mic fixture with no participant claim verifies unknown attribution.
subprocess.run(['say','-v','Samantha','-o',str(root/'mic.aiff'),'A microphone voice with no supported participant name must stay unknown.'],check=True)
subprocess.run(['ffmpeg','-v','error','-y','-i',str(root/'mic.aiff'),'-ar','16000','-ac','1','-c:a','pcm_s16le',str(root/'mic.caf')],check=True)
(root/'meta.json').write_text(json.dumps({'started':origin.isoformat().replace('+00:00','Z'),'ended':(origin+datetime.timedelta(seconds=time)).isoformat().replace('+00:00','Z'),'audio_started_at':origin.timestamp(),'backend':'parakeet','status':'fixture','fixture':True,'fixture_evidence':'synthetic speaking indicators, not a native Teams capture','duration_seconds':time,'files':{'mic':'mic.caf','system':'system.caf'},'start_offset_ms':{'mic':0,'system':0}}))
(root/'speaker-observations.jsonl').write_text('\n'.join(json.dumps(o) for o in sorted(observations,key=lambda o:o['observed_at']))+'\n')
(root/'expected.json').write_text(json.dumps(spans,indent=2))
print(root)
