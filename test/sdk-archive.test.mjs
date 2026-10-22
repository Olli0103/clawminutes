import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {saveEnvelope,installedRuntimeDirectory} from '../src/gateway.mjs';
import {archiveRuntime,meetingRecord} from '../src/archive.mjs';

test('real SDK archive preserves names, timing and gaps through repeated saves',async()=>{
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-sdk-contract-'));
  try {
    const payload={recordingId:'sdk-contract',meta:{started:'2026-10-05T10:00:00Z',ended:'2026-10-05T10:01:00.125Z',audio_started_at:1791194400,status:'stopped',fixture:true,notes_mode:'transcript'},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-05T10:02:00Z',execution_machine:'fixture-recording-mac',execution_location:'recording_mac',segments:[{speaker:'fixture-a',speaker_name:'Fixture Alice',attribution:'meeting_ui',source:'system',start_ms:0,end_ms:1000,text:'Synthetic fixture speech.'},{speaker:'unattributed',source:'mic',start_ms:2500,end_ms:3500,text:'Keep unsupported identity unknown.'}],capture_gaps:[{source:'system',start_ms:1000,end_ms:2000,reason:'buffers_stalled'}]}};
    const options={stateDir,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory()};
    const first=await saveEnvelope(payload,options);
    const repeated=await saveEnvelope(payload,options);
    assert.equal(first.saved,true);
    assert.equal(repeated.sessionId,first.sessionId);
    assert.equal(repeated.utteranceCount,2);
    assert.equal(repeated.notes.backend,'transcript-only');
    assert.deepEqual(repeated.documents.metadata.metadata.captureGaps,payload.transcript.capture_gaps);
    assert.match(repeated.documents.transcriptMarkdown,/Fixture Alice/);
    assert.match(repeated.documents.transcriptMarkdown,/Unknown speaker/);
    assert.match(repeated.documents.transcriptMarkdown,/2026-10-05T10:00:02.500Z/);
    assert.match(repeated.documents.notesMarkdown,/Capture gaps/);
    const corrected=structuredClone(payload);corrected.transcript.segments[0].text='Changed fixture speech.';
    await assert.rejects(saveEnvelope(corrected,options),/Archived transcript differs/);
  } finally {await fs.rm(stateDir,{recursive:true,force:true});}
});

test('concurrent saves of the same meeting share one AI completion and receipt',async()=>{
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-concurrent-save-'));
  let release;const gate=new Promise(resolve=>{release=resolve;});let called;const started=new Promise(resolve=>{called=resolve;});
  let calls=0;
  try {
    const payload={recordingId:'concurrent-fixture',meta:{started:'2026-10-05T10:00:00Z',ended:'2026-10-05T10:01:00Z',audio_started_at:1791194400,status:'stopped',fixture:true,notes_mode:'ai',note_template:{id:'test',name:'Test',context:'Fixture',sections:[{title:'Summary',instructions:'Summarize'}]}},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-05T10:02:00Z',execution_machine:'fixture',execution_location:'recording_mac',segments:[{speaker:'unknown',source:'system',start_ms:0,end_ms:1000,text:'Synthetic speech.'}]}};
    const options={stateDir,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory(),complete:async()=>{calls++;called();await gate;return {text:JSON.stringify({sections:[{title:'Summary',body:`- Fixture completion ${calls}`}]}),provider:'fixture',model:'fixture-model'};}};
    const first=saveEnvelope(payload,options);await started;
    const second=saveEnvelope(structuredClone(payload),options);
    const changed=structuredClone(payload);changed.transcript.segments[0].text='Different speech.';
    await assert.rejects(saveEnvelope(changed,options),/different save.*in progress/);
    release();const receipts=await Promise.all([first,second]);
    assert.equal(calls,1,'Automatic recovery and a manual retry must not create competing AI notes');
    assert.deepEqual(receipts[0],receipts[1]);assert.equal(receipts[0].utteranceCount,1);
    const recovered=await saveEnvelope(structuredClone(payload),options);
    assert.equal(calls,1,'A lost receipt must not regenerate already saved AI notes');
    assert.deepEqual(recovered.documents,receipts[0].documents);
    const changedTemplate=structuredClone(payload);changedTemplate.meta.note_template.context='Changed instructions';
    await assert.rejects(saveEnvelope(changedTemplate,options),/Archived meeting metadata differs/);
    assert.equal(calls,1,'A conflicting retry must preserve saved notes');
    const longer=structuredClone(payload);longer.transcript.segments.push({source:'system',start_ms:1000,end_ms:2000,text:'Additional speech.'});
    await assert.rejects(saveEnvelope(longer,options),/new revision/, 'A completed summary cannot become a partial-save recovery');
    assert.equal(calls,1,'A longer transcript must preserve saved notes without another completion');
  } finally {release();await fs.rm(stateDir,{recursive:true,force:true});}
});

test('a retry completes a partial archive rather than claiming delivery',async()=>{
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-partial-save-'));
  try {
    const payload={recordingId:'partial-fixture',meta:{started:'2026-10-07T10:00:00Z',ended:'2026-10-07T10:01:00Z',audio_started_at:1791367200,status:'stopped',fixture:true,notes_mode:'transcript'},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-07T10:02:00Z',execution_machine:'fixture',execution_location:'recording_mac',segments:[{start_ms:0,end_ms:1000,text:'First fixture utterance.'},{start_ms:1000,end_ms:2000,text:'Second fixture utterance.'}]}};
    const options={stateDir,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory()};
    const {createHash}=await import('node:crypto');
    const id='teams-'+createHash('sha256').update(payload.meta.started+'\n'+payload.recordingId).digest('hex').slice(0,24);
    const record=meetingRecord(payload.meta,payload.transcript,id);
    const {Store}=await archiveRuntime(options.openclawDir);
    const store=new Store(path.join(stateDir,'transcripts'),{env:{...process.env,OPENCLAW_STATE_DIR:stateDir}});
    await store.writeSession(record.session);
    await store.appendUtteranceForSession(record.session,record.utterances[0]);
    const receipt=await saveEnvelope(payload,options);
    assert.equal(receipt.saved,true);assert.equal(receipt.utteranceCount,2);
    assert.match(receipt.documents.transcriptMarkdown,/Second fixture utterance/);
    assert.equal((await store.readUtterancesForSession(record.session)).length,2);
  } finally {await fs.rm(stateDir,{recursive:true,force:true});}
});

test('invalid model output stops automatic completions durably',async()=>{
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-invalid-notes-'));
  try {
    const payload={recordingId:'invalid-fixture',meta:{started:'2026-10-07T10:00:00Z',ended:'2026-10-07T10:01:00Z',audio_started_at:1791367200,status:'stopped',fixture:true,notes_mode:'ai',note_template:{id:'test',name:'Test',context:'Fixture',sections:[{title:'Summary',instructions:'Summarize'}]}},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-07T10:02:00Z',execution_machine:'fixture',execution_location:'recording_mac',segments:[{start_ms:0,end_ms:1000,text:'Synthetic speech.'}]}};
    let calls=0;
    for(let n=0;n<4;n++){
      const options={stateDir,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory(),complete:async()=>{calls++;return {text:'{"sections":[]}',provider:'fixture',model:'test'};}};
      await assert.rejects(saveEnvelope(structuredClone(payload),options),e=>e.code==='ai_invalid_output'&&e.retryable===false);
    }
    assert.equal(calls,1,'Permanent invalid output must survive retries without another paid completion');
  } finally{await fs.rm(stateDir,{recursive:true,force:true});}
});

test('retry after a canonical summary write failure reuses persisted model output',async()=>{
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-summary-failure-'));
  const openclawDir=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory();
  const {Store}=await archiveRuntime(openclawDir),original=Store.prototype.writeSummary;
  let fail=true,calls=0;
  try{
    Store.prototype.writeSummary=async function(...args){if(fail){fail=false;throw Error('Synthetic archive write failure');}return original.apply(this,args);};
    const payload={recordingId:'summary-write-fixture',meta:{started:'2026-10-08T10:00:00Z',ended:'2026-10-08T10:01:00Z',audio_started_at:1791453600,status:'stopped',fixture:true,notes_mode:'ai',note_template:{id:'test',name:'Test',context:'Fixture',sections:[{title:'Summary',instructions:'Summarize'}]}},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-08T10:02:00Z',execution_machine:'fixture',execution_location:'recording_mac',segments:[{start_ms:0,end_ms:1000,text:'Synthetic speech.'}]}};
    const options={stateDir,openclawDir,complete:async()=>{calls++;return {provider:'fixture',model:'fixture-model',text:JSON.stringify({sections:[{title:'Summary',body:'Preserved model result'}]})};}};
    await assert.rejects(saveEnvelope(payload,options),/Synthetic archive write failure/);
    const recovered=await saveEnvelope(payload,options);
    assert.equal(recovered.saved,true);
    assert.match(recovered.documents.notesMarkdown,/Preserved model result/);
    assert.equal(calls,1,'Canonical archive retries must not repeat a successful paid generation');
  }finally{Store.prototype.writeSummary=original;await fs.rm(stateDir,{recursive:true,force:true});}
});
