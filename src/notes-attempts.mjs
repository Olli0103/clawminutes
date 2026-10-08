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
export const recoverableNotesCodes=new Set(['ai_invalid_output','ai_completion_failed','ai_input_too_large','ai_tool_attempt','notes_model_unavailable','notes_owner_required','notes_retry_consumed']);
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function canonical(value){
  if(Array.isArray(value))return value.map(canonical);
  if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])]));
  return value;
}
export function validateNotesRecovery(value,mode){
  if(value===undefined)return undefined;
  if(mode!=='ai'||!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==2||
     !['retry_ai','transcript_only'].includes(value.kind)||typeof value.id!=='string'||!uuid.test(value.id)||
     Object.keys(value).some(k=>!['id','kind'].includes(k)))throw new DeliveryError('invalid_payload','Invalid notes recovery request. Existing files are preserved.');
  return {kind:value.kind,id:value.id.toLowerCase()};
}
async function attemptState(stateDir,id,envelope){
  if(typeof id!=='string'||!/^[-\w.]{1,128}$/.test(id)||id==='.'||id==='..')throw new DeliveryError('notes_state_conflict','Invalid notes state identity.',{status:409});
  const directory=path.join(stateDir,'teams-transcribe','notes-attempts');
  await fs.mkdir(directory,{recursive:true,mode:0o700});
  const file=path.join(directory,id+'.json');
  const base={...envelope};
  if(base.meta){base.meta={...base.meta};delete base.meta.notes_recovery;}
  const legacyFingerprint=createHash('sha256').update(JSON.stringify(base)).digest('hex');
  let fingerprint=createHash('sha256').update(JSON.stringify(canonical(base))).digest('hex');
  let state={schemaVersion:1,fingerprintVersion:2,attempts:0,fingerprint};
  try{
    const data=await readPrivate(file,4096);
    if(data.length>4096)throw Error('Oversized attempt state');
    state=JSON.parse(data);
    if(state.failure&&(!/^[a-z][a-z0-9_]{0,79}$/.test(state.failure.code)||typeof state.failure.detail!=='string'||state.failure.detail.length>512||/[\x00-\x1f]/.test(state.failure.detail)||typeof state.failure.retryable!=='boolean'||!Number.isInteger(state.failure.status)||state.failure.status<400||state.failure.status>599))throw Error('Invalid failure state');
    if(state.schemaVersion!==1||!Number.isSafeInteger(state.attempts)||state.attempts<0||state.attempts>3||
       ![undefined,2].includes(state.fingerprintVersion)||
       (state.fingerprint!==fingerprint&&!(state.fingerprintVersion===undefined&&state.fingerprint===legacyFingerprint)))throw Error('Conflicting attempt state');
    // Preserve legacy hashes and cache bindings when the exact old payload is
    // available. An unprovable old hash never resets the attempt reservation.
    fingerprint=state.fingerprint;
    if(state.recoveries!==undefined&&(!Array.isArray(state.recoveries)||state.recoveries.length>3||new Set(state.recoveries).size!==state.recoveries.length||state.recoveries.some(x=>typeof x!=='string'||!uuid.test(x))))throw Error('Invalid recovery state');
  }catch(error){
    if(error.code!=='ENOENT')throw new DeliveryError('notes_state_conflict','Notes retry state differs or is unreadable. Review this meeting before retrying.',{status:409});
  }
  return {file,fingerprint,state};
}
export async function authorizeTranscriptRecovery(stateDir,id,envelope){
  const {state}=await attemptState(stateDir,id,envelope);
  if(state.attempts===0||state.failure&&!recoverableNotesCodes.has(state.failure.code)&&state.failure.code!=='notes_cache_failed')throw new DeliveryError('notes_recovery_unavailable','This meeting does not have an AI attempt that can be saved as transcript-only notes.',{status:409});
}
export async function withNotesAttempt(stateDir,id,envelope,operation,{cacheResult=false,recoveryId}={}){
  const {file,fingerprint,state}=await attemptState(stateDir,id,envelope);
  if(state.resultSHA256!==undefined){
    try{
      if(!cacheResult||typeof state.resultSHA256!=='string'||!/^[a-f0-9]{64}$/.test(state.resultSHA256))throw Error('Invalid notes cache');
      const data=await readPrivate(file+'.result',2_000_000);
      if(createHash('sha256').update(data).digest('hex')!==state.resultSHA256)throw Error('Notes cache differs');
      const result=JSON.parse(data);if(result.fingerprint!==fingerprint)throw Error('Notes cache differs');
      return result.value;
    }catch{throw new DeliveryError('notes_state_conflict','Generated notes cache is missing or differs. Review before another paid attempt.',{status:409});}
  }
  if(recoveryId!==undefined){
    if(typeof recoveryId!=='string'||!uuid.test(recoveryId)||state.attempts===0)throw new DeliveryError('notes_recovery_unavailable','No failed AI attempt is available to retry.',{status:409});
    if(state.recoveries?.includes(recoveryId))throw new DeliveryError('notes_retry_consumed','This requested AI retry was already used. Review the meeting before requesting another attempt.',{status:422});
    if(state.failure&&!recoverableNotesCodes.has(state.failure.code))throw new DeliveryError('notes_recovery_unavailable','This failure requires review before another paid attempt.',{status:409});
  }
  else if(state.failure?.retryable===false)throw new DeliveryError(state.failure.code,state.failure.detail,{status:state.failure.status});
  if(state.attempts>=3)throw new DeliveryError('ai_retry_limit','AI notes stopped after three attempts. Review the meeting or save transcript-only notes.',{status:422});
  async function persist(){
    await persistPrivate(file,JSON.stringify(state));
  }
  // Reserve before invoking anything that could incur provider cost. A crash
  // consumes this attempt conservatively instead of forgetting it on relaunch.
  state.attempts++;delete state.failure;
  if(recoveryId!==undefined)state.recoveries=[...(state.recoveries||[]),recoveryId];
  await persist();
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
    if(recoveryId!==undefined)failure.retryable=false;
    state.failure={code:failure.code,detail:failure.message,retryable:failure.retryable,status:failure.status};
    await persist();throw failure;
  }
}
