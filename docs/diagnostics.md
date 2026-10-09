# Diagnostics and meeting progress

In Settings, open Advanced and choose **Save diagnostic report**. The helper creates a new JSON file, then reveals it in Finder. It never replaces an existing file. The command-line equivalent is:

```sh
ocmh diagnose --output /path/to/new-report.json
```

Omit `--output` to print JSON. Use `--recordings /path/to/recordings` to inspect a different recording root. The command never starts capture, inference, sign-in or Gateway requests. It does not acquire lifecycle or recording locks. Schema 3 adds sampled lock states through an isolated read-only worker. Owner identity remains `needs_evidence` for the helper's `flock` locks. Permission values describe the process running the check, so an unpackaged development binary may have a different macOS permission identity from the installed helper.

The report includes the packaged helper version, macOS version, permission booleans, local-model availability, free disk bytes, up to 25 recent meeting states, bounded speech/delivery/local-export attempt counts, recorded paid-completion attempts, unknown paid-budget flags and allowlisted error codes for each stage. It includes up to 100 structured stage events. Meeting references are hashes, not titles or folder names.

Audio, transcripts, notes, participant names, meeting titles, paths, hostnames, Gateway URLs, credentials, free-form errors, raw configuration and raw logs are excluded. The report builder constructs a new object from allowed fields. It does not copy source files and attempt to redact them afterward. Unrecognized error codes become `unclassified_error`.

Schema 2 reports reconcile a copy of the saved state against current artifact observations. A verified transcript clears a stale speech error in the report; a verified archive clears a stale delivery error; verified exported files clear a stale disk-export error. Counts and unknown budgets remain. This changes no state or receipt bytes. `stateVerified` means that the local state parsed and passed validation, not that the diagnostic acquired ownership or an atomic snapshot. Concurrent work can change artifacts while the report is being built.

`events.jsonl` beside the helper settings records progress writes. It rotates at 1 MB and keeps one previous file. Recording references are hashed and fields are closed. Logging is best effort and cannot block pipeline progress. New events use schema 2 and include separate local-export counts/causes and paid-attempt observations. The reader also accepts schema 1, where missing counts remain unknown. It rejects invalid counts and non-allowlisted causes. These events describe saved local progress, not proof that a provider completed a request. Delivery and audio removal still require verified artifacts.

## Lock observations

The CLI and Settings report query the instance, lifecycle and capture lock files plus archive locks for the same bounded set of recent meetings. A report contains at most 28 samples. Each sample has a role, observation time, state and an optional kernel-reported PID. Archive samples also carry the existing hashed recording reference and the meeting's index in this report. Two copied folders can have the same recording identity; their indices keep the samples separate without exposing folder names.

The worker uses `F_GETLK` to ask which lock would block a whole-file write lock. It never requests, changes or releases a lock. `shared` and `exclusive` describe the first blocking lock returned by the kernel. `noBlockingLock` is a point observation, not proof that the helper is idle. `absent`, `unsafe`, `changed` and `unavailable` retain the difference between a missing file, an unverified path/type, replacement during inspection and a failed query. Symlinks in the path, non-regular files and hard-linked leaves are not followed or inspected. A lexical system alias such as `/var` can therefore remain unverified; the physical path can be used for an isolated diagnostic fixture.

The macOS `fcntl(2)` manual and the SDK's `sys/fcntl.h` document owner PID `-1` for `flock` and other file-description locks. Local synthetic shared/exclusive locks reproduced that result. The report leaves `ownerPID` absent in that case. A positive PID is included only when the kernel reports a process-owned POSIX record lock. It is a sample, not verification of the process incarnation, all owners, current liveness or Gateway request ownership. PID-file contents, filenames and open descriptors cannot fill the missing evidence.

The query runs in a separate helper process. This matters even for read-only access: closing any descriptor for a file in the calling process can release that process's POSIX record locks. The child inherits no parent descriptors and runs with a restricted environment, a private temporary HOME/cwd, bounded input/output and a two-second watchdog. The timeout terminates and reaps its process group. Kernel-stalled filesystem I/O can still delay termination; this is not a hard real-time guarantee. Unavailable or incompatible workers produce unavailable samples instead of guessed states. Replies must match the requested roles, references and indices and cannot add paths or free-form fields.

Request paths stay in private temporary files and never enter the report. Ordinary success/failure removes the worker files. A hard process crash can leave the private temporary directory for OS or manual cleanup. The worker performs no permission requests, capture, inference, sign-in or Gateway calls. Samples cannot authorize recording, replacement, retry or audio deletion. Files and lock state can change after any sample; there is no atomic snapshot across the report.

Nine isolated lock regressions exercise the real helper worker and report: held shared/exclusive locks without invented owners, preservation of a parent's POSIX lock, absent/unlocked files without creation or content changes, linked/special/hard-linked paths, copied meeting identities, strict input/output, restricted environment, timeout and output-budget enforcement. They establish source behavior on synthetic files, not installed helper or Gateway ownership. Pure report-builder tests remain available without launching the worker.

## Pipeline responsibilities

`TranscriptionCoordinator` schedules bounded work, reconciles artifact evidence and publishes immutable meeting values for the UI. `RecordingTranscriber` owns recognition engines, usable-track recovery and speaker alignment. It cannot call the Gateway or delete audio. `MeetingDeliveryStage` owns text delivery, retry reservation and receipt/export verification. `MeetingRetention` invokes the separate artifact-verifying retention implementation. Each stage retains the lifecycle lease required for its work.

Schema 2 of `state.json` owns transcription and delivery counters, backoff, structured causes and their observation times, notes recovery authorization and bounded history. Read-only inspection imports older records in memory. The next authorized pipeline write publishes the migration without changing legacy evidence. A locked compare-and-swap rejects stale writers. Invalid or conflicting state is preserved. Delivery and retention still verify actual artifacts and receipts; a stage flag never proves success or authorizes audio removal. See [pipeline state](pipeline-state.md). Closed-chunk reservations and checkpoint hashes are also owned by this record. Explicit legacy completed-receipt verification is available, while conflicting or unprovable legacy failed-attempt histories remain blocked. See [receipt reconciliation](receipt-reconciliation.md).

## Speaker uncertainty

`meeting_voice` maps a voice cluster to a participant using speaking-tile evidence. It remains an inference because one cluster may contain more than one real voice. Native and Gateway readable transcripts mark these names as `voice match, uncertain`. The notes prompt preserves that uncertainty and forbids using the inferred name alone as evidence of ownership, approval, commitment or attendance.

Existing saved archives are not rewritten to add that marker. A changed rendering of an existing record can require a new revision. The separate revision workflow preserves original documents. Installed speaker-correction and playback acceptance remain unverified. See [revisions](revisions.md).
