import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {DeliveryError} from './delivery-errors.mjs';

// Cache the loaded constructor and exact probe descriptor, never a version name.
// A separate process bounds SDK work and releases its workers before cleanup.
const verified=new WeakMap();
export const archiveProbeTimeoutMs=20_000;
export async function verifyArchiveStore(Store,descriptor){
  const key=JSON.stringify(descriptor);
  let entries=verified.get(Store);
  if(!entries){entries=new Map();verified.set(Store,entries);}
  if(entries.has(key))return entries.get(key);
  const pending=probe(descriptor);entries.set(key,pending);
  try{
    await pending;
    while(entries.size>4)entries.delete(entries.keys().next().value);
  }catch(error){if(entries.get(key)===pending)entries.delete(key);throw error;}
}
async function probe(descriptor){
  let root;
  try{
    root=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-store-probe-'));
    await fs.chmod(root,0o700);
    await new Promise((resolve,reject)=>{
      const child=spawn(process.execPath,[fileURLToPath(new URL('./archive-probe.mjs',import.meta.url)),JSON.stringify(descriptor),root],{
        cwd:root,stdio:['ignore','pipe','ignore'],
        env:{PATH:process.env.PATH||'',HOME:root,OPENCLAW_HOME:root,OPENCLAW_STATE_DIR:root,TMPDIR:root,TMP:root,TEMP:root}
      });
      let output='',bytes=0,failure;
      function stop(error){failure??=error;child.kill('SIGKILL');}
      const timer=setTimeout(()=>stop(Error('Archive probe deadline exceeded')),archiveProbeTimeoutMs);
      child.stdout.on('data',data=>{
        bytes+=data.length;
        if(bytes>16_384)stop(Error('Archive probe output exceeded its bound'));
        else output+=data.toString('utf8');
      });
      child.on('error',error=>{failure??=error;});
      // Await close, including on timeout. Never remove files under a live probe.
      child.on('close',(code,signal)=>{
        clearTimeout(timer);
        if(failure||code!==0||signal){reject(failure||Error('Archive probe failed'));return;}
        try{
          const result=JSON.parse(output);
          if(Object.keys(result).length!==2||result.ok!==true||result.contract!==2)throw Error('Invalid archive proof');
          resolve();
        }catch(error){reject(error);}
      });
    });
  }catch(cause){
    throw new DeliveryError('plugin_update_needed','The Gateway archive adapter failed its isolated contract check. Local files are preserved; no model was called.',{status:503,cause});
  }finally{if(root)await fs.rm(root,{recursive:true,force:true});}
}
