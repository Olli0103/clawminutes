import os from 'node:os';
import {archiveRuntime} from './archive.mjs';

export async function gatewayCapabilities({openclawDir,notesModel}={}){
  const runtime=await archiveRuntime(openclawDir);
  return {plugin:'teams-transcribe',protocolVersion:1,gatewayMachine:os.hostname(),rawAudioAccepted:false,
    notesModelConfigured:notesModel||null,
    archive:{adapterVersion:runtime.adapterVersion,sdkVersion:runtime.version,verification:runtime.verification},
    capabilities:{textEnvelope:1,structuredErrors:1,idempotentCompletedSave:true,cappedNotesAttempts:3,revisions:1,notesRecovery:1,receiptVerification:1,captureGapEvidence:2,maximumCaptureGaps:4096}};
}
