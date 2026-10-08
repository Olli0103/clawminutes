# Opus review implementation

The goal covers the complete review and UX proposals. Teams remains the only enabled meeting provider. New meeting providers are excluded from this implementation. Checked items require code and verification evidence; a proposed design alone is not completion.

## Defects and recovery

- [ ] R1 Recover orphaned captures at launch under exclusive ownership, preserve interruption evidence, and restart after crashes without interrupting live capture.
- [ ] R2 Structured delivery/model errors, durable capped AI attempts, bounded retries, per-meeting causes and explicit recovery actions.
- [x] R3 Future-only retention opt-in, explicit historical cleanup, and conservative missing/silent remote capture checks.
- [ ] R4 Consent survives relaunch only for the evidenced ongoing call, with process incarnation and call identity.
- [ ] R5 Partial-track recovery with gaps, durable transcription retries and retry after model setup; never present partial speech as complete.
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
- [ ] Separate transcription, delivery and retention implementations behind a small pipeline interface.
- [ ] Explicit capability negotiation and an archive adapter contract, without admitting unverified host semantics merely because method names match.
- [ ] Isolate Teams detection from dormant provider code; do not enable additional providers.
- [ ] Structured event log and a redacted diagnostics command/bundle.
- [ ] Public distribution signing/notarization workflow and permission continuity verification. External signing credentials remain an explicit delivery gate.
- [ ] Preserve uncertainty for voice-cluster-derived names in transcripts and AI prompts.
- [ ] Storage usage/free-space checks, legacy receipt reconciliation and accurate reuse documentation.
- [x] Full native suite configured in CI, with Swift-to-JavaScript HTTP tests against the real handler and SDK. A live CI run is still required for each pushed commit.

## User experience

- [ ] Status-first pop-up: current meeting, primary recording action, health and processing stages, recent meetings, Open notes, Settings, Pause prompts, Quit.
- [ ] Per-meeting attention and success states with one actionable cause; errors do not disappear when a different meeting starts.
- [ ] Settings grouped into General, Recording, Notes, Connection, Privacy and storage, Permissions, Advanced.
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
- Native delivery attempts retain paid-attempt counts and the last cause across relaunches. Authentication failures pause automatically and can be rearmed by the explicit reconnect/retry path. Permanent model errors cannot be bypassed by that path. Per-meeting recovery UI is still open.
- Launch recovery requires the process lock, respects the lifecycle lease and finishes before new capture is enabled. It inspects actual audio beyond stale frame checkpoints, records interruption evidence and does not invent an offline call duration. Installer tests accept orphan metadata only for known protected installs under the exclusive lifecycle lease; legacy and active-work gates remain. The generated launch agent supervises the helper binary after abnormal exit. Real crash/restart timing remains needs_evidence.
- A missing, unreadable or empty audio track becomes an explicit missing-speech gap while usable tracks are transcribed. Valid-track provider/inference failures still fail the job. Durable transcription retry and requeue after model setup remain open.
- Automatic deletion requires a timestamped future-only opt-in. An untimed legacy setting cannot delete automatically. A recording with no transcribed Teams speech retains audio even when durations and receipts match. Historical verification/deletion remains a separate explicit command.
- Exports bind to their original root. Changing the default cannot migrate them. The explicit migration command copies user-edited files, keeps originals and rejects conflicts.
- Missing AX windows stay unknown unless destroyed-element evidence and the independent all-Spaces WindowServer inventory corroborate closure. A replacement call window keeps the call present. Live Spaces and fullscreen acceptance remains needs_evidence.
- Unchanged delivery inputs reuse verified backlog entries. File identity, size, nanosecond mtime and ctime invalidate changes, including edits with restored size/mtime. Deletion still re-verifies all artifacts.
- Consent persists process launch time, a title hash and observed WindowServer IDs. Isolated regressions cover restored same-call consent, new call windows and PID reuse. Unidentified calls cannot persist PID-only suppression. Reusing the same title and window while the helper is off remains ambiguous; no stable Teams call ID is exposed by the current evidence.
- Recording and detection timers run in common and modal-panel modes. Consent uses a non-activating asynchronous panel. Offscreen light/dark panel renders were inspected. Focus behavior remains a live acceptance item.
- Both malformed-settings overwrite regressions pass. Other existing settings writers retain their parse guards. The User-Agent reads the bundled version. Reuse documentation now describes the implemented segment recovery.

Current local evidence: the full native suite ran 278 tests, with 266 passing and 12 opt-in fixture/live tests skipped. All 31 JavaScript tests pass against each supported real SDK release, including the canonical-write-failure cache regression. The installer suite passes 10 isolated tests. The native HTTP test sends the actual Swift envelope through the real JavaScript handler and real SDK store, confirms one synthetic completion across a repeated save and a conflicting longer transcript, and verifies rejection of raw audio. No real provider, live call or Gateway restart was used.
