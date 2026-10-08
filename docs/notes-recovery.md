# Recovering failed AI notes

Open a meeting marked **Needs attention** through **See all → Details**. Supported AI failures offer **Save transcript-only notes…**. When an attempt remains, **Try AI notes again…** requests one additional attempt using the Gateway's current notes model. The sheet explains charges before queuing work. It cannot reset the three-attempt limit for that archive version.

Transcript-only recovery preserves the transcript, original recording metadata and recorded failure history. It sends the same text with a closed recovery request containing only a kind and UUID. If the Gateway already saved AI notes and the earlier response was lost, it returns those saved notes without changing them or calling a model. Otherwise it verifies the failed source against its attempt ledger and saves transcript-only notes without another completion. Network outages and expired sign-in can still recover after the AI cap because sending text is independent of generating notes.

An AI recovery UUID grants at most one new reservation from the existing budget. Repeating a failed request cannot call the model again. A successful request returns its saved result on replay. If a process crashes after reserving an explicit attempt, that request is treated as consumed even if provider execution is uncertain. A new explicit request can use an attempt only while the original limit permits it. Cross-process Gateway ownership remains unverified; the current owner contract serializes requests within one process.

The native helper binds a private recovery intent to the recording identity and transcript hash. It publishes authorization in the retry record only after writing the intent. A partially published replacement keeps the previously armed request; an unarmed intent does not authorize a model call. Prior causes are retained in a bounded history. This is process-crash handling, not a hardware durability guarantee.

After transcript-only recovery succeeds, **Regenerate notes…** can create a separate AI-notes version. That is an explicit new archive with its own budget and potential charges. The earlier transcript-only archive and documents stay intact. See [meeting versions](revisions.md).

## Retry fingerprint compatibility

Version 2 fingerprints sort JSON object keys recursively while preserving array order. Swift can serialize the same object with different key orders; key order must not change delivery identity. Recovery UUIDs are excluded from this fingerprint. Speech, participant evidence, templates and other delivery metadata remain bound to it.

Legacy ledgers retain their existing hash and attempt count when the original ordered payload still matches. An unmatched or corrupt old hash is preserved and blocked; it never becomes a fresh budget. Older failed records whose original serialization is unavailable still need an explicit reconciliation path. That limitation remains open with legacy receipt reconciliation. Completed canonical records use their saved-record readback and do not need a ledger reset.

## Evidence and activation

Isolated real-SDK tests cover one-use retry requests, the three-attempt cap, transcript-only recovery, lost successful replies, changed-source rejection, key-order independence and preservation of legacy budgets. The native HTTP test drives the actual delivery stage and archive writer through the real JavaScript handler and SDK store. It checks failed generation, an explicit retry, transcript-only recovery and a later separate AI revision, with exact synthetic completion counts. It uses temporary exports, injected loopback transport and no Notification Center delivery.

These are source-candidate checks. A real provider, Cloudflare session, user interaction and live helper/Gateway activation still need acceptance and explicit approval. No audio is sent by either recovery action.
