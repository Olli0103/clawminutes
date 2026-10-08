import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {DeliveryError} from './delivery-errors.mjs';
// Verified SDK releases expose no public completed-record import.
// Use its real canonical store and lease machinery, never write guessed SQLite rows.
const verifiedArchiveVersions = ['2026.9.7','2026.9.8'];
export async function archiveAdapter(openclawDir) {
  if(!openclawDir) throw Error('needs_evidence: installed OpenClaw directory is required for the Meetings archive adapter.');
  const pkg=JSON.parse(await fs.readFile(path.join(openclawDir,'package.json'),'utf8'));
  if(!verifiedArchiveVersions.includes(pkg.version)) throw new DeliveryError('plugin_update_needed',`Archive adapter verified only for OpenClaw ${verifiedArchiveVersions.join(' or ')}, found ${pkg.version}. Recording preserved.`,{status:503});
  const dist=path.join(openclawDir,'dist');
  for(const f of (await fs.readdir(dist)).filter(f=>/^store-.*\.mjs$/.test(f))) {
    const source=await fs.readFile(path.join(dist,f),'utf8');
    if(!source.includes('src/transcripts/store.ts')) continue;
    const module=await import(pathToFileURL(path.join(dist,f)).href);
    const Store=Object.values(module).find(v=>typeof v==='function' && typeof v.prototype?.appendUtteranceForSession==='function');
    if(Store) return Store;
  }
  throw new DeliveryError('plugin_update_needed','needs_evidence: OpenClaw transcript store implementation changed. Recording preserved.',{status:503});
}
export function meetingRecord(meta,transcript,id) {
  if(!Array.isArray(transcript.segments) || !transcript.engine || !transcript.model) throw Error('Invalid transcript provenance');
  const origin=meta.audio_started_at*1000;
  if(!Number.isFinite(origin))throw Error('Missing recording clock');
  const unknown=s=> {
    if(!s.speaker_name)return 'Unknown speaker';
    if(s.attribution==='meeting_voice')return `${s.speaker_name} (voice match, uncertain)`;
    return ['meeting_tile','meeting_ui','accessibility_active_speaker','meeting_tile_edge','local_microphone'].includes(s.attribution) ? s.speaker_name : 'Unknown speaker';
  };
  const fixture=meta.fixture===true||meta.status==='fixture';
  // Older helpers saved this Teams window label in the observed title. Keep the
  // original evidence in metadata while using only the subject for documents.
  const title=meta.meeting_context?.title?.replace(/^Meeting compact view \| /i,'').trim();
  const session={sessionId:id,title:title||(fixture?'Fixture: Teams transcription test':'Teams meeting'),source:{providerId:'teams-transcribe',kind:'recording'},startedAt:meta.started,stoppedAt:meta.ended||transcript.created_at,metadata:{stt:{backend:transcript.engine,model:transcript.model,executionMachine:transcript.execution_machine,executionLocation:transcript.execution_location},notes:{backend:meta.notes_mode==='transcript'?'transcript-only':'extractive-local',model:null,executionMachine:os.hostname()},meetingContext:meta.meeting_context||null,participants:meta.participants||null,captureStatus:meta.status||'unknown',captureGaps:transcript.capture_gaps||[],fixture,nameAttribution:'timestamped Teams Accessibility evidence; uncertain speech unknown'}};
  const utterances=transcript.segments.map((s,i)=> {
    if(!Number.isFinite(s.start_ms)||!Number.isFinite(s.end_ms)||s.end_ms<s.start_ms||typeof s.text!=='string')throw Error('Invalid utterance');
    return {id:`${id}:${i}`,sessionId:id,startedAt:new Date(origin+s.start_ms).toISOString(),endedAt:new Date(origin+s.end_ms).toISOString(),speaker:{label:unknown(s)},text:s.text,final:true,metadata:{source:s.source,start_ms:s.start_ms,end_ms:s.end_ms,attribution:s.attribution,rawSpeaker:s.speaker,nameEvidence:s.speaker_name||null}};
  });
  const summary={sessionId:id,title:fixture?'Fixture: transcription test notes':'Teams meeting notes',generatedAt:new Date().toISOString(),source:'extractive-local',overview:`Speech-to-text: ${transcript.engine} / ${transcript.model}, executed at ${transcript.execution_location} on ${transcript.execution_machine}. Notes: local extractive, no language model. Decisions and owners require review.`,participants:[...new Set(utterances.map(u=>u.speaker.label).filter(n=>n!=='Unknown speaker'))],decisions:[],actionItems:[],risks:['needs_evidence: extracted speech does not by itself establish approvals, owners or commitments.'],transcript:utterances.map(u=>`[${u.startedAt}] ${u.speaker.label}: ${u.text}`),utteranceCount:utterances.length};
  summary.title=session.title;
  if(meta.note_template)summary.template=meta.note_template;
  if(meta.notes_mode==='transcript') {
    summary.title='Teams meeting transcript';
    summary.source='transcript-only';
    summary.overview=`Speech-to-text: ${transcript.engine} / ${transcript.model}, executed at ${transcript.execution_location} on ${transcript.execution_machine}. Notes disabled; no language model.`;
  } else {
    summary.highlights=utterances.slice(0,8).map(u=>({text:u.text,speaker:u.speaker.label,at:u.startedAt}));
  }
  return {session,utterances,summary};
}
export function assertArchiveReadback(record,rows,snapshot) {
  // SDK 2026.9.7 returns {summary, markdown}, not a bare summary.
  assertUtteranceCompatibility(record,rows);
  if(rows.length!==record.utterances.length||!snapshot?.summary||typeof snapshot.markdown!=='string'||snapshot.summary.overview!==record.summary.overview)throw Error('Canonical archive readback mismatch');
  return snapshot.summary;
}
export function assertUtteranceCompatibility(record,rows) {
  // The SDK appends changed utterances instead of replacing them. Never duplicate
  // speech when a completed transcript is corrected; use a separate revision.
  const expected=new Map(record.utterances.map(u=>[u.id,u]));
  const seen=new Set();
  for(const row of rows) {
    const u=expected.get(row.id);
    if(!u||seen.has(row.id)||row.text!==u.text||row.startedAt!==u.startedAt||row.endedAt!==u.endedAt||row.speaker?.label!==u.speaker?.label||['source','start_ms','end_ms','attribution','rawSpeaker','nameEvidence'].some(k=>row.metadata?.[k]!==u.metadata?.[k]))throw new DeliveryError('revision_conflict','Archived transcript differs. Save the correction as a new revision; the original archive is preserved.',{status:409});
    seen.add(row.id);
  }
}
export async function saveMeeting(dir,{openclawDir=process.env.OPENCLAW_TEAMS_OPENCLAW_DIR,stateDir=process.env.OPENCLAW_STATE_DIR||path.join(os.homedir(),'.openclaw')}={}) {
  const [meta,transcript]=await Promise.all(['meta.json','transcript.json'].map(async f=>JSON.parse(await fs.readFile(path.join(dir,f),'utf8'))));
  const id='teams-'+createHash('sha256').update(meta.started+'\n'+path.basename(dir)).digest('hex').slice(0,24);
  const record=meetingRecord(meta,transcript,id);
  const Store=await archiveAdapter(openclawDir);
  const store=new Store(path.join(stateDir,'transcripts'),{env:{...process.env,OPENCLAW_STATE_DIR:stateDir}});
  await store.writeSession(record.session);
  for(const utterance of record.utterances)await store.appendUtteranceForSession(record.session,utterance);
  await store.writeSummary(record.summary,record.session);
  const readback=await store.readUtterancesForSession(record.session);
  const savedSummary=await store.readSummary(record.session);
  assertArchiveReadback(record,readback,savedSummary);
  const receipt={saved:true,sessionId:id,stateDir,utteranceCount:readback.length,stt:record.session.metadata.stt,notes:record.session.metadata.notes,savedAt:new Date().toISOString()};
  await fs.writeFile(path.join(dir,'archive-receipt.json.next'),JSON.stringify(receipt,null,2),{mode:0o600});
  await fs.rename(path.join(dir,'archive-receipt.json.next'),path.join(dir,'archive-receipt.json'));
  return receipt;
}
