import test from 'node:test';
import assert from 'node:assert/strict';
import {meetingRecord,archiveAdapter} from '../src/archive.mjs';
import plugin from '../src/index.js';
const meta={started:'2026-10-01T10:00:00Z',audio_started_at:1790848800,status:'stopped'};
const transcript={engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',execution_machine:'recording-mac',execution_location:'recording_mac',segments:[{start_ms:500,end_ms:900,text:'Fixture speech',source:'system',speaker:'system_1',speaker_name:'Alice',attribution:'meeting_tile'}]};
test('archive preserves clock, STT model, execution host and separate notes provenance',()=>{const r=meetingRecord(meta,transcript,'fixture');assert.equal(r.utterances[0].startedAt,'2026-10-01T10:00:00.500Z');assert.equal(r.session.metadata.stt.model,transcript.model);assert.equal(r.session.metadata.notes.model,null);assert.deepEqual(r.summary.decisions,[]);assert.deepEqual(r.summary.actionItems,[]);});
test('acoustic labels and roster membership alone cannot become participant names',()=>{for(const attribution of ['diarization','participant_roster','audio_source','unknown',undefined]){const t={...transcript,segments:[{...transcript.segments[0],attribution}]};assert.equal(meetingRecord(meta,t,'f').utterances[0].speaker.label,'Unknown speaker');}});
test('bad utterance clock rejects archival',()=>{assert.throws(()=>meetingRecord(meta,{...transcript,segments:[{...transcript.segments[0],end_ms:1}]},'f'),/Invalid utterance/);});
test('plugin registration has no audio capture effect and exposes no remote Start',()=>{const cli=[],node=[],service=[];plugin.register({id:'teams-transcribe',registerHttpRoute:()=>{},registerSessionAction:()=>{},pluginConfig:{},registerCli:(...args)=>cli.push(args),registerNodeHostCommand:c=>node.push(c),registerService:s=>service.push(s)});assert.equal(cli.length,1);assert.deepEqual(node,[]);assert.equal(service.length,0);});
test('archive fails closed without real installed runtime',async()=>{await assert.rejects(archiveAdapter(),/needs_evidence/);});

test('Teams compact view label is excluded from archived and exported meeting titles',()=>{
  const r=meetingRecord({...meta,meeting_context:{title:'Meeting compact view | AI Standup'}},transcript,'fixture');
  assert.equal(r.session.title,'AI Standup');
  assert.equal(r.summary.title,'AI Standup');
  assert.equal(r.session.metadata.meetingContext.title,'Meeting compact view | AI Standup');
  assert.equal(meetingRecord({...meta,meeting_context:{title:'Discussion about Meeting compact view'}},transcript,'fixture').session.title,'Discussion about Meeting compact view');
});

test('notes selection is separate from the recorded speech model', () => {
  const transcript={engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',execution_machine:'recording-mac',execution_location:'recording_mac',segments:[{start_ms:0,end_ms:1000,text:'Fixture speech',source:'mic'}]};
  const base={started:'2026-10-01T10:00:00Z',audio_started_at:1790848800,status:'fixture'};
  const simple=meetingRecord({...base,notes_mode:'simple'},transcript,'teams-notes-fixture');
  const only=meetingRecord({...base,notes_mode:'transcript'},transcript,'teams-transcript-fixture');
  assert.equal(simple.session.metadata.notes.backend,'extractive-local');
  assert.equal(only.session.metadata.notes.backend,'transcript-only');
  assert.equal(only.session.metadata.stt.model,transcript.model);
  assert.equal(only.session.metadata.notes.model,null);
  assert.equal(simple.summary.highlights.length,1);
  assert.equal(only.summary.highlights,undefined);
});

test('voice cluster names remain uncertain in the archive and exports',()=>{
 const record=meetingRecord(meta,{...transcript,segments:[{...transcript.segments[0],attribution:'meeting_voice'}]},'voice-fixture');
 assert.equal(record.utterances[0].speaker.label,'Alice (voice match, uncertain)');
 assert.equal(record.utterances[0].metadata.attribution,'meeting_voice');
 assert.match(record.summary.transcript[0],/Alice \(voice match, uncertain\)/);
});
