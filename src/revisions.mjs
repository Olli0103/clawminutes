import {createHash} from 'node:crypto';
import {DeliveryError} from './delivery-errors.mjs';

export function archiveIdentity(started,recordingId){
  return 'teams-'+createHash('sha256').update(started+'\n'+recordingId).digest('hex').slice(0,24);
}
export function revisionRecordingId(baseRecordingId,number){
  return 'cmrev-'+createHash('sha256').update(baseRecordingId).digest('hex').slice(0,24)+'-'+number;
}
export function validateRevision(value,{started,recordingId}){
  if(value===undefined)return undefined;
  if(!value||typeof value!=='object'||Array.isArray(value)||
     Object.keys(value).some(k=>!['number','baseRecordingId','parentSessionId','reason'].includes(k))||
     !Number.isSafeInteger(value.number)||value.number<2||value.number>1000||
     typeof value.baseRecordingId!=='string'||!/^[-\w.]{1,128}$/.test(value.baseRecordingId)||
     !['speaker_correction','template_change','retranscription'].includes(value.reason)||
     value.parentSessionId!==archiveIdentity(started,value.number===2?value.baseRecordingId:revisionRecordingId(value.baseRecordingId,value.number-1))||
     recordingId!==revisionRecordingId(value.baseRecordingId,value.number))throw new DeliveryError('revision_conflict','The meeting version has an invalid link to its previous version.',{status:409});
  return {number:value.number,baseRecordingId:value.baseRecordingId,parentSessionId:value.parentSessionId,reason:value.reason};
}
export async function verifyRevisionParent(store,record,revision){
  if(!revision)return;
  const parent=await store.readSession(revision.parentSessionId);
  const fail=()=>{throw new DeliveryError('revision_parent_unavailable','Save the previous meeting version before creating another version. Existing notes are preserved.',{status:409});};
  if(!parent||parent.startedAt!==record.session.startedAt||parent.stoppedAt!==record.session.stoppedAt)fail();
  if(revision.number===2){if(parent.metadata?.revision)fail();}
  else if(parent.metadata?.revision?.number!==revision.number-1||parent.metadata.revision.baseRecordingId!==revision.baseRecordingId)fail();
  const rows=await store.readUtterancesForSession(parent),snapshot=await store.readSummary(parent);
  if(!snapshot?.summary||snapshot.summary.sessionId!==parent.sessionId||snapshot.summary.utteranceCount!==rows.length||
     typeof snapshot.markdown!=='string'||new Set(rows.map(r=>r.id)).size!==rows.length||
     JSON.stringify(snapshot.summary.transcript)!==JSON.stringify(rows.map(u=>`[${u.startedAt}] ${u.speaker.label}: ${u.text}`)))fail();
}
