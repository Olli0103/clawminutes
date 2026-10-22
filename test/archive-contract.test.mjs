import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {archiveRuntime} from '../src/archive.mjs';
import {gatewayHandler,installedRuntimeDirectory} from '../src/gateway.mjs';

test('matching SDK version and method names cannot admit a store that loses readback',async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-broken-sdk-'));
  try{
    await fs.mkdir(path.join(root,'dist'));
    await fs.writeFile(path.join(root,'package.json'),JSON.stringify({name:'openclaw',version:'2026.9.7'}));
    await fs.writeFile(path.join(root,'dist/openclaw-state-db.paths-fixture.mjs'),`import path from 'node:path';export function resolveOpenClawStateSqlitePath(env){return path.join(env.OPENCLAW_STATE_DIR,'state','openclaw.sqlite');}`);
    await fs.writeFile(path.join(root,'dist/store-fixture.mjs'),`
      // src/transcripts/store.ts
      export class Store {
        async writeSession() {} async appendUtteranceForSession() {} async writeSummary() {}
        async readSession() { return null; } async readUtterancesForSession() { return []; }
        async readSummary() { return null; }
      }
    `);
    await assert.rejects(archiveRuntime(root),e=>e.code==='plugin_update_needed'&&!e.completionAttempted);
    let calls=0;
    const response={setHeader(){},writeHead(code){this.code=code;},end(body){this.body=JSON.parse(body);}};
    await gatewayHandler({openclawDir:root,stateDir:path.join(root,'canonical'),complete:async()=>{calls++;}})({method:'GET'},response);
    assert.equal(response.code,503);assert.equal(response.body.code,'plugin_update_needed');assert.equal(response.body.retryable,false);
    assert.equal(calls,0);await assert.rejects(fs.stat(path.join(root,'canonical')),e=>e.code==='ENOENT');
  }finally{await fs.rm(root,{recursive:true,force:true});}
});


test('an unlisted SDK version with the same real store is admitted by its observable contract',async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-future-sdk-'));
  try{
    const sdk=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory();
    await fs.writeFile(path.join(root,'package.json'),JSON.stringify({name:'openclaw',version:'2099.1.1'}));
    await fs.symlink(path.join(sdk,'dist'),path.join(root,'dist'),'dir');
    assert.equal(typeof (await archiveRuntime(root)).Store,'function');
    let calls=0;
    const response={setHeader(){},writeHead(code){this.code=code;},end(body){this.body=JSON.parse(body);}};
    await gatewayHandler({openclawDir:root,stateDir:path.join(root,'canonical'),complete:async()=>{calls++;}})({method:'GET'},response);
    assert.equal(response.code,200);assert.equal(response.body.archive.sdkVersion,'2099.1.1');
    assert.equal(response.body.archive.verification,'isolated-readback-v2');
    assert.equal(calls,0);await assert.rejects(fs.stat(path.join(root,'canonical')),e=>e.code==='ENOENT');
  }finally{await fs.rm(root,{recursive:true,force:true});}
});

import {pathToFileURL} from 'node:url';
import {archiveProbeTimeoutMs} from '../src/archive-contract.mjs';
async function sdkFixture(t,{version='2026.9.7',storeBody,resolverBody}={}){
  const sdk=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory(),dist=path.join(sdk,'dist');
  const files=await fs.readdir(dist);
  let storeFile;
  for(const name of files.filter(name=>/^store-.*\.mjs$/.test(name))) {
    if((await fs.readFile(path.join(dist,name),'utf8')).includes('src/transcripts/store.ts')){storeFile=name;break;}
  }
  const resolverFile=files.find(name=>/^openclaw-state-db\.paths-.*\.mjs$/.test(name));
  assert.ok(storeFile&&resolverFile,'Real SDK fixture modules are required');
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-contract-sdk-'));
  t.after(()=>fs.rm(root,{recursive:true,force:true}));await fs.mkdir(path.join(root,'dist'));
  await fs.writeFile(path.join(root,'package.json'),JSON.stringify({name:'openclaw',version}));
  const storeURL=pathToFileURL(path.join(dist,storeFile)).href,resolverURL=pathToFileURL(path.join(dist,resolverFile)).href;
  await fs.writeFile(path.join(root,'dist/store-fixture.mjs'),`// src/transcripts/store.ts\nimport * as real from ${JSON.stringify(storeURL)};\n${storeBody||'export * from '+JSON.stringify(storeURL)+';'}\n`);
  await fs.writeFile(path.join(root,'dist/openclaw-state-db.paths-fixture.mjs'),resolverBody||`export * from ${JSON.stringify(resolverURL)};`);
  return root;
}

test('readback alone cannot admit readers that mutate the archive',async t=>{
  const root=await sdkFixture(t,{storeBody:`
    const Base=Object.values(real).find(value=>typeof value==='function'&&typeof value.prototype?.appendUtteranceForSession==='function');
    export class UnsafeStore extends Base {
      async readSession(id){const value=await super.readSession(id);if(this.databaseOptions.readOnly&&value)await super.writeSession({...value,title:'Unexpected reader mutation'});return value;}
    }
  `});
  await assert.rejects(archiveRuntime(root),e=>e.code==='plugin_update_needed'&&!e.completionAttempted);
});

test('resolver escape and mismatched database location cannot admit an SDK',async t=>{
  const root=await sdkFixture(t,{resolverBody:`
    import path from 'node:path';
    export function resolveOpenClawStateSqlitePath(env){return path.join(env.OPENCLAW_STATE_DIR,'..','outside.sqlite');}
  `,storeBody:`export class Store {constructor(){throw Error('Must reject resolver before opening the store');} async appendUtteranceForSession(){}}`});
  await assert.rejects(archiveRuntime(root),e=>e.code==='plugin_update_needed');
  const mismatch=await sdkFixture(t,{resolverBody:`
    import path from 'node:path';
    export function resolveOpenClawStateSqlitePath(env){return path.join(env.OPENCLAW_STATE_DIR,'unused.sqlite');}
  `});
  await assert.rejects(archiveRuntime(mismatch),e=>e.code==='plugin_update_needed');
});

test('probe isolates environment and shares only successful checks; readers guard missing and linked databases',async t=>{
  const root=await sdkFixture(t),marker=path.join(root,'probe-observations.jsonl');
  const file=path.join(root,'dist/store-fixture.mjs'),source=await fs.readFile(file,'utf8');
  await fs.writeFile(file,source+`
    import fs from 'node:fs';
    if(process.argv[1]?.endsWith('/archive-probe.mjs')){
      fs.appendFileSync(${JSON.stringify(marker)},JSON.stringify({pid:process.pid,root:process.env.HOME,
        state:process.env.OPENCLAW_STATE_DIR,tmp:process.env.TMPDIR,credential:process.env.CLAWMINUTES_FIXTURE_SECRET??null})+String.fromCharCode(10));
    }
  `);
  const previous=process.env.CLAWMINUTES_FIXTURE_SECRET;process.env.CLAWMINUTES_FIXTURE_SECRET='synthetic-sentinel';
  t.after(()=>{if(previous===undefined)delete process.env.CLAWMINUTES_FIXTURE_SECRET;else process.env.CLAWMINUTES_FIXTURE_SECRET=previous;});
  const results=await Promise.all(Array.from({length:8},()=>archiveRuntime(root)));
  await archiveRuntime(root);
  const observations=(await fs.readFile(marker,'utf8')).trim().split('\n').map(line=>JSON.parse(line));
  assert.equal(observations.length,1,'Concurrent and repeated callers share one successful check');
  const observation=observations[0];assert.equal(observation.credential,null);
  assert.equal(observation.root,observation.state);assert.equal(observation.root,observation.tmp);
  assert.notEqual(observation.root,os.homedir());
  assert.throws(()=>process.kill(observation.pid,0),e=>e.code==='ESRCH');
  await assert.rejects(fs.lstat(observation.root),e=>e.code==='ENOENT');
  const runtime=results[0],state=path.join(root,'canonical');
  assert.equal(await runtime.existingReader(state),null);
  await assert.rejects(fs.lstat(state),e=>e.code==='ENOENT');
  await fs.mkdir(state);await fs.mkdir(path.join(root,'outside'));
  await fs.writeFile(path.join(root,'outside/openclaw.sqlite'),'synthetic outside archive');
  await fs.symlink(path.join(root,'outside'),path.join(state,'state'),'dir');
  await assert.rejects(runtime.existingReader(state),e=>e.code==='plugin_update_needed');
  assert.equal(await fs.readFile(path.join(root,'outside/openclaw.sqlite'),'utf8'),'synthetic outside archive');
});

test('a hung SDK probe is bounded, reaped and removed, and failure does not poison recovery',async t=>{
  const root=await sdkFixture(t),marker=path.join(root,'hung-probe.json'),gate=path.join(root,'hang');
  await fs.writeFile(gate,'synthetic gate');
  const file=path.join(root,'dist/store-fixture.mjs'),working=await fs.readFile(file,'utf8');
  await fs.writeFile(file,working+`
    import fs from 'node:fs';
    if(process.argv[1]?.endsWith('/archive-probe.mjs')&&fs.existsSync(${JSON.stringify(gate)})){
      fs.writeFileSync(${JSON.stringify(marker)},JSON.stringify({pid:process.pid,root:process.env.HOME}));
      await new Promise(()=>{setInterval(()=>{},1000);});
    }
  `);
  const start=performance.now();
  await assert.rejects(archiveRuntime(root),e=>e.code==='plugin_update_needed'&&!e.completionAttempted&&!e.retryable);
  const elapsed=performance.now()-start;
  assert.ok(elapsed>=archiveProbeTimeoutMs-1000&&elapsed<archiveProbeTimeoutMs+10_000,`Deadline was ${elapsed}ms`);
  const observation=JSON.parse(await fs.readFile(marker,'utf8'));
  assert.throws(()=>process.kill(observation.pid,0),e=>e.code==='ESRCH');
  await assert.rejects(fs.lstat(observation.root),e=>e.code==='ENOENT');
  // The source and loaded constructor stay unchanged. A failed check must be
  // retried after this synthetic external block is removed.
  await fs.unlink(gate);
  assert.equal((await archiveRuntime(root)).verification,'isolated-readback-v2');
});

test('a changed source cannot reuse a prior admission or differ between parent and probe',async t=>{
  const root=await sdkFixture(t),file=path.join(root,'dist/store-fixture.mjs');
  await archiveRuntime(root);
  await fs.writeFile(file,`// src/transcripts/store.ts
    export class Broken {async appendUtteranceForSession(){}}
  `);
  await assert.rejects(archiveRuntime(root),e=>e.code==='plugin_update_needed');
  const changed=await sdkFixture(t),entry=path.join(changed,'dist/store-fixture.mjs');
  await fs.appendFile(entry,`
    import fs from 'node:fs';
    if(!process.argv[1]?.endsWith('/archive-probe.mjs'))fs.appendFileSync(${JSON.stringify(entry)},'// changed during import');
  `);
  await assert.rejects(archiveRuntime(changed),e=>e.code==='plugin_update_needed');
});

test('SDK provenance and version display are checked before admission',async t=>{
  const root=await sdkFixture(t);
  for(const pkg of [{name:'other',version:'2026.9.7'},{name:'openclaw'},
    ...['2026.9.9\n','../archive','2026.9.9\u0000','9'.repeat(81)].map(version=>({name:'openclaw',version}))]){
    await fs.writeFile(path.join(root,'package.json'),JSON.stringify(pkg));
    await assert.rejects(archiveRuntime(root),e=>e.code==='plugin_update_needed');
  }
});

test('unexpected and excessive probe output cannot publish readiness',async t=>{
  for(const body of ["process.stdout.write('unexpected output');", "process.stdout.write('x'.repeat(16385));await new Promise(()=>setInterval(()=>{},1000));"]){
    const root=await sdkFixture(t),file=path.join(root,'dist/store-fixture.mjs');
    await fs.appendFile(file,`if(process.argv[1]?.endsWith('/archive-probe.mjs')){${body}}`);
    const start=performance.now();
    await assert.rejects(archiveRuntime(root),e=>e.code==='plugin_update_needed'&&!e.completionAttempted);
    assert.ok(performance.now()-start<10_000,'Output refusal must not wait for the full probe deadline');
  }
});
