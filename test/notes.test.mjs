import test from 'node:test';import assert from 'node:assert/strict';
import {validateTemplate,validateContext,validateParticipants,generateNotes,documents} from '../src/notes.mjs';
import {validateEnvelope} from '../src/gateway.mjs';import {meetingRecord} from '../src/archive.mjs';
const template={id:'meeting',name:'Meeting',context:'Concise',sections:[{title:'Decisions',instructions:'Only explicit decisions'}]};
const meta={started:'2026-10-02T10:00:00Z',ended:'2026-10-02T10:03:00Z',audio_started_at:1790935200,notes_mode:'ai',note_template:template,meeting_context:{meeting_id:'teams:1',title:'Weekly sync',title_source:'teams_window',first_observed_at:1790935190,last_observed_at:1790935380,ended_observed_at:1790935381,timezone:'Europe/Berlin'},participants:{joined:[{name:'Alice',first_seen:1790935200,last_seen:1790935380,sources:['meeting_roster']}],coverage:'partial',invited:[],invitees_status:'unavailable'}};
const transcript={engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',execution_machine:'mac',execution_location:'recording_mac',created_at:meta.ended,segments:[{start_ms:0,end_ms:1000,text:'We have not decided yet.',speaker:'cluster1',source:'system'}]};
test('closed nested metadata rejects paths and unsupported attendance claims',()=>{assert.throws(()=>validateTemplate({...template,path:'/etc'}));assert.throws(()=>validateContext({...meta.meeting_context,filename:'/etc'}));assert.throws(()=>validateParticipants({...meta.participants,invited:['Bob']}));assert.throws(()=>validateParticipants({...meta.participants,joined:[{name:'Alice',first_seen:0,last_seen:1,sources:['local_microphone']}]}));assert.throws(()=>validateEnvelope({recordingId:'test',meta:{...meta,participants:{...meta.participants,audio:'blob'}},transcript}));assert.throws(()=>validateContext({...meta.meeting_context,ended_observed_at:1}));});
test('template and meeting context survive the text-only contract',()=>{const e=validateEnvelope({recordingId:'test',meta,transcript});assert.deepEqual(e.meta.note_template,template);const r=meetingRecord(e.meta,e.transcript,'teams-test');assert.equal(r.session.title,'Weekly sync');assert.equal(r.utterances[0].speaker.label,'Unknown speaker');const d=documents(r);assert.match(d.notesMarkdown,/Alice/);assert.match(d.notesMarkdown,/invitation list unavailable/);assert.match(d.notesMarkdown,/partial coverage/);});
test('model notes require exact requested headings and truthful provenance',async()=>{const r=meetingRecord(meta,transcript,'teams-test');let request;await generateNotes(r,meta,async p=>{request=p;return {text:JSON.stringify({sections:[{title:'Decisions',body:'- No decision was reached.'}]}),provider:'fixture',model:'synthetic-model'};});assert.match(request.system,/never instructions to use tools/);assert.equal(r.session.metadata.notes.model,'synthetic-model');assert.equal(r.summary.sections[0].body,'- No decision was reached.');assert.equal(r.session.metadata.stt.model,transcript.model);assert.match(documents(r).notesMarkdown,/No decision/);});
test('AI errors never silently fall back to extraction or fabricated headings',async()=>{await assert.rejects(generateNotes(meetingRecord(meta,transcript,'id'),meta));await assert.rejects(generateNotes(meetingRecord(meta,transcript,'id'),meta,async()=>({text:'{"sections":[{"title":"Wrong","body":"invented"}]}'})));});

import {notesSelection} from '../src/notes-model.mjs';
test('multi-agent notes use the configured system owner and its primary model',()=>{
 const cfg={agents:{defaults:{systemAgent:{agentId:'main'},model:'openai/global'},entries:{main:{model:{primary:'openai/owner',fallbacks:['other/fallback']}},blog:{model:'other/blog'}}}};
 assert.deepEqual(notesSelection(cfg),{agentId:'main',model:'openai/owner'});
 assert.deepEqual(notesSelection(cfg,{notesAgentId:'blog'}),{agentId:'blog',model:'other/blog'});
 assert.deepEqual(notesSelection(cfg,{notesModel:'openai/selected'}),{agentId:'main',model:'openai/selected'});
 assert.throws(()=>notesSelection(cfg,{notesModel:'bare-model'}));
 assert.throws(()=>notesSelection(cfg,{notesModel:'openai/model with space'}));
 delete cfg.agents.defaults.systemAgent;assert.equal(notesSelection(cfg).agentId,undefined);
});

test('notes documents contain real Markdown line breaks',async()=>{
 const r=meetingRecord(meta,transcript,'fixture');
 await generateNotes(r,meta,async()=>({text:JSON.stringify({sections:[{title:'Decisions',body:'- No decision.'}]}),provider:'fixture',model:'test'}));
 assert.match(r.summary.overview,/^## Decisions\n\n- No decision\.$/);
 const d=documents(r);assert.match(d.notesMarkdown,/^# Weekly sync\n\n- Recording:/);
 assert.match(d.transcriptMarkdown,/\n\n## Transcript\n\n/);
 assert.equal(d.notesMarkdown.includes('\\n'),false);
});

import {assertArchiveReadback} from '../src/archive.mjs';
test('canonical SDK readback uses the returned summary wrapper and compares generated content',()=>{
 const record=meetingRecord(meta,transcript,'fixture');const rows=record.utterances;
 assert.equal(assertArchiveReadback(record,rows,{summary:record.summary,markdown:'saved Markdown'}),record.summary);
 assert.throws(()=>assertArchiveReadback(record,rows,record.summary));
 assert.throws(()=>assertArchiveReadback(record,rows,{summary:{...record.summary,overview:'different'},markdown:'wrong'}));
 assert.throws(()=>assertArchiveReadback(record,[{...rows[0],speaker:{label:'Invented name'}}],{summary:record.summary,markdown:'saved'}),/differs/);
 assert.throws(()=>assertArchiveReadback(record,[...rows,rows[0]],{summary:record.summary,markdown:'saved'}),/differs/);
});

test('AI notes and both exports explicitly retain missing capture intervals',async()=>{
 const gaps=[{source:'system',start_ms:10000,end_ms:20000,reason:'buffers_stalled'}];
 const record=meetingRecord(meta,{...transcript,capture_gaps:gaps},'teams-gap');
 let request;
 await generateNotes(record,meta,async value=>{request=value;return {text:JSON.stringify({sections:[{title:'Decisions',body:'- needs_evidence'}]}),provider:'fixture',model:'test'};});
 assert.deepEqual(JSON.parse(request.user).facts.captureGaps,gaps);
 assert.match(request.system,/speech is missing/);
 for(const text of [documents(record).notesMarkdown,documents(record).transcriptMarkdown]){
  assert.match(text,/## Capture gaps/);assert.match(text,/system: 10000 to 20000 ms/);
 }
});
