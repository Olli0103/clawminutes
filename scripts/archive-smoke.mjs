// Synthetic text through the production save interface. No audio, STT or model.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {archiveAdapter} from '../src/archive.mjs';
import {saveEnvelope} from '../src/gateway.mjs';
const openclawDir=process.env.OPENCLAW_TEAMS_OPENCLAW_DIR;
if(!openclawDir)throw Error('Set OPENCLAW_TEAMS_OPENCLAW_DIR to the development SDK directory.');
const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-archive-smoke-'));
try{
  let directory=path.join(root,'three-speaker-fixture');await fs.mkdir(directory);
  const meta={recording_id:'archive-smoke-fixture',fixture:true,started:'2026-10-01T10:00:00Z',ended:'2026-10-01T10:01:00Z',audio_started_at:1790848800,status:'stopped',notes_mode:'transcript'};
  // Engine/model identify the closed protocol being exercised. fixture:true and
  // this command's output identify synthetic text, never recognition evidence.
  const transcript={engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-01T10:02:00Z',execution_machine:'synthetic-storage-fixture',execution_location:'recording_mac',segments:[
    {start_ms:0,end_ms:1000,text:'This is a synthetic storage fixture.',source:'mic',speaker:'me',speaker_name:'Alex',attribution:'local_microphone'},
    {start_ms:2000,end_ms:3000,text:'Timestamped speaker evidence supports this fixture label.',source:'system',speaker:'system_1',speaker_name:'Blair',attribution:'meeting_tile'},
    {start_ms:4000,end_ms:5000,text:'An unsupported identity remains unknown.',source:'system',speaker:'system_2',speaker_name:'Casey',attribution:'diarization'}
  ]};
  await fs.writeFile(path.join(directory,'meta.json'),JSON.stringify(meta));
  await fs.writeFile(path.join(directory,'transcript.json'),JSON.stringify(transcript));
  async function readEnvelope(){
    const {recording_id:recordingId,...meta}=JSON.parse(await fs.readFile(path.join(directory,'meta.json'),'utf8'));
    return {recordingId,meta,transcript:JSON.parse(await fs.readFile(path.join(directory,'transcript.json'),'utf8'))};
  }
  let completions=0;
  const stateDir=path.join(root,'state');
  const options={openclawDir,stateDir,complete:async()=>{completions++;throw Error('A transcript-only storage fixture must never call a model.');}};
  const first=await saveEnvelope(await readEnvelope(),options);
  const second=await saveEnvelope(await readEnvelope(),options);
  assert.equal(first.sessionId,second.sessionId);assert.equal(second.utteranceCount,3);
  assert.deepEqual(first.documents,second.documents);
  await fs.writeFile(path.join(directory,'transcript.json'),JSON.stringify({...transcript,segments:[...transcript.segments,
    {start_ms:6000,end_ms:7000,text:'Changed synthetic speech must not overwrite a completed save.',source:'mic',speaker:'me'}]}));
  await assert.rejects(saveEnvelope(await readEnvelope(),options),error=>error.code==='revision_conflict'&&!error.completionAttempted);
  await fs.writeFile(path.join(directory,'transcript.json'),JSON.stringify(transcript));
  const renamed=directory+'-renamed';await fs.rename(directory,renamed);directory=renamed;
  const afterRename=await saveEnvelope(await readEnvelope(),options);
  assert.equal(afterRename.sessionId,first.sessionId);assert.deepEqual(afterRename.documents,first.documents);
  const Store=await archiveAdapter(openclawDir);
  const store=new Store(path.join(stateDir,'transcripts'),{env:{...process.env,OPENCLAW_STATE_DIR:stateDir}});
  const session=await store.readSession(first.sessionId),rows=await store.readUtterancesForSession(session);
  assert.equal(session.metadata.fixture,true);assert.equal(rows.length,3);
  assert.deepEqual(rows.map(row=>row.speaker.label),['Alex','Blair','Unknown speaker']);
  assert.equal(completions,0);
  console.log(JSON.stringify({test:'production save interface and real SDK, synthetic text only',rows:rows.length,
    idempotent:true,changedSpeechRejected:true,folderRenamePreservesIdentity:true,completions},null,2));
}finally{await fs.rm(root,{recursive:true,force:true});}
