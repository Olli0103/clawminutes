import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {saveEnvelope,installedRuntimeDirectory,validateEnvelope} from '../src/gateway.mjs';
import {archiveIdentity} from '../src/revisions.mjs';
function envelope(){return {recordingId:'recovery-fixture',meta:{started:'2026-10-08T10:00:00Z',ended:'2026-10-08T10:01:00Z',audio_started_at:1791453600,status:'stopped',fixture:true,notes_mode:'ai',note_template:{id:'fixture',name:'Fixture',context:'Synthetic',sections:[{title:'Summary',instructions:'Summarize'}]}},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-08T10:02:00Z',execution_machine:'fixture-mac',execution_location:'recording_mac',segments:[{speaker:'system_unknown',source:'system',start_ms:0,end_ms:1000,text:'Synthetic speech.'}]}};}
const recovery=(e,kind)=>({...structuredClone(e),meta:{...structuredClone(e.meta),notes_recovery:{kind,id:randomUUID()}}});
const sdk=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory();
test('explicit one-use AI retries preserve the durable budget and transcript-only recovery incurs no completion',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'notes-recovery-'));let calls=0;
 try{
  const options={stateDir,openclawDir:sdk,complete:async()=>{calls++;return {provider:'fixture',model:'fixture',text:'{"sections":[]}'};}};
  const e=envelope();
  await assert.rejects(saveEnvelope(e,options),x=>x.code==='ai_invalid_output');
  const second=recovery(e,'retry_ai');await assert.rejects(saveEnvelope(second,options),x=>x.code==='ai_invalid_output'&&!x.retryable&&x.completionAttempted);
  await assert.rejects(saveEnvelope(second,options),x=>x.code==='notes_retry_consumed'&&!x.completionAttempted);assert.equal(calls,2);
  await assert.rejects(saveEnvelope(recovery(e,'retry_ai'),options),x=>x.code==='ai_invalid_output');
  await assert.rejects(saveEnvelope(recovery(e,'retry_ai'),options),x=>x.code==='ai_retry_limit');assert.equal(calls,3);
  const before=await fs.readFile(path.join(stateDir,'teams-transcribe/notes-attempts',archiveIdentity(e.meta.started,e.recordingId)+'.json'),'utf8');
  const fallback=recovery(e,'transcript_only'),saved=await saveEnvelope(fallback,options),repeat=await saveEnvelope(fallback,options);
  assert.equal(saved.notes.backend,'transcript-only');assert.deepEqual(saved.documents,repeat.documents);assert.equal(calls,3);
  assert.equal(await fs.readFile(path.join(stateDir,'teams-transcribe/notes-attempts',saved.sessionId+'.json'),'utf8'),before);
  await assert.rejects(saveEnvelope(e,options),x=>x.code==='revision_conflict');assert.equal(calls,3);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
test('lost successful reply returns existing AI notes even when transcript-only recovery is requested',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'notes-recovery-saved-'));let calls=0;
 try{
  const options={stateDir,openclawDir:sdk,complete:async()=>{calls++;return {provider:'fixture',model:'fixture',text:'{"sections":[{"title":"Summary","body":"Saved AI notes"}]}'};}};
  const e=envelope(),first=await saveEnvelope(e,options),again=await saveEnvelope(recovery(e,'transcript_only'),options);
  assert.deepEqual(first.documents,again.documents);assert.equal(again.notes.backend,'gateway-model');assert.equal(calls,1);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
test('recovery requires an unchanged failed source and rejects arbitrary recovery data before completion',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'notes-recovery-invalid-'));let calls=0;
 try{
  const options={stateDir,openclawDir:sdk,complete:async()=>{calls++;throw Error('synthetic');}};
  const e=envelope();await assert.rejects(saveEnvelope(recovery(e,'retry_ai'),options),x=>x.code==='notes_recovery_unavailable');
  await assert.rejects(saveEnvelope(recovery(e,'transcript_only'),options),x=>x.code==='notes_recovery_unavailable');assert.equal(calls,0);
  await assert.rejects(saveEnvelope(e,options),x=>x.code==='ai_completion_failed');assert.equal(calls,1);
  const changed=recovery(e,'transcript_only');changed.transcript.segments[0].text='Changed speech';
  await assert.rejects(saveEnvelope(changed,options),x=>x.code==='notes_state_conflict');assert.equal(calls,1);
  const invalid=recovery(e,'retry_ai');invalid.meta.notes_recovery.audio='forbidden';assert.throws(()=>validateEnvelope(invalid));
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
test('semantically identical native JSON key orders share the same durable retry identity',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'notes-recovery-order-'));let calls=0;
 const reverse=value=>Array.isArray(value)?value.map(reverse):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).reverse().map(k=>[k,reverse(value[k])])):value;
 try{
  const options={stateDir,openclawDir:sdk,complete:async()=>{calls++;return {provider:'fixture',model:'fixture',text:'{"sections":[]}'};}};
  const e=envelope();await assert.rejects(saveEnvelope(e,options),x=>x.code==='ai_invalid_output');
  await assert.rejects(saveEnvelope(reverse(recovery(e,'retry_ai')),options),x=>x.code==='ai_invalid_output');assert.equal(calls,2);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
test('a successful explicit retry returns the same saved result after a lost reply without another completion',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'notes-recovery-success-'));let calls=0;
 try{
  const options={stateDir,openclawDir:sdk,complete:async()=>({provider:'fixture',model:'fixture',text:JSON.stringify({sections:++calls===1?[]:[{title:'Summary',body:'Recovered AI notes'}]})})};
  const e=envelope();await assert.rejects(saveEnvelope(e,options),x=>x.code==='ai_invalid_output');
  const request=recovery(e,'retry_ai'),saved=await saveEnvelope(request,options),again=await saveEnvelope(request,options);
  assert.equal(saved.notes.backend,'gateway-model');assert.deepEqual(saved.documents,again.documents);
  assert.deepEqual((await saveEnvelope(e,options)).documents,saved.documents);assert.equal(calls,2);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
