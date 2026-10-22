import test from 'node:test';
import assert from 'node:assert/strict';
import {deliveryError,safeErrorDiagnostic} from '../src/delivery-errors.mjs';

test('provider messages and arbitrary names cannot leak into diagnostics or helper failures',()=>{
 const cause=Object.assign(new Error('Bearer secret-token https://private.example/?token=secret'),{name:'RateLimitError',status:429});
 const failure=deliveryError(cause,{completionAttempted:true});
 assert.deepEqual(safeErrorDiagnostic(failure),{errorClass:'RateLimitError',providerStatus:429});
 assert.equal(failure.cause,cause);
 assert.ok(!JSON.stringify(failure).includes('secret'));
 assert.ok(!failure.message.includes('secret'));
 cause.name='secret-token';cause.status='secret';
 assert.deepEqual(safeErrorDiagnostic(failure),{errorClass:'unknown'});
});
