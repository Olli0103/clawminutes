# Delivery evidence and current meeting state

A transcript hash cannot prove which title, participant list or template was sent. Completed receipts now bind two fingerprints. `localTranscriptSHA256` covers the exact local transcript file bytes. `localEnvelopeSHA256` covers the closed text package with sorted JSON object keys. Array order remains significant. The package includes the recording identity, clocks, observed meeting context, participants, notes selection/template, revision, active recovery request, STT provenance, speech and capture gaps. Private capture paths and housekeeping fields are excluded by the same allowlist used for delivery.

Normal saves, receipt verification and local receipt matching use one package builder. Delivery rechecks current transcript bytes and the complete package after its response. Changed metadata cannot silently reuse a completed save or trigger an in-place resend. Saved changes require review and a separate revision. Merely reordering metadata object keys or updating excluded capture housekeeping does not invalidate delivery. Participant-file changes invalidate the backlog cache.

## Changed inputs during delivery

If source files change while a save is in flight, the Gateway may already have committed the original package. The helper keeps that request and response in private `delivery-conflict.<source-hash>.json` evidence. It does not publish a standard receipt or export for the changed source. The permanent `saved_source_changed` failure cannot authorize another AI attempt. The evidence's `sourceSHA256` is the normalized package fingerprint, distinct from receipt verification's SHA-256 of raw request bytes.

This evidence does not verify the current version or authorize deletion. Resolving the original source and creating a new revision remains an explicit review task; there is no automatic overwrite, restoration or budget reset. Failure to persist this evidence remains a local save failure.

## Existing receipts

A receipt missing either fingerprint needs **Verify saved meeting…**, even when its transcript hash matches. That explicit read-only Gateway comparison can add both fingerprints without another completion. Existing declared fingerprints must still match; verification cannot bless changed source bytes. Earlier attempt budgets and legacy files remain intact. See [receipt reconciliation](receipt-reconciliation.md).

Local export retries, speaker revisions and audio cleanup require current source binding. An older incomplete receipt cannot authorize automatic audio deletion. This is a source migration candidate; no installed helper or existing user receipt has been changed by these tests.

## Shared artifact observations

Backlog inspection reports whether it verified a transcript, completed archive documents or the local export. These observations come from source artifacts and receipts, not `state.json` stage labels. Reconciliation uses them to clear obsolete transcription/delivery causes while retaining attempt counts and unknown budget flags. A saved meeting with capture gaps remains Needs attention, with the gap warning taking priority over an earlier missing-model or AI error.

The UI uses these observations for document availability and cause priority. Delivery requires a verified local export before it reports success or emits its saved notification. A successful callback without artifacts is `local_save_unverified`. Audio removal still runs its independent coverage and retained-document checks; an observation or stage flag alone cannot authorize deletion.

## Verification and remaining audit

Minimized isolated regressions failed before the fix for changed title/participants/template, metadata changing during delivery, stale errors hiding saved capture gaps and a successful callback without saved artifacts. The final tests cover those cases, normalized fingerprints, excluded private capture fields, offline resend rejection, preserved conflict evidence, legacy repair and unchanged paid counts. The actual Swift-to-JavaScript contract still verifies original, revised and recovered meetings against both pinned real SDK stores with synthetic completions.

Installed migration and live acceptance remain `needs_evidence`. The state audit also retains local-export retry accounting/backoff and remaining CLI draft-mutation ownership paths as explicit follow-up work. Current source binding fails closed when those paths change a saved source; this does not claim that every mutation entry point is already protected before the change.
