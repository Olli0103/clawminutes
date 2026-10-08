import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {createHash,randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import {archiveAdapter,meetingRecord,assertArchiveReadback,assertUtteranceCompatibility} from './archive.mjs';
import {validateTemplate,validateContext,validateParticipants,generateNotes,documents,restoreGeneratedNotes} from './notes.mjs';
import {DeliveryError,deliveryError,safeErrorDiagnostic} from './delivery-errors.mjs';
import {withNotesAttempt,validateNotesRecovery,authorizeTranscriptRecovery} from './notes-attempts.mjs';
import {archiveIdentity,validateRevision,verifyRevisionParent} from './revisions.mjs';
export function validateEnvelope(value){
  if(!value || typeof value!=='object' || Array.isArray(value) || Object.keys(value).some(k=>!['meta','transcript','recordingId'].includes(k)))throw Error('Only transcript metadata is accepted. Raw audio is forbidden.');
  if(typeof value.recordingId!=='string'||!/^[-\w.]{1,128}$/.test(value.recordingId))throw Error('Invalid recording identity');
  const t=value.transcript,m=value.meta;
  if(!m || !t || typeof m!=='object'||typeof t!=='object'||Array.isArray(m)||Array.isArray(t))throw Error('Invalid transcript metadata');
  if(Object.keys(m).some(k=>!['started','ended','audio_started_at','status','fixture','notes_mode','note_template','meeting_context','participants','revision','notes_recovery'].includes(k))||Object.keys(t).some(k=>!['engine','model','created_at','execution_machine','execution_location','segments','capture_gaps'].includes(k)))throw Error('Unexpected metadata field. Raw audio is forbidden.');
  if(!m || !t || !['parakeet','elevenlabs'].includes(t.engine) || !['parakeet-tdt-0.6b-v3-coreml','scribe_v2'].includes(t.model))throw Error('Invalid STT provenance');
  if(!Number.isFinite(m.audio_started_at)||typeof m.started!=='string'||!Number.isFinite(Date.parse(m.started)))throw Error('Invalid recording clock');
  for(const key of ['ended'])if(m[key]!==undefined && (typeof m[key]!=='string'||!Number.isFinite(Date.parse(m[key]))))throw Error('Invalid recording end clock');
  if(m.status!==undefined&&!['stopped','interrupted','fixture'].includes(m.status))throw Error('Recording is not complete');
  if(m.fixture!==undefined&&typeof m.fixture!=='boolean')throw Error('Invalid fixture provenance');
  for(const key of ['execution_machine','execution_location','created_at'])if(typeof t[key]!=='string'||!t[key].length||t[key].length>256)throw Error('Missing or invalid STT execution provenance');
  if(!Number.isFinite(Date.parse(t.created_at)))throw Error('Invalid transcript clock');
  if(!Array.isArray(t.segments)||t.segments.length>100000)throw Error('Invalid transcript');
  for(const segment of t.segments){
    if(!segment||Object.keys(segment).some(k=>!['speaker','start_ms','end_ms','text','source','speaker_name','attribution'].includes(k)))throw Error('Unexpected utterance field');
    if(typeof segment.text!=='string'||segment.text.length>20000)throw Error('Invalid utterance text');
    for(const key of ['speaker','source','speaker_name','attribution'])if(segment[key]!==undefined&&(typeof segment[key]!=='string'||segment[key].length>256))throw Error('Invalid utterance metadata');
    if(!Number.isInteger(segment.start_ms)||!Number.isInteger(segment.end_ms)||segment.start_ms<0||segment.end_ms<segment.start_ms)throw Error('Invalid utterance clock');
  }
  if(t.capture_gaps!==undefined){
    if(!Array.isArray(t.capture_gaps)||t.capture_gaps.length>32)throw Error('Invalid capture gaps');
    for(const gap of t.capture_gaps){
      if(!gap||typeof gap!=='object'||Array.isArray(gap)||Object.keys(gap).some(k=>!['source','start_ms','end_ms','reason'].includes(k))||
         !['mic','system'].includes(gap.source)||!['capture_failed','buffers_stalled','frame_coverage_shortfall','incomplete_at_stop','helper_interrupted','track_unavailable','device_changed'].includes(gap.reason)||
         !Number.isSafeInteger(gap.start_ms)||!Number.isSafeInteger(gap.end_ms)||gap.start_ms<0||gap.end_ms<gap.start_ms||gap.end_ms>7*24*3600*1000)throw Error('Invalid capture gap evidence');
    }
  }
  if(t.engine==='parakeet' && t.execution_location!=='recording_mac')throw Error('Local only must execute on the recording Mac');
  if(t.engine==='parakeet' && t.model!=='parakeet-tdt-0.6b-v3-coreml')throw Error('Local backend/model mismatch');
  if(t.engine==='elevenlabs' && t.model!=='scribe_v2')throw Error('Cloud backend/model mismatch');
  // Drop all unneeded nested objects. No arbitrary paths, blobs or audio reach storage.
  if(m.notes_mode!==undefined && !['simple','transcript','ai'].includes(m.notes_mode))throw Error('Invalid notes selection');
  if(m.note_template!==undefined)validateTemplate(m.note_template);
  if(m.notes_mode==='ai'&&!m.note_template)throw Error('AI notes require a template');
  if(m.meeting_context!==undefined)validateContext(m.meeting_context);
  if(m.participants!==undefined)validateParticipants(m.participants);
  const revision=validateRevision(m.revision,{started:m.started,recordingId:value.recordingId});
  const notes_recovery=validateNotesRecovery(m.notes_recovery,m.notes_mode);
  return {recordingId:value.recordingId,meta:{started:m.started,ended:m.ended,audio_started_at:m.audio_started_at,status:m.status,fixture:m.fixture===true,notes_mode:m.notes_mode||'simple',note_template:m.note_template,meeting_context:m.meeting_context,participants:m.participants,revision,notes_recovery},transcript:{engine:t.engine,model:t.model,created_at:t.created_at,execution_machine:t.execution_machine,execution_location:t.execution_location,segments:t.segments,capture_gaps:t.capture_gaps}};
}
// Share in-flight ownership across module reloads in the same Gateway process.
const savesKey=Symbol.for('clawminutes.teams-transcribe.pending-saves.v1');
const pendingSaves=globalThis[savesKey]??=new Map();
export async function saveEnvelope(envelope,options={}){
  let e;
  try{e=validateEnvelope(envelope);}catch(error){if(error instanceof DeliveryError)throw error;throw new DeliveryError('invalid_payload',error.message);}
  const key=JSON.stringify([path.resolve(options.stateDir),e.meta.started,e.recordingId]);
  const pending=pendingSaves.get(key);
  if(pending){
    if(!isDeepStrictEqual(pending.envelope,e)||pending.complete!==options.complete)throw new DeliveryError('save_in_progress','A different save of this meeting is in progress. Retry after it finishes.',{retryable:true,status:409});
    return pending.promise;
  }
  const promise=persistEnvelope(e,options);
  pendingSaves.set(key,{envelope:e,complete:options.complete,promise});
  try{return await promise;}finally{pendingSaves.delete(key);}
}
async function persistEnvelope(envelope,{openclawDir,stateDir,complete}={}){
  const e=envelope;const id=archiveIdentity(e.meta.started,e.recordingId);
  let record=meetingRecord(e.meta,e.transcript,id);record.session.metadata.fixture=e.meta.fixture===true;
  const Store=await archiveAdapter(openclawDir);const store=new Store(path.join(stateDir,'transcripts'),{env:{...process.env,OPENCLAW_STATE_DIR:stateDir}});
  await verifyRevisionParent(store,record,e.meta.revision);
  const existing=await store.readSession(id);
  if(existing){
    const rows=await store.readUtterancesForSession(existing);
    assertUtteranceCompatibility(record,rows);
    const snapshot=await store.readSummary(existing);
    if(snapshot?.summary){
      if(rows.length!==record.utterances.length)throw new DeliveryError('revision_conflict','Archived transcript differs. Save changes as a new revision; saved notes are preserved.',{status:409});
      // The previous HTTP response may have been lost after a successful commit.
      // Return the persisted documents without another model call or store write.
      const same=(a,b)=>isDeepStrictEqual(JSON.parse(JSON.stringify(a??null)),JSON.parse(JSON.stringify(b??null)));
      const summary=snapshot.summary;
      if(summary.sessionId!==id||summary.utteranceCount!==rows.length||!same(summary.transcript,record.summary.transcript))throw new DeliveryError('archive_integrity','Canonical archive readback mismatch',{status:409});
      const fallback=existing.metadata?.notesRecovery;
      if(fallback&&!same(fallback,e.meta.notes_recovery))throw new DeliveryError('revision_conflict','This meeting was explicitly saved as transcript-only notes. Existing notes are preserved.',{status:409});
      const notesBackend=fallback?.kind==='transcript_only'?'transcript-only':e.meta.notes_mode==='ai'?'gateway-model':record.session.metadata.notes.backend;
      if(['title','startedAt','stoppedAt','source'].some(k=>!same(existing[k],record.session[k]))||
         ['stt','meetingContext','participants','captureStatus','captureGaps','fixture','revision'].some(k=>!same(existing.metadata?.[k],record.session.metadata[k]))||
         existing.metadata?.notes?.backend!==notesBackend||!same(summary.template,e.meta.note_template))throw new DeliveryError('revision_conflict','Archived meeting metadata differs. Save changes as a new revision; saved notes are preserved.',{status:409});
      const saved={session:existing,utterances:rows,summary};
      assertArchiveReadback(saved,rows,snapshot);
      return archiveReceipt(saved,rows);
    }
  }
  if(e.meta.notes_recovery?.kind==='transcript_only'){
    await authorizeTranscriptRecovery(stateDir,id,e);
    record=meetingRecord({...e.meta,notes_mode:'transcript'},e.transcript,id);
    record.session.metadata.notesRecovery=e.meta.notes_recovery;
    await generateNotes(record,{...e.meta,notes_mode:'transcript'},complete);
  }
  else if(e.meta.notes_mode==='ai'){
    const generated=await withNotesAttempt(stateDir,id,e,async()=>{
      await generateNotes(record,e.meta,complete);
      return {notes:record.session.metadata.notes,sections:record.summary.sections,template:record.summary.template};
    },{cacheResult:true,recoveryId:e.meta.notes_recovery?.id});
    try{
      if(!isDeepStrictEqual(generated.template,e.meta.note_template))throw Error('Cached template differs');
      restoreGeneratedNotes(record,generated);
    }catch{throw new DeliveryError('notes_state_conflict','Generated notes cache is incompatible. Saved text is preserved.',{status:409});}
  }
  else await generateNotes(record,e.meta,complete);
  await store.writeSession(record.session);
  for(const utterance of record.utterances)await store.appendUtteranceForSession(record.session,utterance);
  await store.writeSummary(record.summary,record.session);
  const rows=await store.readUtterancesForSession(record.session);const summary=await store.readSummary(record.session);
  assertArchiveReadback(record,rows,summary);
  return archiveReceipt(record,rows);
}
function archiveReceipt(record,rows){
  return {saved:true,sessionId:record.session.sessionId,utteranceCount:rows.length,stt:record.session.metadata.stt,notes:record.session.metadata.notes,documents:documents(record),archiveExecutionMachine:os.hostname(),savedAt:new Date().toISOString()};
}
export function gatewayHandler(options){
  return async(req,res)=>{
    res.setHeader('Content-Type','application/json');
    const requestId=randomUUID();
    res.setHeader('X-ClawMinutes-Request-ID',requestId);
    let recordingRef;
    const fail=error=>{
      const failure=deliveryError(error);
      res.writeHead(failure.status);res.end(JSON.stringify({saved:false,code:failure.code,retryable:failure.retryable,completionAttempted:failure.completionAttempted,detail:failure.message,error:failure.message,recordingPreserved:true,requestId}));
      // Diagnostics must never turn a completed HTTP response into a rejected handler.
      try { options?.onFailure?.({requestId,...(recordingRef?{recordingRef}:{}),code:failure.code,retryable:failure.retryable,completionAttempted:failure.completionAttempted,...safeErrorDiagnostic(failure)}); } catch { /* best effort */ }
    };
    if(req.method==='GET'){res.writeHead(200);res.end(JSON.stringify({plugin:'teams-transcribe',gatewayMachine:os.hostname(),rawAudioAccepted:false,notesModelConfigured:options?.notesModel||null,capabilities:{structuredErrors:1,idempotentCompletedSave:true,cappedNotesAttempts:3,revisions:1,notesRecovery:1}}));return true;}
    if(req.method!=='POST'){fail(new DeliveryError('method_not_allowed','POST required',{status:405}));return true;}
    if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']||'')){fail(new DeliveryError('content_type_required','JSON transcript metadata only',{status:415}));return true;}
    let size=0;const chunks=[];
    try{
      for await(const chunk of req){size+=chunk.length;if(size>16*1024*1024)throw new DeliveryError('payload_too_large','Transcript package too large',{status:413});chunks.push(chunk);}
      let envelope;
      try{envelope=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{throw new DeliveryError('invalid_payload','The meeting package is not valid JSON.');}
      if(typeof envelope?.recordingId==='string'&&envelope.recordingId.length<=128)recordingRef=createHash('sha256').update(envelope.recordingId).digest('hex').slice(0,24);
      const receipt=await saveEnvelope(envelope,options);
      res.writeHead(200);res.end(JSON.stringify(receipt));
    }catch(error){
      fail(error);
    }
    return true;
  };
}
export function installedRuntimeDirectory(){
  return path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.resolve('openclaw/plugin-sdk/feature-plugin')))));
}
