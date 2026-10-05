import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {installedRuntimeDirectory} from '../src/gateway.mjs';

test('real SDK discovery admits this plugin on each supported host API',async()=>{
  const sdk=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory();
  let discover;
  for(const name of (await fs.readdir(path.join(sdk,'dist'))).filter(n=>/^discovery-.*\.mjs$/.test(n))) {
    const file=path.join(sdk,'dist',name);
    if(!(await fs.readFile(file,'utf8')).includes('function discoverConfiguredPluginLoadPaths('))continue;
    const module=await import(pathToFileURL(file).href);
    discover=Object.values(module).find(value=>typeof value==='function'&&value.name==='discoverConfiguredPluginLoadPaths');
    if(discover)break;
  }
  assert.ok(discover,'SDK configured-path discovery seam missing');
  const temporary=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-discovery-contract-'));
  try {
    const plugin=path.join(temporary,'plugin');await fs.mkdir(plugin);
    const repo=new URL('../',import.meta.url);
    for(const name of ['package.json','openclaw.plugin.json'])await fs.copyFile(new URL(name,repo),path.join(plugin,name));
    await fs.cp(new URL('src',repo),path.join(plugin,'src'),{recursive:true});
    for(const host of ['2026.9.7','2026.9.8','2026.9.9']) {
      const result=discover({loadPaths:[plugin],workspaceDir:temporary,env:{...process.env,HOME:temporary,OPENCLAW_HOME:temporary,OPENCLAW_STATE_DIR:temporary,OPENCLAW_COMPATIBILITY_HOST_VERSION:host}});
      const admitted=result.candidates.some(candidate=>candidate.packageName==='openclaw-teams-transcribe');
      assert.equal(admitted,host!=='2026.9.9',`${host}: ${result.diagnostics.map(d=>d.message).join('; ')}`);
      if(host==='2026.9.9')assert.ok(result.diagnostics.some(d=>/plugin requires plugin API/.test(d.message)));
    }
  } finally {await fs.rm(temporary,{recursive:true,force:true});}
});
