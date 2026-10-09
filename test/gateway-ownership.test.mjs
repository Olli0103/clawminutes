import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fork} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {installedRuntimeDirectory,saveEnvelope} from '../src/gateway.mjs';
import {archiveIdentity} from '../src/revisions.mjs';
import {withSaveOwnership} from '../src/save-ownership.mjs';

const template={id:'fixture',name:'Fixture',context:'Synthetic',sections:[{title:'Summary',instructions:'Summarize'}]};
function envelope(){return {recordingId:'ownership-fixture',meta:{started:'2026-10-08T10:00:00Z',ended:'2026-10-08T10:01:00Z',audio_started_at:1791453600,status:'stopped',fixture:true,notes_mode:'ai',note_template:template},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-08T10:02:00Z',execution_machine:'fixture-mac',execution_location:'recording_mac',segments:[{source:'system',start_ms:0,end_ms:1000,text:'Synthetic speech.'}]}};}
function worker(root,options={}){
  const child=fork(fileURLToPath(new URL('./fixtures/gateway-save-worker.mjs',import.meta.url)),[],{
    cwd:root,env:{PATH:process.env.PATH,HOME:root,TMPDIR:root,LANG:'C'},stdio:['ignore','ignore','pipe','ipc'],execArgv:[]
  });
  const messages=[];const waiters=[];
  const watchdog=setTimeout(()=>child.kill('SIGKILL'),30000);watchdog.unref();
  child.on('message',message=>{const waiter=waiters.shift();if(waiter)waiter.resolve(message);else messages.push(message);});
  const exit=new Promise(resolve=>child.once('exit',(code,signal)=>{
    clearTimeout(watchdog);
    for(const w of waiters.splice(0))w.reject(Error('Fixture worker exited before its expected message'));
    resolve({code,signal});
  }));
  child.stderr.resume();
  child.send({stateDir:root,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory(),envelope:envelope(),...options});
  return {child,exit,next(){return messages.length?Promise.resolve(messages.shift()):new Promise((resolve,reject)=>waiters.push({resolve,reject}));},async stop(){if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');await exit;}};
}

test('separate Gateway processes cannot complete the same meeting while a save owns it', {timeout:60000},async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-ownership-'));const children=[];
  try{
    const first=worker(root,{hold:true});children.push(first);
    assert.equal((await first.next()).kind,'completion');
    const id=archiveIdentity(envelope().meta.started,envelope().recordingId);
    const budgetFile=path.join(root,'teams-transcribe/notes-attempts',id+'.json');
    const budgetBefore=await fs.readFile(budgetFile);
    const second=worker(root);children.push(second);
    const competing=await second.next();await second.exit;
    assert.deepEqual(competing,{kind:'result',ok:false,calls:0,code:'save_in_progress',retryable:true,completionAttempted:false});
    assert.deepEqual(await fs.readFile(budgetFile),budgetBefore);
    first.child.send({release:true});
    const saved=await first.next();await first.exit;
    assert.equal(saved.ok,true);assert.equal(saved.calls,1);
    const replay=worker(root);children.push(replay);
    const repeated=await replay.next();await replay.exit;
    assert.equal(repeated.ok,true);assert.equal(repeated.calls,0);
  }finally{for(const child of children)await child.stop();await fs.rm(root,{recursive:true,force:true});}
});

test('process death releases ownership without deleting files or resetting reserved budget', {timeout:60000},async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-crash-'));const children=[];
  try{
    const first=worker(root,{hold:true});children.push(first);
    assert.equal((await first.next()).kind,'completion');
    const id=archiveIdentity(envelope().meta.started,envelope().recordingId);
    const file=path.join(root,'teams-transcribe/save-ownership',id+'.sqlite');
    const before=await fs.lstat(file);
    await first.stop();
    const next=worker(root);children.push(next);
    const recovered=await next.next();await next.exit;
    assert.equal(recovered.ok,true);assert.equal(recovered.calls,1);
    const after=await fs.lstat(file);assert.equal(after.ino,before.ino);assert.equal(after.dev,before.dev);
    const budget=JSON.parse(await fs.readFile(path.join(root,'teams-transcribe/notes-attempts',id+'.json')));
    assert.equal(budget.attempts,2);
    const replay=worker(root);children.push(replay);
    assert.equal((await replay.next()).calls,0);await replay.exit;
  }finally{for(const child of children)await child.stop();await fs.rm(root,{recursive:true,force:true});}
});

test('another meeting saves while the first meeting waits for its model', {timeout:60000},async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-independent-'));const children=[];
  try{
    const first=worker(root,{hold:true});children.push(first);
    assert.equal((await first.next()).kind,'completion');
    const second=worker(root,{envelope:{...envelope(),recordingId:'independent-fixture'}});children.push(second);
    const other=await second.next();await second.exit;
    assert.equal(other.ok,true);assert.equal(other.calls,1);
    first.child.send({release:true});assert.equal((await first.next()).ok,true);await first.exit;
  }finally{for(const child of children)await child.stop();await fs.rm(root,{recursive:true,force:true});}
});

test('three durable paid attempts remain capped across separate Gateway processes', {timeout:60000},async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-budget-'));const children=[];
  try{
    let calls=0;
    for(let i=0;i<4;i++){
      const child=worker(root,{fail:true});children.push(child);
      const result=await child.next();await child.exit;calls+=result.calls;
      assert.equal(result.ok,false);assert.equal(result.code,i<3?'ai_completion_failed':'ai_retry_limit');
      assert.equal(result.calls,i<3?1:0);
    }
    assert.equal(calls,3);
    const id=archiveIdentity(envelope().meta.started,envelope().recordingId);
    assert.equal(JSON.parse(await fs.readFile(path.join(root,'teams-transcribe/notes-attempts',id+'.json'))).attempts,3);
  }finally{for(const child of children)await child.stop();await fs.rm(root,{recursive:true,force:true});}
});

test('conflicting cross-process saves wait for ownership, then preserve the completed original', {timeout:60000},async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-conflict-'));const children=[];
  try{
    const first=worker(root,{hold:true});children.push(first);
    assert.equal((await first.next()).kind,'completion');
    const changed=envelope();changed.transcript.segments[0].text='Changed synthetic speech';
    const blocked=worker(root,{envelope:changed});children.push(blocked);
    const busy=await blocked.next();await blocked.exit;
    assert.equal(busy.code,'save_in_progress');assert.equal(busy.calls,0);
    first.child.send({release:true});assert.equal((await first.next()).ok,true);await first.exit;
    const conflict=worker(root,{envelope:changed});children.push(conflict);
    const result=await conflict.next();await conflict.exit;
    assert.equal(result.code,'revision_conflict');assert.equal(result.calls,0);
    const original=worker(root);children.push(original);
    const replay=await original.next();await original.exit;
    assert.equal(replay.ok,true);assert.equal(replay.calls,0);
  }finally{for(const child of children)await child.stop();await fs.rm(root,{recursive:true,force:true});}
});

test('unsafe or corrupt ownership files fail before model calls and preserve their bytes',async()=>{
  const id=archiveIdentity(envelope().meta.started,envelope().recordingId);
  for(const kind of ['file-link','parent-link','hard-link','directory','corrupt','nonempty-database','public-mode','journal-link']){
    const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-unsafe-'));let calls=0;
    try{
      const plugin=path.join(root,'teams-transcribe'),locks=path.join(plugin,'save-ownership'),file=path.join(locks,id+'.sqlite');
      const target=path.join(root,'private-target');const bytes=Buffer.from('Preserved private fixture');
      await fs.writeFile(target,bytes,{mode:0o600});await fs.mkdir(plugin,{mode:0o700});
      if(kind==='parent-link')await fs.symlink(root,locks);
      else{
        await fs.mkdir(locks,{mode:0o700});
        if(kind==='file-link')await fs.symlink(target,file);
        if(kind==='hard-link')await fs.link(target,file);
        if(kind==='directory')await fs.mkdir(file);
        if(kind==='corrupt')await fs.writeFile(file,bytes,{mode:0o600});
        if(kind==='nonempty-database'){
          await fs.writeFile(file,'',{mode:0o600});
          const {DatabaseSync}=await import('node:sqlite');const db=new DatabaseSync(file);
          try{db.exec('CREATE TABLE foreign_state(value TEXT)');}finally{db.close();}
        }
        if(kind==='public-mode')await fs.writeFile(file,'',{mode:0o644});
        if(kind==='journal-link')await fs.symlink(target,file+'-journal');
      }
      const existing=kind==='nonempty-database'?await fs.readFile(file):undefined;
      await assert.rejects(saveEnvelope(envelope(),{stateDir:root,openclawDir:'must-not-load',complete:async()=>{calls++;}}),error=>error.code==='notes_state_conflict'&&!error.completionAttempted&&!error.message.includes(root));
      assert.equal(calls,0);assert.deepEqual(await fs.readFile(target),bytes);
      if(kind==='corrupt')assert.deepEqual(await fs.readFile(file),bytes);
      if(existing)assert.deepEqual(await fs.readFile(file),existing);
      assert.equal(await fs.stat(path.join(root,'transcripts')).catch(()=>undefined),undefined);
    }finally{await fs.rm(root,{recursive:true,force:true});}
  }
});

test('ownership release after an exception preserves the mutex inode and permits the next operation',async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-release-'));
  const id=archiveIdentity(envelope().meta.started,envelope().recordingId);
  try{
    await assert.rejects(withSaveOwnership(root,id,async()=>{throw Error('Synthetic operation failure');}),/Synthetic operation failure/);
    const file=path.join(root,'teams-transcribe/save-ownership',id+'.sqlite'),before=await fs.lstat(file);
    assert.equal(await withSaveOwnership(root,id,async()=>42),42);
    const after=await fs.lstat(file);assert.equal(after.ino,before.ino);assert.equal(after.dev,before.dev);
    assert.equal(after.mode&0o777,0o600);
  }finally{await fs.rm(root,{recursive:true,force:true});}
});

test('closing a contending same-process connection cannot release the active owner', {timeout:60000},async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-same-process-'));const children=[];
  const id=archiveIdentity(envelope().meta.started,envelope().recordingId);
  try{
    await withSaveOwnership(root,id,async()=>{
      await assert.rejects(withSaveOwnership(root,id,async()=>assert.fail('Competing operation must not run')),error=>error.code==='save_in_progress');
      const child=worker(root);children.push(child);
      const blocked=await child.next();await child.exit;
      assert.equal(blocked.code,'save_in_progress');assert.equal(blocked.calls,0);
    });
    assert.equal(await withSaveOwnership(root,id,async()=>true),true);
  }finally{for(const child of children)await child.stop();await fs.rm(root,{recursive:true,force:true});}
});

test('completed receipt verification remains read-only while another process owns the save mutex', {timeout:60000},async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-save-readonly-'));const children=[];
  try{
    const first=worker(root);children.push(first);
    const saved=await first.next();await first.exit;assert.equal(saved.ok,true);
    const id=archiveIdentity(envelope().meta.started,envelope().recordingId);
    const file=path.join(root,'teams-transcribe/save-ownership',id+'.sqlite');
    const ledger=path.join(root,'teams-transcribe/notes-attempts',id+'.json');
    const before=await fs.readFile(file),budget=await fs.readFile(ledger),stat=await fs.lstat(file);
    await withSaveOwnership(root,id,async()=>{
      const verification=worker(root,{verify:true});children.push(verification);
      const verified=await verification.next();await verification.exit;
      assert.equal(verified.ok,true);assert.equal(verified.calls,0);assert.equal(verified.sessionId,saved.sessionId);
    });
    assert.deepEqual(await fs.readFile(file),before);assert.deepEqual(await fs.readFile(ledger),budget);
    const after=await fs.lstat(file);assert.equal(after.ino,stat.ino);assert.equal(after.mtimeMs,stat.mtimeMs);
  }finally{for(const child of children)await child.stop();await fs.rm(root,{recursive:true,force:true});}
});
