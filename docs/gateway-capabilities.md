# Gateway compatibility checks

The helper checks the authenticated ingest endpoint with GET when connecting and before each text delivery. It requires protocol version 1, text envelope version 1, structured errors, immutable completed-save behavior, a three-attempt notes budget, revision and notes-recovery support, and the verified archive contract. Missing or incompatible fields produce `plugin_update_needed` before any meeting text is sent. HTTP 200 alone cannot authorize delivery.

The Gateway performs an isolated archive check before advertising readiness or opening the real archive. It creates a private temporary directory, writes synthetic session metadata, appends the same synthetic utterance twice, writes notes, and reopens the store. It verifies metadata, timestamps, speaker evidence, one deduplicated utterance, the structured summary and Markdown readback. It removes the temporary directory afterwards. It calls no model and writes no user meeting to the canonical archive. Failed probes are not cached as successes.

Successful checks are reused for the loaded store constructor within the process. The first check includes SDK loading and synthetic storage work. It is not a continuous performance monitor or a guarantee against later host changes. Source tests do not establish live event-loop latency, memory stability, cross-process ownership or real-provider completion.

The archive adapter still accepts only the separately tested SDK releases 2026.9.7 and 2026.9.8. The review proposed removing exact version pins after a round-trip probe. This candidate retains the pins because the private store also owns schema and lease behavior that one synthetic round trip does not establish for a new release. The probe strengthens that existing contract; it does not claim an untested host is supported. Broader version admission and a public completed-record import interface remain open.

The status response reports `archive.adapterVersion: 1`, the actual supported SDK version and `archive.verification: "isolated-readback-v1"`. Its capabilities describe the current text protocol. A new helper therefore needs the matching Gateway candidate. Updating or activating that Gateway still requires explicit approval; these source changes cannot update it automatically.

After a successful compatibility check, connection recovery can rearm a matching `plugin_update_needed` failure without resetting delivery or AI attempt counts. A generic Retry without that verified handshake cannot bypass the block. Model-output errors, conflicts and exhausted AI budgets remain blocked. Explicit AI recovery retains its separate confirmation and one-use request.

A meeting with a verified local archive receipt can retry its local export without a handshake or another text send. An offline Gateway cannot prevent that export recovery.

## Verification

A synthetic SDK with the expected version and method names but broken readback was accepted before this fix and is rejected afterwards. Real SDK checks pass on both supported releases. Native regressions verify closed handshake requirements, no speech transmission on incompatibility, matching-failure recovery with preserved budgets, and offline local-export recovery. The native HTTP contract negotiates through the actual JavaScript handler and SDK before exercising delivery with synthetic completions. No live helper, Gateway, credentials or recording are used.
