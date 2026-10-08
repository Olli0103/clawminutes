import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {saveEnvelope,installedRuntimeDirectory,validateEnvelope} from '../src/gateway.mjs';
import {archiveAdapter} from '../src/archive.mjs';
import {archiveIdentity,revisionRecordingId} from '../src/revisions.mjs';
const template={id:'fixture',name:'Fixture',context:'Synthetic',sections:[{title:'Summary',instructions:'Summarize'}]};
function envelope(){return {recordingId:'version-fixture',meta:{started:'2026-10-08T10:00:00Z',ended:'2026-10-08T10:01:00Z',audio_started_at:1791453600,status:'stopped',fixture:true,notes_mode:'ai',note_template:template},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-08T10:02:00Z',execution_machine:'fixture-mac',execution_location:'recording_mac',segments:[{speaker:'system_unknown',source:'system',start_ms:0,end_ms:1000,text:'Synthetic speech.'}]}};}
function revision(parent,number=2){const base='version-fixture';return {...structuredClone(parent),recordingId:revisionRecordingId(base,number),meta:{...structuredClone(parent.meta),revision:{number,baseRecordingId:base,parentSessionId:archiveIdentity(parent.meta.started,number===2?base:revisionRecordingId(base,number-1)),reason:'speaker_correction'}}};}

test('saved speaker corrections create an idempotent revision and preserve the original canonical record',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-revisions-'));let calls=0;
 try{
  const options={stateDir,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory(),complete:async()=>({text:JSON.stringify({sections:[{title:'Summary',body:`- Synthetic completion ${++calls}`}]}),provider:'fixture',model:'fixture'})};
  const first=envelope();const original=await saveEnvelope(first,options);
  const second=revision(first);second.transcript.segments[0].speaker_name='Fixture Alice';second.transcript.segments[0].attribution='manual';
  const changed=await saveEnvelope(second,options),repeated=await saveEnvelope(second,options);
  assert.notEqual(changed.sessionId,original.sessionId);assert.deepEqual(repeated.documents,changed.documents);assert.equal(calls,2);
  assert.match(changed.documents.transcriptMarkdown,/Fixture Alice/);assert.match(changed.documents.notesMarkdown,/Version: 2, supersedes/);
  const restored=await saveEnvelope(first,options);assert.deepEqual(restored.documents,original.documents);assert.equal(calls,2);
  const Store=await archiveAdapter(options.openclawDir),store=new Store(path.join(stateDir,'transcripts'),{env:{...process.env,OPENCLAW_STATE_DIR:stateDir}});
  const parent=await store.readSession(original.sessionId),child=await store.readSession(changed.sessionId);
  assert.equal(child.metadata.revision.parentSessionId,parent.sessionId);
  assert.equal((await store.readUtterancesForSession(parent))[0].speaker.label,'Unknown speaker');
  second.transcript.segments[0].text='Changed again without a version';
  await assert.rejects(saveEnvelope(second,options),e=>e.code==='revision_conflict'&&!e.completionAttempted);assert.equal(calls,2);
  const third=revision(first,3);third.meta.revision.reason='template_change';
  const final=await saveEnvelope(third,options);assert.equal(final.documents.metadata.metadata.revision.number,3);assert.equal(calls,3);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});

test('missing parents, forged lineage and arbitrary revision fields incur no model completion',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-revision-reject-'));let calls=0;
 try{
  const options={stateDir,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory(),complete:async()=>{calls++;throw Error('must not complete');}};
  const child=revision(envelope());
  await assert.rejects(saveEnvelope(child,options),e=>e.code==='revision_parent_unavailable');
  for(const mutate of [x=>x.meta.revision.parentSessionId='teams-'+'0'.repeat(24),x=>x.meta.revision.audio='/private/audio',x=>x.meta.revision.number=3,x=>x.recordingId='unrelated']){
   const value=structuredClone(child);mutate(value);assert.throws(()=>validateEnvelope(value));
  }
  assert.equal(calls,0);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
