# Opus review implementation

The goal covers the complete review and UX proposals. Teams remains the only enabled meeting provider. New meeting providers are excluded from this implementation. Checked items require code and verification evidence; a proposed design alone is not completion.

## Defects and recovery

- [ ] R1 Recover orphaned captures at launch under exclusive ownership, preserve interruption evidence, and restart after crashes without interrupting live capture.
- [ ] R2 Structured delivery/model errors, durable capped AI attempts, bounded retries, per-meeting causes and explicit recovery actions.
- [x] R3 Future-only retention opt-in, explicit historical cleanup, and conservative missing/silent remote capture checks.
- [ ] R4 Consent survives relaunch only for the evidenced ongoing call, with process incarnation and call identity.
- [x] R5 Partial-track recovery with gaps, durable transcription retries and retry after model setup; never present partial speech as complete.
- [x] R6 Completed archive immutability, including longer transcripts and changed metadata; preserve partial-save recovery.
- [ ] R7 Revisions and speaker corrections end to end, including templates and reprocessing, preserving earlier documents.
- [ ] R8 Independent call-window closure evidence and actionable stop countdown; unknown visibility must not stop capture.
- [x] R9 Changing the output folder does not migrate history implicitly. Explicit migration preserves user edits.
- [ ] R10 Immediate microphone device-change handling, time-based recovery budget and recovery-failure notification.
- [ ] R11 Diagnostic error causes, current version provenance and redacted provider/stage logging.
- [x] R12 Malformed configuration survives every settings writer.
- [x] R13 Indexed delivery checks avoid repeatedly hashing saved history while detecting changed inputs.
- [x] R14 Recording housekeeping continues through modal UI; consent avoids stealing focus.

## Architecture and contracts

- [ ] One versioned per-meeting pipeline record, migrated alongside existing artifacts. Irreversible deletion still verifies source artifacts and receipts.
- [x] Separate transcription, delivery and retention implementations behind a small pipeline interface.
- [x] Explicit capability negotiation and an archive adapter contract, without admitting unverified host semantics merely because method names match.
- [x] Isolate Teams detection from dormant provider code; do not enable additional providers.
- [x] Structured event log and a redacted diagnostics command/bundle.
- [ ] Public distribution signing/notarization workflow and permission continuity verification. External signing credentials remain an explicit delivery gate.
- [x] Preserve uncertainty for voice-cluster-derived names in transcripts and AI prompts.
- [ ] Storage usage/free-space checks, legacy receipt reconciliation and accurate reuse documentation.
- [x] Full native suite configured in CI, with Swift-to-JavaScript HTTP tests against the real handler and SDK. A live CI run is still required for each pushed commit.

## User experience

- [x] Status-first pop-up: current meeting, primary recording action, health and processing stages, recent meetings, Open notes, Settings, Pause prompts, Quit.
- [x] Per-meeting attention and success states with one actionable cause; errors do not disappear when a different meeting starts.
- [x] Settings grouped into General, Recording, Notes, Connection, Privacy and storage, Permissions, Advanced.
- [ ] Guided first-run checklist and safe short capture check.
- [ ] Notes-ready notification, actionable call-end and microphone warnings, accessible keyboard controls and light/dark presentation.
- [ ] Speaker correction/revision UI, template import/export and regeneration, local recent-meeting search and quick actions.

## Incremental transcription

- [ ] Durable closed-chunk transcription during recording, final reconciliation, bounded concurrency and recovery checkpoints.
- [ ] Explicit provisional/final transcript semantics; final speech remains authoritative and is the Gateway input.
- [ ] Evaluate and document streaming feasibility with the pinned local engine, measure latency/compute/battery and preserve local-only behavior.
- [ ] Live draft notes, if implemented, use revisioned idempotent identities and cannot overwrite final notes.

## Acceptance and deployment

- [ ] Regression reproduction before each consequential fix; deterministic isolated tests do not contact live providers or mutate user recordings.
- [ ] Audit all requirements against final code, tests, renders and release package.
- [ ] Obtain explicit approval for live installation/reload/restart; never interrupt an active recording.
- [ ] Controlled live crash, outage, sign-in, call-end, device-change and long-meeting acceptance.
- [ ] Gateway event-loop/memory and outstanding-call ownership investigation remains open until directly evidenced. Any disable/reload A/B needs approval.

## Evidence so far

On 8 October, isolated reproductions against real SDK 2026.9.7 and 2026.9.8 confirmed that a completed one-utterance archive accepts a longer transcript and regenerates notes, and four invalid-output saves cause four model callbacks. These are synthetic tests with a stub model and temporary state; they do not call a provider or establish live behavior. The source and isolated tests now establish the following. This does not establish live installation or acceptance.

- Completed saves reject longer or changed transcripts and metadata without another completion. In-place retranscription refuses any existing archive receipt; a separate preview remains available.
- Gateway failures have stable codes and retry policy. A durable budget stops permanent AI failures and caps transient generation attempts at three. Successful generated notes are persisted before canonical writes, and a synthetic canonical write failure recovers with one model callback in total. In-flight ownership survives module reloads in the same process. Cross-process Gateway ownership remains an open host assumption.
- Native delivery attempts retain paid-attempt counts and the last cause across relaunches. Authentication failures pause automatically and can be rearmed by the explicit reconnect/retry path. Permanent model errors cannot be bypassed by that path. Per-meeting recovery UI now offers the matching model, key, sign-in or delivery remedy. Explicit retry after the paid-attempt cap and transcript-only recovery remain open.
- Launch recovery requires the process lock, respects the lifecycle lease and finishes before new capture is enabled. It inspects actual audio beyond stale frame checkpoints, records interruption evidence and does not invent an offline call duration. Installer tests accept orphan metadata only for known protected installs under the exclusive lifecycle lease; legacy and active-work gates remain. The generated launch agent supervises the helper binary after abnormal exit. Real crash/restart timing remains needs_evidence.
- A missing, unreadable or empty audio track becomes an explicit missing-speech gap while usable tracks are transcribed. Valid-track provider/inference failures still fail the job. Durable transcription retry now caps work at three attempts across relaunches. Missing models and rejected credentials pause until the matching setup action requeues them.
- Automatic deletion requires a timestamped future-only opt-in. An untimed legacy setting cannot delete automatically. A recording with no transcribed Teams speech retains audio even when durations and receipts match. Historical verification/deletion remains a separate explicit command.
- Exports bind to their original root. Changing the default cannot migrate them. The explicit migration command copies user-edited files, keeps originals and rejects conflicts.
- Missing AX windows stay unknown unless destroyed-element evidence and the independent all-Spaces WindowServer inventory corroborate closure. A replacement call window keeps the call present. Live Spaces and fullscreen acceptance remains needs_evidence.
- Unchanged delivery inputs reuse verified backlog entries. File identity, size, nanosecond mtime and ctime invalidate changes, including edits with restored size/mtime. Deletion still re-verifies all artifacts.
- Consent persists process launch time, a title hash and observed WindowServer IDs. Isolated regressions cover restored same-call consent, new call windows and PID reuse. Unidentified calls cannot persist PID-only suppression. Reusing the same title and window while the helper is off remains ambiguous; no stable Teams call ID is exposed by the current evidence.
- Recording and detection timers run in common and modal-panel modes. Consent uses a non-activating asynchronous panel. Offscreen light/dark panel renders were inspected. Focus behavior remains a live acceptance item.
- Both malformed-settings overwrite regressions pass. Other existing settings writers retain their parse guards. The User-Agent reads the bundled version. Reuse documentation now describes the implemented segment recovery.

Current local evidence: the full native suite ran 278 tests, with 266 passing and 12 opt-in fixture/live tests skipped. All 31 JavaScript tests pass against each supported real SDK release, including the canonical-write-failure cache regression. The installer suite passes 10 isolated tests. The native HTTP test sends the actual Swift envelope through the real JavaScript handler and real SDK store, confirms one synthetic completion across a repeated save and a conflicting longer transcript, and verifies rejection of raw audio. No real provider, live call or Gateway restart was used.

### Second implementation checkpoint

The full native suite now runs 293 tests, with 281 passing and 12 opt-in tests skipped. All 34 JavaScript tests pass against each supported SDK. The earlier installer suite remains unchanged at 10 passing tests. Tests use temporary recording roots, synthetic model callbacks and URL-protocol responses. No live helper or Gateway was restarted, installed or activated.

- A versioned `state.json` imports alongside legacy artifacts. It records transcription attempts, causes and stages without trusting a stage flag as proof of delivery or permission to delete audio. Invalid state is preserved and blocks provider calls. Delivery still has a legacy retry record, so the single-record migration and pipeline split are not complete.
- Automatic transcription retries run while the app stays open, honor persisted backoff and stop after three attempts across process relaunches. Downloading the model or replacing a rejected API key rearms only that cause. Other permanent causes stay blocked.
- The popover shows the primary action, current capture health and three recent meetings. Each meeting retains its own issue. Seven Settings pages separate recording, notes, connection, privacy, permissions and advanced controls. Offscreen light/dark popover and all light Settings renders were inspected. No visible UI, capture, Keychain mutation or real sign-in was used for those previews.
- Notes-ready and call-end notifications have scoped actions. Keep recording uses a per-recording UUID, so an old action cannot affect a subsequent recording. Notification Center delivery and focus behavior remain `needs_evidence`.
- Microphone configuration changes trigger recovery on the next housekeeping tick. Recovery rotates rather than discards the original segment and allows three attempts per source in a rolling ten-minute interval. Tests cover stale engine callbacks and renewed budgets. Live AirPods/USB switching and actual gap duration remain `needs_evidence`.
- Capture refuses to start with less than 1 GB available. Recent successful writes determine the live health line. Digital silence still counts as captured audio. Storage usage is read-only. This is not a capacity guarantee for a long meeting.
- Gateway errors include a correlation ID and allowlisted error class and HTTP status for diagnostics. Raw exception messages never enter that diagnostic event. A failing diagnostic callback cannot reject an already completed error response.

Still open: explicit capped-failure recovery and revisions, inferred-speaker uncertainty, diagnostic bundle and structured local events, capability negotiation, provider separation, onboarding, search and template exchange, historical-cleanup and migration UI, chunk transcription, packaging/signing, and controlled live acceptance.

### Third implementation checkpoint

Recognition engine ownership and track alignment now live in `RecordingTranscriber`. Text delivery has a separate serial stage and artifact-verifying retention remains separate. The coordinator schedules work and publishes progress. This separation does not finish the legacy retry-record migration.

Native readable transcripts, Gateway archive labels and AI input retain `meeting_voice` uncertainty. Tests verify the label and evidence fields through native serialization and Gateway note generation. They do not verify a real model's semantic compliance. Existing completed archives remain immutable.

`ocmh diagnose` and Advanced Settings create a new redacted JSON report without capture, provider calls or recording locks. Allowlisted fields exclude speech, names, paths, credentials and raw errors. Bounded structured events record progress writes. Four regressions verify redaction, malformed state, linked inputs, bounded rotation and non-overwrite behavior. Lock ownership is explicitly unverified.

Local verification: 298 native tests, 286 passed and 12 opt-in tests skipped; 36 JavaScript tests on each supported SDK. Previous checkpoint `2de80a7` has a passing PR CI run. Its push CI failed before native tests because a runner lacked the hard-coded Xcode filename. The workflow now selects the installed Xcode 27+ toolchain, and that selection was checked locally. CI must verify the new commit.

### Library and template exchange checkpoint

The meeting library lists local recordings with title search, an attention filter, Open, Details and Copy notes. It searches titles only; a full-text index is still open. Recent-meeting refresh now checks Markdown availability using file metadata rather than rereading full documents, preserving the backlog index's benefit.

The template editor imports a closed, versioned JSON format as a new unsaved draft and exports to a new file. Imports cannot replace an existing template, and exports refuse to overwrite files. Size, schema, fields and headings are validated. Offscreen library and editor renders were inspected and their root backgrounds corrected.

The full native suite ran 303 tests, with 291 passing and 12 opt-in tests skipped. Focused UI/template/library tests also pass after the render fixes. German short mute-label fixtures now include `Stummschalten` with or without a shortcut, while a notification mute label does not establish a call. Live German Teams remains `needs_evidence`. Both CI runs for `56f903c` pass after toolchain discovery replaced the hard-coded path.

Remaining source work includes revisions and explicit capped-failure recovery, speaker correction, full-text search, legacy receipt reconciliation, the final single-record migration, capability probing, provider isolation, onboarding and storage/migration UI, incremental transcription, signing/package audit and approved live acceptance. New providers remain disabled.

### Revision checkpoint

Separate version identities now support exact-turn speaker correction, template regeneration and replacement transcripts from a separate re-transcription preview. The Gateway validates the closed descriptor and canonical parent before generation. Completed revisions retain the existing immutability and idempotency guards. Native creation stages text privately, preserves source artifacts and copies no audio. Local exports keep edited originals and use a version suffix for the new record.

Meeting details expose correction and template sheets. Correction previews up to eight seconds from a validated local track only after a play click; deleted audio is reported unavailable. Version metadata and unidentified-turn counts avoid claiming a count of actual speakers. The new CLI uses the same revision implementation. A Swift HTTP regression exercises a revision through the real handler and SDK, verifies the original documents remain unchanged and counts exactly two synthetic completions across original, revision, repeats and invalid saves.

Verification so far: 309 native tests, 297 passed and 12 opt-in tests skipped; 38 JavaScript tests pass on both supported SDKs. A focused preview regression initially compared macOS `/var` and `/private/var` aliases as different URLs; its assertion now compares resolved paths. Light/dark correction and regeneration sheets were rendered offscreen and inspected. The final full native run and 24 focused tests pass; CI still needs to check the new commit. Both prior `a3b6686` CI runs passed. No helper or Gateway restart, activation, capture, real audio playback, settings mutation or provider completion occurred.

R7 remains open for live acceptance and failure interactions. Explicit capped-failure recovery and transcript-only recovery for an unsaved original remain the next source work. The full goal also retains the architecture, onboarding, incremental transcription, packaging and live checks listed above.

### Failed-notes recovery checkpoint

Meeting details now offer transcript-only recovery and, where budget remains, one explicit AI attempt. Recovery requests cannot reset the Gateway's reservations. Replay of a failed explicit UUID makes no completion; replay of a successful save returns the stored result. An original save whose HTTP reply was lost returns its AI notes even when transcript-only recovery was requested. Native recovery preserves original transcript and metadata, retains prior causes, binds authorization to the transcript hash, and does not turn network or sign-in failures into an AI-cap error while sending text-only notes.

The actual Swift delivery/archive path now runs through a loopback transport and temporary export root in the real SDK contract test. Its five synthetic completions cover the original save, a revision, two failed attempts for another recording and a later explicit AI revision. Transcript-only recovery and replay make no completion. Notification delivery is injected out of this test; no credentials, live Gateway or real recording are used.

That test exposed a previously hidden retry bug: JSON key order changed the ledger hash even when values were identical. A minimized key-order-only regression failed before the fix and passes afterwards. Version 2 fingerprints normalize object keys while retaining array order. Legacy hashes and caches stay bound to their original fingerprint; an unmatched old hash cannot silently reset its budget. Unprovable old failed payloads remain an explicit reconciliation limitation.

Verification: 313 native tests, 301 passed and 12 opt-in tests skipped. The final expanded delivery/recovery contract and focused suite pass 15 tests. All 44 JavaScript tests pass on both supported SDKs. Light recovery sheets were rendered offscreen and inspected. Both CI runs for `bf3029e` passed. The new source still needs its own CI and approved live acceptance. The remaining full-scope work includes final single-record migration, capability probing, provider isolation, onboarding, full-text search, storage/migration UI, incremental transcription, packaging/signing and the live checks above.

### Capability verification checkpoint

Connection checks and each pending text save require a versioned Gateway handshake. An incompatible HTTP 200 response sends no speech and produces `plugin_update_needed`. Matching connection failures can be rearmed after a verified handshake without resetting attempt counts or granting another AI retry. Verified local exports still recover offline.

The archive adapter performs a synthetic session/utterance/summary round trip, duplicate append and reopened-store readback in a private temporary directory before canonical use. It calls no model and caches successful verification for the loaded store constructor. A fake store with matching methods but lost readback reproduces the earlier structural-only admission and now fails closed. The real contracts pass on SDK 2026.9.7 and 2026.9.8. Exact version pins remain deliberately narrower than the review proposal; one probe does not establish new private schema/lease semantics. Broader admission and a public import interface remain open, as does live compatibility acceptance.

Full local verification: 316 native tests, 304 passed and 12 opt-in tests skipped; 45 JavaScript tests on each supported SDK. The earlier focused suite passed 18 tests before the final offline-export assertion; the final full suite includes it. Both `d3555d6` CI runs passed. No live helper/Gateway, real archive, credentials or settings were changed. Details are in [Gateway compatibility checks](gateway-capabilities.md).

### Teams adapter isolation checkpoint

The enabled scanner now owns only native Teams detection and speaker observations. Both discovery and scanner input require supported Teams bundle/service evidence. Rejected inputs return before the permission callback or Accessibility access. Teams roster extraction no longer dispatches through a provider selector. The existing title/consent identity, frame-timing guards, latched end evidence, independent all-Spaces closure check and incremental speaker-tree refresh remain. No additional provider or browser-caption action was added.

Pure inherited provider parsers are grouped under `Meetings/Legacy` for fixtures. The visual Zoom detector moved into the test target; the built helper's symbols contain neither that actor/sample type nor `SCScreenshotManager`. Three isolated regressions cover rejected/forged app inputs, a denied Teams permission callback without tree access, and roster membership that cannot imply a speaking frame.

The full native suite passes 319 tests with 307 passed and 12 opt-in tests skipped. The prior initial focused evidence passed 35 tests with one opt-in skipped. Gateway code is unchanged since its 45-test suites on both SDKs and both passing `c1fb701` CI runs. No live scanner, provider, capture, permissions or helper/Gateway lifecycle was exercised. Live Teams regressions remain part of approved acceptance.

### Authoritative retry-state checkpoint

Schema 2 of `state.json` now owns writable transcription/delivery counters, backoff, structured failures with observation times, recovery authorization and bounded history. Legacy files import read-only and remain frozen evidence. Their later mutation blocks work rather than resetting limits. An atomic state write publishes recovery intent and authorization together. State writers use an OS lock and compare the actual bytes loaded, preventing stale snapshots from replacing newer attempt limits. The coordinator reloads state after delivery before reconciling progress.

The stale-snapshot regression failed against the earlier implementation by replacing a three-attempt limit with zero. It now passes. Unknown legacy AI budgets cannot authorize another AI attempt; explicit transcript-only recovery retains the unknown flag and the Gateway's independent source checks. Changed speech after a delivery attempt requires review. Verified receipts still recover local exports despite an earlier paid-attempt cap. Stage flags remain insufficient evidence for delivery or audio removal.

Local verification: 327 native tests, 315 passed and 12 opt-in tests skipped, including the actual Swift-to-JavaScript delivery contract. The migration-focused suite passes 28 tests. A separate run against SDK 2026.9.8 passes all 11 state/HTTP contract tests, including the final dangling-link write guard. Both CI runs for the prior `43fb99d` commit passed. Current source still needs CI and approved live acceptance. No installed helper, Gateway, real recording, credentials or settings were changed. The architecture item remains open for final consistency audit and approved migration acceptance; incremental checkpoints and legacy-receipt reconciliation remain unfinished. Details are in [durable meeting state](pipeline-state.md).

### Local full-text search checkpoint

The library now searches titles, saved notes and transcripts with case/accent-insensitive words, matching excerpts and the existing attention filter and quick actions. A minimized body-only search failed against the title-only implementation and passes now. Reads run outside the UI thread, cancelled queries cannot publish stale results, and new meeting snapshots refresh results. A bounded memory-only cache reuses unchanged text; it creates no persistent speech index. Clearing the query drops cached text. Linked, changed-during-read, unreadable and oversized documents are excluded with a coverage notice.

Local verification: 336 native tests, 324 passed and 12 opt-in tests skipped. The focused search/library suite passes 10 tests; the expanded search/UI suite passes 12. Light/dark offscreen result renders were inspected after allowing the real debounced query to finish. Both CI runs for `04543fa` and the full-text search commit `511cc92` passed. Installed keyboard/accessibility checks and large-history latency acceptance remain open. No live helper, Gateway, credentials, capture or user recording was changed. See [meeting search](meeting-search.md).

The full goal remains open for the remaining architecture consistency audit, onboarding and safe capture-check acceptance, storage/notes-migration UI, legacy ledger/receipt reconciliation, incremental transcription, packaging/signing and approved live reliability checks. Teams remains the only enabled provider.

### Reviewed notes-copy checkpoint

Settings and saved meeting details now offer an explicit destination review for existing notes. No meeting is preselected. File counts, bytes and source/destination locations precede confirmation. Each copy checks its reviewed recording identity, receipt, source contents and destination identity again, verifies the staged files, preserves the originals and updates only the successful meeting's local export binding. The default for future meetings stays unchanged. OS locks block concurrent saves and installer ownership; changed files, conflicts, nested destinations, symbolic links and oversized folders fail closed. Each row reports its result and failed rows require another review.

Offscreen light/dark review renders were inspected without opening a window or copying user notes. The complete isolated native suite passes 345 tests with 12 opt-in tests skipped and no failures, including all nine new notes-copy tests and the actual Swift-to-JavaScript delivery contract. The copied folder and saved-location update are separate writes; a crash between them can leave an unbound copy that needs manual review. This remains an explicit limitation, not a claimed filesystem transaction. See [copy existing notes](notes-copy.md).

The full goal remains open. Historical-audio cleanup is addressed in the following checkpoint. Legacy ledger/receipt reconciliation, final state consistency audit, onboarding/capture-check acceptance, incremental transcription, packaging/signing and approved live reliability checks are also unfinished. No helper/Gateway activation, user-folder migration or new provider was performed.

### Reviewed historical-audio cleanup checkpoint

Privacy & storage and meeting details now offer read-only eligibility review with no default selections, track counts/sizes, blocked reasons and explicit permanent-deletion confirmation. The future-only preference stays unchanged. Selected meetings are verified again under save and lifecycle locks. Exact text hashes, directory identities and track identities/durations must still match the review; each unlink rechecks current evidence. The CLI also defaults to read-only and requires `--delete` for removal.

Schema-2 audits record verification before unlinking and progress afterwards. Prepared/partial receipts do not prove completion. A fresh review can resume interrupted removal, including an unlink whose progress write was lost, only when text proofs and surviving track identities/coverage still match. Missing tracks without this evidence, changed survivors and insufficient legacy partial audits keep remaining audio. The duration check reads headers, not every audio sample, and does not prove transcript accuracy. See [audio cleanup](audio-cleanup.md) for the precise recovery and filesystem limits.

The focused native suite passes 38 tests, including read-only real-PCM probing and injected interrupted-unlink cases. Offscreen light/dark eligible/blocked review renders were inspected. Both CI workflows for notes-copy commit `1e0ddf0` passed. The complete isolated native suite passes 358 tests with 12 opt-in tests skipped and no failures, including the actual Swift-to-JavaScript delivery contract. No helper/Gateway lifecycle change, user-audio deletion, permission change or new provider was performed.

The full goal remains open for legacy ledger/receipt reconciliation, final state consistency audit, onboarding/capture-check acceptance, incremental transcription, packaging/signing and approved live reliability checks. Source and offscreen verification do not replace installed acceptance.

### Legacy completed-receipt checkpoint

Meeting details now offer explicit verification for saved receipts without local transcript hashes. Preparation reads local evidence only. The admitted Gateway request compares a text-only envelope against a completed canonical record using the SDK's read-only store, without a notes attempt, model completion, canonical write or ledger mutation. Missing, partial and conflicting records cannot be saved through this action. The response binds its readback to the exact request bytes. The helper checks that proof and document shape, rechecks source files under save/lifecycle locks, preserves the original receipt, repairs the local export and reconciles progress. Existing edits and audio remain.

An actual Swift-to-JavaScript regression found that verification omitted the existing transcript-only recovery request. The pre-fix run failed against the real SDK's metadata comparison. The final path includes the existing request without arming another one, preserves its two paid attempts and adds no completion. A separate legacy AI revision also verifies and preserves an edited export. Unknown budgets, frozen legacy records and earlier conflicting local fingerprints retain their limits; unprovable failed-attempt Gateway fingerprints remain blocked. Receipt, export and state publication are separate writes. A partial local repair can recover its verified export offline. See [receipt reconciliation](receipt-reconciliation.md).

The full isolated native suite passes 369 tests, with 357 passed and 12 opt-in tests skipped. The focused native suite passed 26 tests before the final recovered-request regression; the final SDK 2026.9.8 receipt/HTTP suite passes 12 tests. All 48 JavaScript tests pass on each pinned SDK. Light/dark verification sheets were rendered offscreen and inspected. Both CI workflows for historical-audio commit `51e4125` passed; this checkpoint still needs its own CI. No real meeting, Gateway archive, credentials, settings or helper/Gateway lifecycle was changed.

The full goal remains open for final state consistency audit, conflicting legacy-ledger reconciliation, onboarding/capture-check acceptance, incremental transcription, packaging/signing and approved live reliability checks. Teams remains the only enabled provider. Source tests do not prove proxy query forwarding or installed canonical verification.

### Delivery evidence and state-consistency checkpoint

Four minimized native regressions failed before the fix. A saved transcript hash concealed changed title/participants/template; metadata changing during delivery still received a standard receipt; stale model and AI errors hid a saved capture-gap warning; and a successful callback without saved artifacts reported completion.

Completed receipts now bind the exact transcript bytes and complete normalized text package. One builder supplies normal delivery, legacy verification and current-source matching. Changes to a saved source require review and a separate revision. A response to a changed in-flight source is kept with its original request in private conflict evidence, without binding the changed source or exporting it. Existing declared hashes cannot be replaced through verification. Receipts lacking the new full-source proof require explicit canonical readback, even when their transcript hash matches. Missing proof or changed metadata cannot authorize audio removal.

Backlog inspection reports structured transcript/archive/export observations. State reconciliation and the UI use them to clear obsolete causes while preserving all attempt counts and unknown budget flags. Saved capture gaps remain Needs attention. Delivery requires the verified local export before reporting success or notifying the user. Participant changes invalidate the cached delivery check. Private capture paths and bookkeeping are excluded from the package fingerprint; JSON object ordering is normalized while array order remains meaningful. See [delivery evidence](delivery-evidence.md).

The complete isolated native suite passes 376 tests with 364 passed and 12 opt-in tests skipped. The earlier 44-test focused suite passed before the final callback and retention regressions. The final receipt/evidence/actual HTTP suite passes 18 tests on SDK 2026.9.8. The unchanged Gateway source has 48 passing tests per SDK and both successful CI workflows for `99aa36d`. This native checkpoint still needs its own CI and installed acceptance. No helper/Gateway lifecycle, actual recording, user receipt, audio, permissions or credentials were changed.

The next source checkpoint below addresses local-export retry accounting/backoff and the remaining CLI draft-mutation ownership paths. Installed acceptance is still open. Conflicting legacy-ledger resolution, onboarding, incremental transcription, packaging/signing and approved live reliability checks also remain open. The full objective is unchanged.


### Offline export and draft-source ownership checkpoint

The disk export of a completed receipt now has an independent schema-2 counter, backoff and cause. Automatic attempts stop at three across relaunches. Meeting details offer **Retry saving notes on this Mac**, which performs only verified filesystem work and preserves cumulative disk attempts, remote counters and unknown paid budgets. A Gateway retry deadline or earlier AI cap cannot delay this work. A first remote save that persists its receipt and then hits a disk failure records a local export cause without turning it into another AI failure. Unbound legacy destinations still require review.

Speech recognition, speaker refresh and manual labeling now acquire shared lifecycle ownership plus exclusive archive and processing locks. Active recordings, any receipt and previously attempted delivery are protected from in-place mutation. Separate previews retain source ownership while reading. Final source fingerprints detect changes before transcript publication. Delivery reservation also respects the archive lock, so it cannot consume an attempt while a draft writer holds the meeting. See [delivery evidence](delivery-evidence.md) for filesystem limits.

The minimized speaker-refresh and labeling fixtures rewrote delivered/attempted source before the fix. Regressions now cover that refusal, preserved source bytes, no engine preparation, concurrent saves/processing/installer ownership, active captures, linked receipts and late source changes. Offline export tests cover paid-budget preservation, remote backoff, disk failure after a real receipt, automatic caps across reloads, explicit local recovery, lock refusal and malformed state. Light and dark retry detail renders were inspected. These are isolated source checks; no installed helper, Gateway, real audio, permissions or settings were changed.

Verification: 391 native tests, 379 passed and 12 opt-in checks skipped. The final evidence/receipt/actual HTTP suite passes 24 tests on the real SDK 2026.9.8 fixture. The earlier focused ownership/export suite passes 53 tests. Both CI workflows for `53b47f4` passed. This new checkpoint still needs its own CI and installed acceptance.

The full objective remains open for conflicting legacy-ledger reconciliation, onboarding/capture-check acceptance, incremental transcription, streaming feasibility measurements, packaging/signing and approved live reliability checks. Teams is the only enabled provider. Source locks and fixture completions do not settle the live Gateway ownership/event-loop/memory investigation.
