import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {installedRuntimeDirectory} from '../src/gateway.mjs';

test('the full plugin entry loads through the Gateway synchronous module loader',async()=>{
  const sdk=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory();
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-entry-'));
  try {
    const repo=new URL('../',import.meta.url);
    await fs.copyFile(new URL('package.json',repo),path.join(root,'package.json'));
    await fs.cp(new URL('src',repo),path.join(root,'src'),{recursive:true});
    await fs.mkdir(path.join(root,'node_modules'));
    await fs.symlink(sdk,path.join(root,'node_modules/openclaw'),'dir');
    const result=spawnSync(process.execPath,['-e',`const entry=require(${JSON.stringify(path.join(root,'src/index.js'))}); if(!entry.default)process.exit(2);`],{encoding:'utf8',timeout:20000});
    assert.equal(result.status,0,result.stderr||String(result.error));
  } finally {await fs.rm(root,{recursive:true,force:true});}
});
