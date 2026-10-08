import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {saveEnvelope,verifyEnvelope,gatewayHandler,installedRuntimeDirectory} from '../src/gateway.mjs';
import {archiveRuntime} from '../src/archive.mjs';
const payload={recordingId:'receipt-fixture',meta:{started:'2026-10-05T10:00:00Z',ended:'2026-10-05T10:01:00Z',audio_started_at:1791194400,status:'stopped',fixture:true,notes_mode:'ai',note_template:{id:'fixture',name:'Fixture',context:'Synthetic',sections:[{title:'Summary',instructions:'Summarize'}]}},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-05T10:02:00Z',execution_machine:'fixture',execution_location:'recording_mac',segments:[{speaker:'unknown',source:'system',start_ms:0,end_ms:1000,text:'Synthetic speech.'}]}};
const runtime=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory();
async function request(body,mode,options){
 const req={method:'POST',url:'/plugins/teams-transcribe/ingest'+mode,headers:{'content-type':'application/json'},async *[Symbol.asyncIterator](){yield body;}};
 const res={setHeader(){},writeHead(code){this.status=code;},end(data){this.value=JSON.parse(data);}};
 await gatewayHandler(options)(req,res);return res;
}
test('verification reads completed canonical notes without model, store or attempt-ledger writes',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-verify-'));let calls=0;
 const options={stateDir,openclawDir:runtime,complete:async()=>{calls++;return {provider:'fixture',model:'fixture',text:JSON.stringify({sections:[{title:'Summary',body:'Synthetic notes.'}]})};}};
 const {Store}=await archiveRuntime(runtime);const methods=['writeSession','appendUtteranceForSession','writeSummary'];const originals=Object.fromEntries(methods.map(name=>[name,Store.prototype[name]]));
 const readWorker=Store.prototype.readWorker;const admissions=[];
 try{
  const saved=await saveEnvelope(payload,options);
  const ledger=path.join(stateDir,'teams-transcribe','notes-attempts',saved.sessionId+'.json');const before=await fs.readFile(ledger);
  for(const name of methods)Store.prototype[name]=()=>{throw Error('Canonical writes are forbidden during verification');};
  Store.prototype.readWorker=function(...args){admissions.push(this.databaseOptions.readOnly);return readWorker.apply(this,args);};
  const body=Buffer.from(JSON.stringify(payload));const result=await request(body,'?mode=verify',options);
  assert.equal(result.status,200);assert.equal(result.value.saved,true);
  assert.equal(result.value.verification.requestSHA256,createHash('sha256').update(body).digest('hex'));
  assert.deepEqual(result.value.documents,saved.documents);assert.equal(calls,1);
  assert.deepEqual(await fs.readFile(ledger),before);assert.ok(admissions.length>=3);assert.ok(admissions.every(value=>value===true));
  for(const change of ['text','template','title']){
   const changed=structuredClone(payload);
   if(change==='text')changed.transcript.segments[0].text='Different speech.';
   if(change==='template')changed.meta.note_template.context='Different instructions';
   if(change==='title')changed.meta.meeting_context={title:'Different meeting'};
   await assert.rejects(verifyEnvelope(changed,options));
  }
  assert.equal(calls,1);assert.deepEqual(await fs.readFile(ledger),before);
 }finally{
  for(const name of methods)Store.prototype[name]=originals[name];Store.prototype.readWorker=readWorker;
  await fs.rm(stateDir,{recursive:true,force:true});
 }
});
test('missing archives and unknown verification modes cannot create a meeting or notes ledger',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-verify-missing-'));let calls=0;
 const options={stateDir,openclawDir:runtime,complete:async()=>{calls++;throw Error('No completion allowed');}};
 try{
  await assert.rejects(verifyEnvelope(payload,options));
  assert.deepEqual(await fs.readdir(stateDir),[]);
  for(const query of ['?mode=verification','?mode=verify&mode=verify','?other=verify']){
   const result=await request(Buffer.from(JSON.stringify(payload)),query,options);
   assert.equal(result.status,422);assert.equal(result.value.code,'invalid_payload');
  }
  assert.equal(calls,0);assert.deepEqual(await fs.readdir(stateDir),[]);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
test('a partial canonical save is reported incomplete rather than completed or regenerated',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-verify-partial-'));
 try{
  const {meetingRecord}=await import('../src/archive.mjs');const {archiveIdentity}=await import('../src/revisions.mjs');
  const record=meetingRecord(payload.meta,payload.transcript,archiveIdentity(payload.meta.started,payload.recordingId));
  const {Store}=await archiveRuntime(runtime);const store=new Store(path.join(stateDir,'transcripts'),{env:{...process.env,OPENCLAW_STATE_DIR:stateDir}});
  await store.writeSession(record.session);await store.appendUtteranceForSession(record.session,record.utterances[0]);
  await assert.rejects(verifyEnvelope(payload,{stateDir,openclawDir:runtime}),error=>error.code==='archive_not_verified');
  assert.equal((await store.readSummary(record.session))?.summary,undefined);
  await assert.rejects(fs.stat(path.join(stateDir,'teams-transcribe','notes-attempts')),error=>error.code==='ENOENT');
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
