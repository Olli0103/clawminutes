import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {withNotesAttempt} from '../src/notes-attempts.mjs';

test('transient model failures stop at three durable reservations',async()=>{
 const state=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-budget-'));let calls=0;
 try{
  for(let i=0;i<4;i++)await assert.rejects(withNotesAttempt(state,'teams-test',{synthetic:true},async()=>{calls++;throw Error('private provider message');}),e=>e.code===(i<3?'ai_completion_failed':'ai_retry_limit')&&!e.message.includes('private provider'));
  assert.equal(calls,3);
  const saved=JSON.parse(await fs.readFile(path.join(state,'teams-transcribe/notes-attempts/teams-test.json'),'utf8'));
  assert.equal(saved.attempts,3);
 }finally{await fs.rm(state,{recursive:true,force:true});}
});

test('unreadable retry state cannot reset the AI budget',async()=>{
 const state=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-budget-corrupt-'));let calls=0;
 try{
  const directory=path.join(state,'teams-transcribe/notes-attempts');await fs.mkdir(directory,{recursive:true});
  await fs.writeFile(path.join(directory,'teams-test.json'),'{broken');
  await assert.rejects(withNotesAttempt(state,'teams-test',{},async()=>{calls++;}),e=>e.code==='notes_state_conflict'&&!e.retryable);
  assert.equal(calls,0);
 }finally{await fs.rm(state,{recursive:true,force:true});}
});

test('successful generation survives a later archive failure without another completion',async()=>{
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'notes-cache-'));
  try{
    let calls=0;
    const operation=async()=>{calls++;return {notes:{model:'fixture'},sections:[{title:'Summary',body:'Saved result'}]};};
    const first=await withNotesAttempt(stateDir,'teams-'+ 'c'.repeat(24),{fixture:true},operation,{cacheResult:true});
    const again=await withNotesAttempt(stateDir,'teams-'+ 'c'.repeat(24),{fixture:true},operation,{cacheResult:true});
    assert.deepEqual(again,first);
    assert.equal(calls,1);
  }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
test('legacy fingerprint state keeps its remaining budget and an unprovable hash cannot be reset',async()=>{
 const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'notes-legacy-fingerprint-'));let calls=0;
 try{
  const envelope={synthetic:true,meta:{z:1,a:2}};
  const directory=path.join(stateDir,'teams-transcribe/notes-attempts');await fs.mkdir(directory,{recursive:true});
  const file=path.join(directory,'teams-test.json');
  await fs.writeFile(file,JSON.stringify({schemaVersion:1,attempts:2,fingerprint:createHash('sha256').update(JSON.stringify(envelope)).digest('hex'),failure:{code:'ai_invalid_output',detail:'Synthetic',retryable:false,status:422}}));
  await withNotesAttempt(stateDir,'teams-test',envelope,async()=>{calls++;return 'success';},{recoveryId:randomUUID()});
  assert.equal(JSON.parse(await fs.readFile(file,'utf8')).attempts,3);assert.equal(calls,1);
  const bytes=await fs.readFile(file);
  await assert.rejects(withNotesAttempt(stateDir,'teams-test',{meta:{a:2,z:1},synthetic:true},async()=>{calls++;},{recoveryId:randomUUID()}),x=>x.code==='notes_state_conflict');
  assert.deepEqual(await fs.readFile(file),bytes);assert.equal(calls,1);
 }finally{await fs.rm(stateDir,{recursive:true,force:true});}
});
