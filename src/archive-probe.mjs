// Private child entry. It receives no Gateway credentials or user archive path.
// Process separation bounds probe lifetime; this is not a hostile-code sandbox.
import fs from 'node:fs/promises';
import {writeSync} from 'node:fs';
import path from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {isDeepStrictEqual} from 'node:util';

async function probe(){
  const descriptor=JSON.parse(process.argv[2]),root=process.argv[3];
  async function verifySources(){
    for(const [url,hash] of [[descriptor.storeURL,descriptor.storeSHA256],[descriptor.resolverURL,descriptor.resolverSHA256]]){
      if(createHash('sha256').update(await fs.readFile(new URL(url))).digest('hex')!==hash)throw Error('Archive module changed during admission');
    }
  }
  await verifySources();
  const module=await import(descriptor.storeURL),resolver=await import(descriptor.resolverURL);
  const Store=module[descriptor.storeExport],resolveDatabase=resolver[descriptor.resolverExport];
  const methods=['writeSession','appendUtteranceForSession','writeSummary','readSession','readUtterancesForSession','readSummary'];
  if(typeof Store!=='function'||methods.some(name=>typeof Store.prototype?.[name]!=='function')||typeof resolveDatabase!=='function')throw Error('Archive methods changed');
  const options={env:{...process.env,OPENCLAW_STATE_DIR:root}},directory=path.join(root,'transcripts');
  const database=resolveDatabase(options.env);
  const relative=typeof database==='string'?path.relative(root,database):'..';
  if(typeof database!=='string'||!path.isAbsolute(database)||!relative||relative==='..'||relative.startsWith('..'+path.sep)||path.isAbsolute(relative))throw Error('Archive resolver escaped isolated state');
  try{await fs.lstat(database);throw Error('Fresh archive database already exists');}catch(error){if(error.code!=='ENOENT')throw error;}
  const store=new Store(directory,options),id='teams-probe-'+randomUUID();
  const session={sessionId:id,title:'Synthetic adapter check',source:{providerId:'teams-transcribe',kind:'recording'},
    startedAt:'2026-10-08T00:00:00Z',stoppedAt:'2026-10-08T00:00:01Z',metadata:{fixture:true,contractProbe:2}};
  const utterance={id:id+':0',sessionId:id,startedAt:session.startedAt,endedAt:session.stoppedAt,
    speaker:{label:'Unknown speaker'},text:'Synthetic archive check.',final:true,metadata:{source:'system',attribution:'unknown'}};
  const summary={sessionId:id,title:session.title,generatedAt:session.stoppedAt,source:'transcript-only',
    overview:'Synthetic archive check.',participants:[],decisions:[],actionItems:[],risks:[],
    transcript:['[2026-10-08T00:00:00Z] Unknown speaker: Synthetic archive check.'],utteranceCount:1};
  await store.writeSession(session);
  await store.appendUtteranceForSession(session,utterance);
  await store.appendUtteranceForSession(session,utterance);
  await store.writeSummary(summary,session);
  const info=await fs.lstat(database);
  if(!info.isFile()||info.isSymbolicLink())throw Error('SDK did not use the resolved database');
  const readOnly=new Store(directory,{...options,path:database,readOnly:true});
  const reopened=new Store(directory,options);
  const same=(a,b)=>isDeepStrictEqual(JSON.parse(JSON.stringify(a??null)),JSON.parse(JSON.stringify(b??null)));
  async function readback(reader){
    const saved=await reader.readSession(id),rows=await reader.readUtterancesForSession(session),snapshot=await reader.readSummary(session);
    if(!saved||['sessionId','title','source','startedAt','stoppedAt','metadata'].some(key=>!same(saved[key],session[key]))||
       !Array.isArray(rows)||rows.length!==1||Object.keys(utterance).some(key=>!same(rows[0][key],utterance[key]))||
       !snapshot||typeof snapshot.markdown!=='string'||!snapshot.markdown.includes(utterance.text)||
       Object.keys(summary).some(key=>!same(snapshot.summary?.[key],summary[key])))throw Error('Archive readback differs');
  }
  await readback(reopened);
  // The SDK's readOnly option is not a general no-write guard. Verify only
  // the existing-archive reader operations actually used, with disk evidence.
  async function snapshot(directory){
    const result={};
    async function walk(dir){
      for(const entry of await fs.readdir(dir,{withFileTypes:true})){
        const file=path.join(dir,entry.name);
        if(entry.isDirectory())await walk(file);
        else if(entry.isFile())result[path.relative(directory,file)]=createHash('sha256').update(await fs.readFile(file)).digest('hex');
        else throw Error('Unexpected archive artifact');
      }
    }
    await walk(directory);return result;
  }
  const before=await snapshot(root);
  await readback(readOnly);await readback(readOnly);
  if(!same(before,await snapshot(root)))throw Error('Read-only readers changed archive artifacts');
  await verifySources();
}
try{await probe();writeSync(1,JSON.stringify({ok:true,contract:2}));process.exit(0);}
catch{process.exit(1);}
