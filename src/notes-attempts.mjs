import fs from 'node:fs/promises';
import {constants} from 'node:fs';
import path from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {DeliveryError,deliveryError} from './delivery-errors.mjs';

// Own delivery metadata, never a guessed write to the SDK's canonical archive.
// Callers serialize the whole save by state directory and meeting identity.
async function readPrivate(file,limit){
  const handle=await fs.open(file,constants.O_RDONLY|constants.O_NOFOLLOW);
  try{const info=await handle.stat();if(!info.isFile()||info.size>limit)throw Error('Invalid private state');return await handle.readFile('utf8');}
  finally{await handle.close();}
}
// Flush the reservation before a provider call. Rename makes readers see one
// complete record; fsync also narrows the crash window beyond process memory.
// A hardware failure can still lose filesystem writes, so this is not a
// provider-side exactly-once guarantee.
async function persistPrivate(file,data){
  const temporary=file+'.'+randomUUID()+'.tmp';
  let handle;
  try{
    handle=await fs.open(temporary,'wx',0o600);
    await handle.writeFile(data);await handle.sync();await handle.close();handle=undefined;
    await fs.rename(temporary,file);
    const directory=await fs.open(path.dirname(file),constants.O_RDONLY);
    try{await directory.sync();}finally{await directory.close();}
  }finally{await handle?.close();await fs.rm(temporary,{force:true});}
}
export async function withNotesAttempt(stateDir,id,envelope,operation,{cacheResult=false}={}){
  if(typeof id!=='string'||!/^[-\w.]{1,128}$/.test(id)||id==='.'||id==='..')throw new DeliveryError('notes_state_conflict','Invalid notes state identity.',{status:409});
  const directory=path.join(stateDir,'teams-transcribe','notes-attempts');
  await fs.mkdir(directory,{recursive:true,mode:0o700});
  const file=path.join(directory,id+'.json');
  const fingerprint=createHash('sha256').update(JSON.stringify(envelope)).digest('hex');
  let state={schemaVersion:1,attempts:0,fingerprint};
  try{
    const data=await readPrivate(file,4096);
    if(data.length>4096)throw Error('Oversized attempt state');
    state=JSON.parse(data);
    if(state.failure&&(!/^[a-z][a-z0-9_]{0,79}$/.test(state.failure.code)||typeof state.failure.detail!=='string'||state.failure.detail.length>512||/[\x00-\x1f]/.test(state.failure.detail)||typeof state.failure.retryable!=='boolean'||!Number.isInteger(state.failure.status)||state.failure.status<400||state.failure.status>599))throw Error('Invalid failure state');
    if(state.schemaVersion!==1||!Number.isSafeInteger(state.attempts)||state.attempts<0||state.attempts>3||state.fingerprint!==fingerprint)throw Error('Conflicting attempt state');
  }catch(error){
    if(error.code!=='ENOENT')throw new DeliveryError('notes_state_conflict','Notes retry state differs or is unreadable. Review this meeting before retrying.',{status:409});
  }
  if(state.resultSHA256!==undefined){
    try{
      if(!cacheResult||typeof state.resultSHA256!=='string'||!/^[a-f0-9]{64}$/.test(state.resultSHA256))throw Error('Invalid notes cache');
      const data=await readPrivate(file+'.result',2_000_000);
      if(createHash('sha256').update(data).digest('hex')!==state.resultSHA256)throw Error('Notes cache differs');
      const result=JSON.parse(data);if(result.fingerprint!==fingerprint)throw Error('Notes cache differs');
      return result.value;
    }catch{throw new DeliveryError('notes_state_conflict','Generated notes cache is missing or differs. Review before another paid attempt.',{status:409});}
  }
  if(state.failure?.retryable===false)throw new DeliveryError(state.failure.code,state.failure.detail,{status:state.failure.status});
  if(state.attempts>=3)throw new DeliveryError('ai_retry_limit','AI notes stopped after three attempts. Review the meeting or save transcript-only notes.',{status:422});
  async function persist(){
    await persistPrivate(file,JSON.stringify(state));
  }
  // Reserve before invoking anything that could incur provider cost. A crash
  // consumes this attempt conservatively instead of forgetting it on relaunch.
  state.attempts++;delete state.failure;await persist();
  try{
    const value=await operation();
    if(cacheResult){
      const data=JSON.stringify({fingerprint,value});
      if(Buffer.byteLength(data)>2_000_000)throw new DeliveryError('notes_cache_failed','Generated notes could not be preserved. Review before another attempt.',{completionAttempted:true,status:503});
      try{
        await persistPrivate(file+'.result',data);
        state.resultSHA256=createHash('sha256').update(data).digest('hex');await persist();
      }catch{throw new DeliveryError('notes_cache_failed','Generated notes could not be preserved. Review before another attempt.',{completionAttempted:true,status:503});}
    }
    return value;
  }
  catch(error){
    const failure=deliveryError(error,{completionAttempted:true});
    state.failure={code:failure.code,detail:failure.message,retryable:failure.retryable,status:failure.status};
    await persist();throw failure;
  }
}
