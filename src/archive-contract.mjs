import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {isDeepStrictEqual} from 'node:util';
import {DeliveryError} from './delivery-errors.mjs';

// The version allowlist remains mandatory in archiveAdapter. This probe checks
// observable storage semantics in an isolated directory, never the real archive.
const verified=new WeakMap();
export async function verifyArchiveStore(Store){
  if(verified.has(Store))return verified.get(Store);
  const pending=probe(Store);
  verified.set(Store,pending);
  try{await pending;}catch(error){verified.delete(Store);throw error;}
}
async function probe(Store){
  let root;
  try{
    root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-store-probe-'));
    await fs.chmod(root,0o700);
    const options={env:{...process.env,OPENCLAW_STATE_DIR:root}};
    const directory=path.join(root,'transcripts');
    const store=new Store(directory,options);
    const id='teams-probe-'+randomUUID();
    const session={sessionId:id,title:'Synthetic adapter check',source:{providerId:'teams-transcribe',kind:'recording'},
      startedAt:'2026-10-08T00:00:00Z',stoppedAt:'2026-10-08T00:00:01Z',metadata:{fixture:true,contractProbe:1}};
    const utterance={id:id+':0',sessionId:id,startedAt:session.startedAt,endedAt:session.stoppedAt,
      speaker:{label:'Unknown speaker'},text:'Synthetic archive check.',final:true,metadata:{source:'system',attribution:'unknown'}};
    const summary={sessionId:id,title:session.title,generatedAt:session.stoppedAt,source:'transcript-only',
      overview:'Synthetic archive check.',participants:[],decisions:[],actionItems:[],risks:[],
      transcript:['[2026-10-08T00:00:00Z] Unknown speaker: Synthetic archive check.'],utteranceCount:1};
    await store.writeSession(session);
    await store.appendUtteranceForSession(session,utterance);
    await store.appendUtteranceForSession(session,utterance);
    await store.writeSummary(summary,session);
    const reopened=new Store(directory,options);
    const saved=await reopened.readSession(id),rows=await reopened.readUtterancesForSession(session),snapshot=await reopened.readSummary(session);
    const same=(a,b)=>isDeepStrictEqual(JSON.parse(JSON.stringify(a??null)),JSON.parse(JSON.stringify(b??null)));
    if(!saved||['sessionId','title','source','startedAt','stoppedAt','metadata'].some(key=>!same(saved[key],session[key]))||
       !Array.isArray(rows)||rows.length!==1||Object.keys(utterance).some(key=>!same(rows[0][key],utterance[key]))||
       !snapshot||typeof snapshot.markdown!=='string'||!snapshot.markdown.includes(utterance.text)||
       Object.keys(summary).some(key=>!same(snapshot.summary?.[key],summary[key])))throw Error('Archive contract differs');
  }catch(cause){
    throw new DeliveryError('plugin_update_needed','The Gateway archive adapter failed its isolated readback check. Local files are preserved; no model was called.',{status:503,cause});
  }finally{if(root)await fs.rm(root,{recursive:true,force:true});}
}
