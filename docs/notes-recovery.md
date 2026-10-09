# Recovering failed AI notes

Open a meeting with an unresolved issue through **See all → Review**. Its recovery card explains the problem and recommends one action. Supported AI failures offer **Save transcript…** or **More options → Save transcript without AI…**. When an attempt remains, **Try AI notes again…** requests one additional attempt using the Gateway's current notes model. The sheet explains charges before queuing work. It cannot reset the three-attempt limit for that archive version.

Transcript-only recovery preserves the transcript, original recording metadata and recorded failure history. It sends the same text with a closed recovery request containing only a kind and UUID. If the Gateway already saved AI notes and the earlier response was lost, it returns those saved notes without changing them or calling a model. Otherwise it verifies the failed source against its attempt ledger and saves transcript-only notes without another completion. Network outages and expired sign-in can still recover after the AI cap because sending text is independent of generating notes.

An AI recovery UUID grants at most one new reservation from the existing budget. Repeating a failed request cannot call the model again. A successful request returns its saved result on replay. If a process crashes after reserving an explicit attempt, that request is treated as consumed even if provider execution is uncertain. A new explicit request can use an attempt only while the original limit permits it. A [per-meeting OS-managed mutex](gateway-save-ownership.md) now serializes the whole save across participating Gateway processes using the same state root. Contention consumes no paid attempt. Actual installed ownership and writers using older code remain unverified.

The native helper binds a private recovery intent to the recording identity and transcript hash. Schema 2 of `state.json` publishes the intent, authorization and preserved counters in one atomic write. A stale snapshot cannot replace newer progress. Legacy paired records import without being changed, including a previously armed request after an interrupted publication. Prior causes remain in a bounded history and legacy evidence stays frozen. See [pipeline state](pipeline-state.md). This handles process interruption; it is not a hardware durability guarantee.

After transcript-only recovery succeeds, **Regenerate notes…** can create a separate AI-notes version. That is an explicit new archive with its own budget and potential charges. The earlier transcript-only archive and documents stay intact. See [meeting versions](revisions.md).

## Retry fingerprint compatibility

Version 2 fingerprints sort JSON object keys recursively while preserving array order. Swift can serialize the same object with different key orders; key order must not change delivery identity. Recovery UUIDs are excluded from this fingerprint. Speech, participant evidence, templates and other delivery metadata remain bound to it.

Legacy ledgers retain their existing hash and attempt count when the original ordered payload still matches. An unmatched or corrupt old hash is preserved and blocked; it never becomes a fresh budget. A present failure record must have the expected object, code, nonempty detail, boolean retryability and HTTP status fields. Values such as false, null, zero or an empty string are malformed evidence, not an absent failure. Automatic retry, explicit AI retry and transcript-only authorization reject them without changing the ledger or invoking a model. Older failed records whose original serialization is unavailable still need an explicit reconciliation path. That limitation remains open with legacy receipt reconciliation. Completed canonical records use their saved-record readback and do not need a ledger reset.

## Evidence and activation

Isolated real-SDK tests cover one-use retry requests, the three-attempt cap, transcript-only recovery, lost successful replies, changed-source rejection, key-order independence and preservation of legacy budgets. The native HTTP test drives the actual delivery stage and archive writer through the real JavaScript handler and SDK store. It checks failed generation, an explicit retry, transcript-only recovery and a later separate AI revision, with exact synthetic completion counts. It uses temporary exports, injected loopback transport and no Notification Center delivery.

These are source-candidate checks. A real provider, Cloudflare session, user interaction and live helper/Gateway activation still need acceptance and explicit approval. No audio is sent by either recovery action.


The terminal `archive-session` command uses the app's delivery stage. It does not authorize an AI retry or clear a failure. It requires the helper to be stopped, honors the existing retry deadline, reserves an eligible attempt before sending, and persists a structured failure if the save fails. Already verified local documents require no Gateway request. Use the meeting's explicit recovery actions for permanent failures, paid caps or unknown budgets. A returning transport callback alone cannot make the command report success.
