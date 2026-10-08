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

test('capture gaps stay text-only and reject arbitrary evidence',()=>{
 const gap={source:'mic',start_ms:10000,end_ms:20000,reason:'buffers_stalled'};
 const payload={...envelope,transcript:{...envelope.transcript,capture_gaps:[gap]}};
 assert.deepEqual(validateEnvelope(payload).transcript.capture_gaps,[gap]);
 for(const invalid of [{...gap,file:'/private/mic.caf'},{...gap,source:'unknown'}, {...gap,end_ms:1}, {...gap,reason:'invented'}, {...gap,audio:'blob'}]){
  assert.throws(()=>validateEnvelope({...payload,transcript:{...payload.transcript,capture_gaps:[invalid]}}),/capture gap/);
 }
});

test('Gateway errors have a machine-readable permanent validation outcome',async()=>{
 const req={method:'POST',headers:{'content-type':'application/json'},async *[Symbol.asyncIterator](){yield Buffer.from('{"audio":"forbidden"}');}};
 const response={setHeader(){},writeHead(code){this.code=code;},end(body){this.body=JSON.parse(body);}};
 await gatewayHandler({})(req,response);
 assert.equal(response.code,422);assert.equal(response.body.code,'invalid_payload');
 assert.equal(response.body.retryable,false);assert.equal(response.body.completionAttempted,false);
});

test('unsupported requests have structured outcomes and redacted correlation events',async()=>{
 for(const [method,contentType,status,code] of [['PUT','application/json',405,'method_not_allowed'],['POST','audio/wav',415,'content_type_required']]){
  const events=[];
  const response={headers:{},setHeader(k,v){this.headers[k]=v;},writeHead(code){this.code=code;},end(body){this.body=JSON.parse(body);}};
  await gatewayHandler({onFailure:e=>events.push(e)})({method,headers:{'content-type':contentType}},response);
  assert.equal(response.code,status);assert.equal(response.body.code,code);
  assert.equal(response.body.retryable,false);
  assert.equal(events[0].requestId,response.headers['X-ClawMinutes-Request-ID']);
 }
});

test('a failing diagnostic sink cannot reject a completed error response',async()=>{
 const response={setHeader(){},writeHead(code){this.code=code;},end(body){this.body=JSON.parse(body);}};
 assert.equal(await gatewayHandler({onFailure(){throw Error('diagnostic sink unavailable');}})({method:'PUT'},response),true);
 assert.equal(response.code,405);
 assert.equal(response.body.code,'method_not_allowed');
});
