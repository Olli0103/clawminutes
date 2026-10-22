# Delivery evidence and current meeting state

A transcript hash cannot prove which title, participant list or template was sent. Completed receipts now bind two fingerprints. `localTranscriptSHA256` covers the exact local transcript file bytes. `localEnvelopeSHA256` covers the closed text package with sorted JSON object keys. Array order remains significant. The package includes the recording identity, clocks, observed meeting context, participants, notes selection/template, revision, active recovery request, STT provenance, speech and capture gaps. Private capture paths and housekeeping fields are excluded by the same allowlist used for delivery.

Normal saves, receipt verification and local receipt matching use one package builder. Delivery rechecks current transcript bytes and the complete package after its response. Changed metadata cannot silently reuse a completed save or trigger an in-place resend. Saved changes require review and a separate revision. Merely reordering metadata object keys or updating excluded capture housekeeping does not invalidate delivery. Participant-file changes invalidate the backlog cache.

## Changed inputs during delivery

If source files change while a save is in flight, the Gateway may already have committed the original package. The helper keeps that request and response in private `delivery-conflict.<source-hash>.json` evidence. It does not publish a standard receipt or export for the changed source. The permanent `saved_source_changed` failure cannot authorize another AI attempt. The evidence's `sourceSHA256` is the normalized package fingerprint, distinct from receipt verification's SHA-256 of raw request bytes.

This evidence does not verify the current version or authorize deletion. Resolving the original source and creating a new revision remains an explicit review task; there is no automatic overwrite, restoration or budget reset. Failure to persist this evidence remains a local save failure.

## Existing receipts

A receipt missing either fingerprint needs **Check for saved meeting…**, even when its transcript hash matches. That explicit read-only Gateway comparison can add both fingerprints without another completion. Existing declared fingerprints must still match; verification cannot bless changed source bytes. Earlier attempt budgets and legacy files remain intact. See [receipt reconciliation](receipt-reconciliation.md).

Local export retries, speaker revisions and audio cleanup require current source binding. An older incomplete receipt cannot authorize automatic audio deletion. This is a source migration candidate; no installed helper or existing user receipt has been changed by these tests.

## Shared artifact observations

Backlog inspection reports whether it verified a transcript, completed archive documents or the local export. These observations come from source artifacts and receipts, not `state.json` stage labels. Reconciliation uses them to clear obsolete transcription/delivery causes while retaining attempt counts and unknown budget flags. A saved meeting with capture gaps remains Needs attention, with the gap warning taking priority over an earlier missing-model or AI error.

The UI uses these observations for document availability and cause priority. Delivery requires a verified local export before it reports success or emits its saved notification. A successful callback without artifacts is `local_save_unverified`. Audio removal still runs its independent coverage and retained-document checks; an observation or stage flag alone cannot authorize deletion.

## Verification and remaining audit

Minimized isolated regressions failed before the fix for changed title/participants/template, metadata changing during delivery, stale errors hiding saved capture gaps and a successful callback without saved artifacts. The final tests cover those cases, normalized fingerprints, excluded private capture fields, offline resend rejection, preserved conflict evidence, legacy repair and unchanged paid counts. The actual Swift-to-JavaScript contract still verifies original, revised and recovered meetings against both pinned real SDK stores with synthetic completions.

Installed migration and live acceptance remain `needs_evidence`. The local-export and CLI draft-ownership follow-up is implemented below. Conflicting legacy-ledger resolution and the broader acceptance work remain open.

## Local export and draft ownership

A complete receipt can be exported by `VerifiedLocalExport` without transport, credentials, capability checks or model calls. The optional schema-2 `localExport` record owns its counter, deadline and structured cause. Older schema-2 records decode with no local export attempts. Automatic disk retries stop after three attempts. **Retry saving notes on this Mac** permits another explicit disk attempt, preserves the cumulative count and does not reset any paid-attempt budget. Remote backoff, unknown legacy budgets and three earlier AI failures cannot block a verified offline export. Invalid or unbound legacy destination paths still require review; they cannot silently move history.

A remote save publishes its complete receipt before disk export. If that export fails, the delivery stage records a local export cause and retains the original remote reservation. It does not convert the failure to an AI limit or schedule another completion. Verified export clears the old local cause without erasing its counter. Lifecycle and archive locks cover each local attempt, and an ownership conflict does not reserve a disk attempt.

`DraftSourceOwnership` serializes in-place speech recognition, speaker refresh and manual labels with archive work, audio cleanup and the installer's exclusive lifecycle lease. Finished metadata is mandatory. Any receipt, prior delivery attempt or recovery authorization requires a separate preview or revision. A final fingerprint check protects changed metadata, transcripts, participant observations and analysis before publication. The labeling lock now uses the same no-follow OS-lock implementation as delivery. Preview reads hold source ownership but leave original speech untouched. These locks coordinate cooperating helper commands; they do not prevent arbitrary external filesystem edits between checks and writes.

A genuinely absent local receipt can use the same explicit canonical check. Absence is part of the reviewed snapshot; malformed or conflicting existing files cannot take this path. An exact completed readback can restore the receipt and original notes export while preserving paid counts and unknown budgets. A missing or partial Gateway record, changed source or unsupported verification capability leaves local artifacts unchanged. See [receipt reconciliation](receipt-reconciliation.md).
