# Durable meeting state

`state.json` schema 2 is the writable authority for a meeting's transcription and delivery attempts, retry times, last structured causes, cause observation times, notes recovery intent and authorization, revision and progress stage. Delivery's `Retry` value is a read-only view of this record. New work does not write or delete `archive-retry.json` or `notes-recovery.json`.

## Migration

Inspection imports schema 1 or missing state in memory. Reading a meeting does not publish files, contact a provider or change documents. The next pipeline mutation writes schema 2 under `state.lock`, with generation 1. Transcription counters and the legacy delivery record are preserved. Legacy attempt counts cannot be lower than the earlier state mirror. Hashes, limits, identities, revisions, failures and recovery requests are validated before admission.

Existing retry and recovery files stay in place as frozen evidence. Their digests are recorded in schema 2. Later changes, removal, newly introduced files or symbolic links block work rather than overriding counters. Do not edit or delete these files to retry a meeting. A downlevel writer cannot silently reset the new helper's budget. Running an older helper against migrated folders is unsupported; migration is a source candidate until installation is approved.

An old AI record without a paid-attempt count remains `legacy_attempts_unverified`. It cannot authorize an AI retry. Explicit transcript-only recovery preserves the unknown budget and still requires the Gateway's source-ledger checks. An unprovable Gateway fingerprint remains blocked; this migration does not reconcile that separate ledger. Verified completed receipts can recover local exports without another model call.

## Concurrent writes and recovery

A state writer acquires an OS file lock and compares the current file hash with the bytes it loaded. If another writer changed or created the record, the write fails with `pipeline_state_conflict`. The writer must reload before deciding what to do. It cannot replace a newer three-attempt limit with a stale zero. Successful writes increment a generation; unchanged writes do not. Atomic replacement publishes each state mutation as one record.

Recovery authorization and its transcript-bound intent are published in the same write. Imported interrupted paired publications retain the previously armed request. Fresh requests preserve counts and prior causes. The Gateway independently enforces its own three-attempt ledger and one-use UUIDs.

## Evidence and limits

Progress is not proof that a provider completed work. Backlog inspection verifies the actual transcript, exact receipt, complete text-package fingerprint and export binding. Its structured transcript/archive/export observations clear obsolete causes without changing attempt counts. A saved capture-gap warning takes priority over an earlier model or AI error. The delivery stage cannot report success from a callback alone. See [delivery evidence](delivery-evidence.md) for source-change handling and remaining audit work. Audio retention separately verifies source coverage and retained documents before removal. A fabricated `audioRemoved` stage cannot authorize deletion. Changing speech after a delivery attempt blocks resending that version instead of starting a new budget.

State is reconciled with verified artifacts after work and during scheduled backlog checks. There is no cross-filesystem transaction covering transcripts, receipts, exports and state. Process interruption can leave a stage behind the artifacts; verified readback repairs progress. Disk or hardware durability is not guaranteed by atomic rename alone. [Legacy receipt verification](receipt-reconciliation.md) repairs matching completed saves without resetting attempt budgets. Earlier conflicting local hashes and unprovable failed-attempt Gateway fingerprints remain blocked. Chunk checkpoints remain unfinished.

Isolated regressions cover read-only schema-1 migration, preserved budgets and frozen files, stale snapshots and stale delivery eligibility, interrupted legacy authorization, unknown budgets, changed speech, malformed records, dangling links and stage flags without receipts. They do not establish installed-helper or live Gateway acceptance.
