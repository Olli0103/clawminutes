import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {saveEnvelope,installedRuntimeDirectory} from '../src/gateway.mjs';

test('real SDK archive preserves names, timing and gaps through repeated saves',async()=>{
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'clawminutes-sdk-contract-'));
  try {
    const payload={recordingId:'sdk-contract',meta:{started:'2026-10-05T10:00:00Z',ended:'2026-10-05T10:01:00.125Z',audio_started_at:1791194400,status:'stopped',fixture:true,notes_mode:'transcript'},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-05T10:02:00Z',execution_machine:'fixture-recording-mac',execution_location:'recording_mac',segments:[{speaker:'fixture-a',speaker_name:'Fixture Alice',attribution:'meeting_ui',source:'system',start_ms:0,end_ms:1000,text:'Synthetic fixture speech.'},{speaker:'unattributed',source:'mic',start_ms:2500,end_ms:3500,text:'Keep unsupported identity unknown.'}],capture_gaps:[{source:'system',start_ms:1000,end_ms:2000,reason:'buffers_stalled'}]}};
    const options={stateDir,openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory()};
    const first=await saveEnvelope(payload,options);
    const repeated=await saveEnvelope(payload,options);
    assert.equal(first.saved,true);
    assert.equal(repeated.sessionId,first.sessionId);
    assert.equal(repeated.utteranceCount,2);
    assert.equal(repeated.notes.backend,'transcript-only');
    assert.deepEqual(repeated.documents.metadata.metadata.captureGaps,payload.transcript.capture_gaps);
    assert.match(repeated.documents.transcriptMarkdown,/Fixture Alice/);
    assert.match(repeated.documents.transcriptMarkdown,/Unknown speaker/);
    assert.match(repeated.documents.transcriptMarkdown,/2026-10-05T10:00:02.500Z/);
    assert.match(repeated.documents.notesMarkdown,/Capture gaps/);
    const corrected=structuredClone(payload);corrected.transcript.segments[0].text='Changed fixture speech.';
    await assert.rejects(saveEnvelope(corrected,options),/Archived transcript differs/);
  } finally {await fs.rm(stateDir,{recursive:true,force:true});}
});
