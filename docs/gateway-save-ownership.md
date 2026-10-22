# Gateway save ownership

The process-local promise map alone did not prevent duplicate paid work. An isolated regression held one process inside its synthetic model callback and sent the same meeting to a second process. The second process called the model and completed the save. The durable attempt file bounded sequential attempts, but it did not own the whole save across processes.

The source candidate now acquires a per-meeting SQLite transaction before SDK admission, completed-record readback, attempt reservation, generation or canonical writes. It keeps ownership until final readback or failure. Same-process identical requests still share their original promise. A competing process receives the existing structured `save_in_progress` response with HTTP 409, retryable true and completionAttempted false. It does not consume an AI attempt. Another meeting uses a separate mutex and can proceed.

## Private mutex files

Files live under `<stateDir>/teams-transcribe/save-ownership/<sessionId>.sqlite`, outside the SDK archive and paid-attempt ledger. The session ID is the existing hash of the start time and recording identity. The mutex contains no transcript, notes, participant names, PID or expiry. The transaction executes no data writes. Isolated checks observed an empty file after release.

The implementation uses Node's built-in `DatabaseSync` with `timeout: 0`, extensions disabled and `BEGIN IMMEDIATE`. Node 24 exposes these options in its [SQLite API](https://github.com/nodejs/node/blob/v24.0.0/doc/api/sqlite.md). SQLite permits one reserved writer at a time for a database, as described in its [locking documentation](https://www.sqlite.org/lockingv3.html). Closing the connection releases the transaction. Killing an isolated owner process also released ownership in the regression. No PID lookup, expiry timer or stale-file removal is involved.

The mutex inode stays on disk after success, failure and process death. Do not delete, replace or rename mutex files while a writer could be active. An open process can still own the old inode, so removing a file does not release its lock. Do not use a lock-file cleanup routine to recover a busy save.

The state root is resolved to its physical directory. Plugin and mutex directories must be owned regular directories. The mutex directory must be private. Existing mutex and journal/WAL/shared-memory leaves must be owned private regular files with one link. The mutex must be empty before and after admission; a nonempty database belongs to an unknown contract and is preserved and blocked. File and parent identity are checked again after transaction admission. Linked, hard-linked, public, corrupt or replaced state fails before model calls. These checks are not an atomic filesystem sandbox against another process replacing parent directories. The configured state root and its storage remain trusted deployment inputs.

## Boundaries

All participating writers must use this implementation and the same physical state root on storage with working SQLite file locks. Older plugin processes, other applications writing the archive directly, copied state roots and unreliable network-filesystem locking are outside this contract. Installed versions and actual outstanding Gateway requests still need investigation. Activating this source candidate requires approval.

The zero busy timeout prevents synchronous waiting for another save's lock. Database open, filesystem access and close still execute synchronously in Node and can have I/O latency. The tests do not establish production event-loop delay, memory, throughput or provider latency.

A crash after a paid reservation still consumes that attempt. The provider may have run even if no result was cached. A later save can use only the remaining budget; the mutex does not make provider execution exactly once or undo cost. Cached successful generations and completed canonical records retain their existing replay checks. Corrupt or unprovable legacy budgets remain blocked.

Read-only receipt verification does not create or acquire this mutex. It can read an already completed archive while a separate process owns the mutex, without model, ledger or mutex writes. It still verifies actual completed-record evidence. It cannot turn a partial write into completion, and it is not an atomic snapshot across arbitrary external archive writers.

## Regression evidence

`node --test test/gateway-ownership.test.mjs` exercises the real JavaScript save path and real SDK stores in temporary homes with synthetic completions. It covers competing processes with zero duplicate completions and unchanged budget, owner death and preserved reservation/inode, independent meetings, three-attempt limits across processes, changed-source conflicts, unsafe/corrupt paths, exception release, same-process connection cleanup and read-only completed receipt verification under an owned mutex. No installed Gateway, helper, model provider, user recording or credentials are used.

These checks establish participating-writer source behavior. They do not close installed ownership, actual model-completion accounting, Gateway event-loop/memory measurements or the signing and activation gates.
