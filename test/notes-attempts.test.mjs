import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
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
