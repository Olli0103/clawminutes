import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {installedRuntimeDirectory} from '../src/gateway.mjs';

test('real SDK inspects retained plugin settings and declares no private state migrations',async()=>{
  const sdk=process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory();
  let name;
  for(const candidate of (await fs.readdir(path.join(sdk,'dist'))).filter(n=>/^doctor-contract-registry-.*\.mjs$/.test(n))) {
    if((await fs.readFile(path.join(sdk,'dist',candidate),'utf8')).includes('function applyPluginDoctorCompatibilityMigrations(')) {name=candidate;break;}
  }
  assert.ok(name);
  const mod=await import(pathToFileURL(path.join(sdk,'dist',name)).href);
  const apply=Object.values(mod).find(v=>typeof v==='function'&&v.name==='applyPluginDoctorCompatibilityMigrations');
  const migrations=Object.values(mod).find(v=>typeof v==='function'&&v.name==='listPluginDoctorStateMigrationEntries');
  assert.ok(apply);assert.ok(migrations);
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-doctor-'));
  try {
    const repo=new URL('../',import.meta.url);
    for(const name of ['package.json','openclaw.plugin.json','doctor-contract-api.js']) {
      try {await fs.copyFile(new URL(name,repo),path.join(root,name));}
      catch(error) {if(error.code!=='ENOENT')throw error;}
    }
    const manifest=JSON.parse(await fs.readFile(path.join(root,'openclaw.plugin.json'),'utf8'));
    const record={id:'teams-transcribe',rootDir:root,origin:'config',channels:[],providers:[],doctorContract:manifest.doctorContract};
    const config={plugins:{entries:{'teams-transcribe':{enabled:true,config:{notesModel:'openai/gpt-6-sol',notesAgentId:'main'}}}},unrelated:{keep:true}};
    const before=structuredClone(config); const inspected=new Map();
    const result=apply(config,{pluginIds:['teams-transcribe'],manifestRegistry:{plugins:[record]},onInspectedPlugin:(id,ok)=>inspected.set(id,ok)});
    assert.equal(inspected.get('teams-transcribe'),true,'The update gate must inspect retained configPaths rather than leave them blocked');
    assert.deepEqual(result.config,before);assert.deepEqual(config,before);assert.deepEqual(result.changes,[]);assert.equal(result.warnings,undefined);
    const stateless=[];
    assert.deepEqual(migrations({inventory:{records:[record]},onInspectedStatelessPlugin:id=>stateless.push(id)}),[]);
    assert.deepEqual(stateless,['teams-transcribe']);
    for(const settings of [{notesModel:'invalid'}, {notesAgentId:''}, {unexpected:true}, ['wrong']]) {
      const invalid={plugins:{entries:{'teams-transcribe':{config:settings}}}};
      const saved=structuredClone(invalid);
      const rejected=apply(invalid,{pluginIds:['teams-transcribe'],manifestRegistry:{plugins:[record]}});
      assert.equal(rejected.warnings?.length,1,'Invalid retained settings must keep the migration gate closed');
      assert.deepEqual(invalid,saved);assert.deepEqual(rejected.config,saved);assert.deepEqual(rejected.changes,[]);
    }
  } finally {await fs.rm(root,{recursive:true,force:true});}
});
