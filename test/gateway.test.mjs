import test from 'node:test';
import assert from 'node:assert/strict';
import {validateEnvelope,gatewayHandler} from '../src/gateway.mjs';
const envelope={recordingId:'fixture',meta:{started:'2026-10-01T10:00:00Z',audio_started_at:1790848800},transcript:{engine:'parakeet',model:'parakeet-tdt-0.6b-v3-coreml',created_at:'2026-10-01T10:01:00Z',execution_machine:'recording-mac',execution_location:'recording_mac',segments:[{start_ms:0,end_ms:100,text:'Fixture'}]}};
test('Gateway rejects audio, paths and arbitrary nested metadata',()=>{
 for(const value of [{...envelope,audio:'base64'}, {...envelope,meta:{...envelope.meta,files:{mic:'/private/audio.caf'}}}, {...envelope,transcript:{...envelope.transcript,audio:'base64'}}, {...envelope,transcript:{...envelope.transcript,segments:[{text:'Fixture',rawAudio:'base64'}]}}])assert.throws(()=>validateEnvelope(value),/audio|field/);
});
test('Local only must report recognition on the recording Mac with its actual model',()=>{
 assert.equal(validateEnvelope(envelope).transcript.engine,'parakeet');
 assert.throws(()=>validateEnvelope({...envelope,transcript:{...envelope.transcript,execution_location:'gateway'}}),/recording Mac/);
 assert.throws(()=>validateEnvelope({...envelope,transcript:{...envelope.transcript,model:'scribe_v2'}}),/mismatch/);
});
test('Gateway readiness GET does not capture, transcribe or write an archive',async()=>{
 const response={headers:{},setHeader(k,v){this.headers[k]=v},writeHead(code){this.code=code},end(body){this.body=JSON.parse(body)}};
 await gatewayHandler({})({method:'GET'},response);
 assert.equal(response.code,200);assert.equal(response.body.rawAudioAccepted,false);
});
