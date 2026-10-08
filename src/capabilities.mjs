import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {archiveAdapter} from './archive.mjs';

export async function gatewayCapabilities({openclawDir,notesModel}={}){
  await archiveAdapter(openclawDir);
  const sdk=JSON.parse(await fs.readFile(path.join(openclawDir,'package.json'),'utf8'));
  return {plugin:'teams-transcribe',protocolVersion:1,gatewayMachine:os.hostname(),rawAudioAccepted:false,
    notesModelConfigured:notesModel||null,
    archive:{adapterVersion:1,sdkVersion:sdk.version,verification:'isolated-readback-v1'},
    capabilities:{textEnvelope:1,structuredErrors:1,idempotentCompletedSave:true,cappedNotesAttempts:3,revisions:1,notesRecovery:1}};
}
