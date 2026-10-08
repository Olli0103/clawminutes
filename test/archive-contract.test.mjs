import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {archiveAdapter} from '../src/archive.mjs';
import {gatewayHandler} from '../src/gateway.mjs';

test('matching SDK version and method names cannot admit a store that loses readback',async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-broken-sdk-'));
  try{
    await fs.mkdir(path.join(root,'dist'));
    await fs.writeFile(path.join(root,'package.json'),JSON.stringify({version:'2026.9.7'}));
    await fs.writeFile(path.join(root,'dist/store-fixture.mjs'),`
      // src/transcripts/store.ts
      export class Store {
        async writeSession() {} async appendUtteranceForSession() {} async writeSummary() {}
        async readSession() { return null; } async readUtterancesForSession() { return []; }
        async readSummary() { return null; }
      }
    `);
    await assert.rejects(archiveAdapter(root),e=>e.code==='plugin_update_needed'&&!e.completionAttempted);
    let calls=0;
    const response={setHeader(){},writeHead(code){this.code=code;},end(body){this.body=JSON.parse(body);}};
    await gatewayHandler({openclawDir:root,stateDir:path.join(root,'canonical'),complete:async()=>{calls++;}})({method:'GET'},response);
    assert.equal(response.code,503);assert.equal(response.body.code,'plugin_update_needed');assert.equal(response.body.retryable,false);
    assert.equal(calls,0);await assert.rejects(fs.stat(path.join(root,'canonical')),e=>e.code==='ENOENT');
  }finally{await fs.rm(root,{recursive:true,force:true});}
});
