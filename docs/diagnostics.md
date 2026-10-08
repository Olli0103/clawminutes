# Diagnostics and meeting progress

In Settings, open Advanced and choose **Save diagnostic report**. The helper creates a new JSON file, then reveals it in Finder. It never replaces an existing file. The command-line equivalent is:

```sh
ocmh diagnose --output /path/to/new-report.json
```

Omit `--output` to print JSON. Use `--recordings /path/to/recordings` to inspect a different recording root. The command never starts capture, inference, sign-in or Gateway requests. It does not acquire lifecycle or recording locks. Ownership remains `needs_evidence` in the report. Permission values describe the process running the check, so an unpackaged development binary may have a different macOS permission identity from the installed helper.

The report includes the packaged helper version, macOS version, permission booleans, local-model availability, free disk bytes, up to 25 recent meeting states, bounded speech/delivery/local-export attempt counts, recorded paid-completion attempts, unknown paid-budget flags and allowlisted error codes for each stage. It includes up to 100 structured stage events. Meeting references are hashes, not titles or folder names.

Audio, transcripts, notes, participant names, meeting titles, paths, hostnames, Gateway URLs, credentials, free-form errors, raw configuration and raw logs are excluded. The report builder constructs a new object from allowed fields. It does not copy source files and attempt to redact them afterward. Unrecognized error codes become `unclassified_error`.

Schema 2 reports reconcile a copy of the saved state against current artifact observations. A verified transcript clears a stale speech error in the report; a verified archive clears a stale delivery error; verified exported files clear a stale disk-export error. Counts and unknown budgets remain. This changes no state or receipt bytes. `stateVerified` means that the local state parsed and passed validation, not that the diagnostic acquired ownership or an atomic snapshot. Concurrent work can change artifacts while the report is being built.

`events.jsonl` beside the helper settings records progress writes. It rotates at 1 MB and keeps one previous file. Recording references are hashed and fields are closed. Logging is best effort and cannot block pipeline progress. New events use schema 2 and include separate local-export counts/causes and paid-attempt observations. The reader also accepts schema 1, where missing counts remain unknown. It rejects invalid counts and non-allowlisted causes. These events describe saved local progress, not proof that a provider completed a request. Delivery and audio removal still require verified artifacts.

## Pipeline responsibilities

`TranscriptionCoordinator` schedules bounded work, reconciles artifact evidence and publishes immutable meeting values for the UI. `RecordingTranscriber` owns recognition engines, usable-track recovery and speaker alignment. It cannot call the Gateway or delete audio. `MeetingDeliveryStage` owns text delivery, retry reservation and receipt/export verification. `MeetingRetention` invokes the separate artifact-verifying retention implementation. Each stage retains the lifecycle lease required for its work.

Schema 2 of `state.json` owns transcription and delivery counters, backoff, structured causes and their observation times, notes recovery authorization and bounded history. Read-only inspection imports older records in memory. The next authorized pipeline write publishes the migration without changing legacy evidence. A locked compare-and-swap rejects stale writers. Invalid or conflicting state is preserved. Delivery and retention still verify actual artifacts and receipts; a stage flag never proves success or authorizes audio removal. See [pipeline state](pipeline-state.md). Closed-chunk reservations and checkpoint hashes are also owned by this record. Explicit legacy completed-receipt verification is available, while conflicting or unprovable legacy failed-attempt histories remain blocked. See [receipt reconciliation](receipt-reconciliation.md).

## Speaker uncertainty

`meeting_voice` maps a voice cluster to a participant using speaking-tile evidence. It remains an inference because one cluster may contain more than one real voice. Native and Gateway readable transcripts mark these names as `voice match, uncertain`. The notes prompt preserves that uncertainty and forbids using the inferred name alone as evidence of ownership, approval, commitment or attendance.

Existing saved archives are not rewritten to add that marker. A changed rendering of an existing record can require a new revision. The separate revision workflow preserves original documents. Installed speaker-correction and playback acceptance remain unverified. See [revisions](revisions.md).
