# Incremental recognition checkpoints

This source checkpoint adds durable local recognition for acknowledged closed capture files and reuses it during final transcription. The source recorder now rotates healthy local capture files after five minutes without stopping either capture device. This is not a complete near-real-time transcription feature, and it has not been installed or tested against live audio.

## Closed-file contract

`capture_segments[].ended_at` records a requested boundary. It does not prove that a writer closed the file. The recorder sets `closed: true` only after closing that file. Device recovery stops its source recorder; healthy rotation swaps PCM writers under a short lock while the same engine and tap continue. It publishes that acknowledgement before submitting a background request. The other audio source keeps running. Stop acknowledges the remaining files after closing capture.

Background admission requires the session's captured backend to be Parakeet, a declared closed file with successful frames, unchanged recording identity/revision, no delivery attempt or saved receipt, and a regular local audio file. Files are limited to ten minutes and 512 MB. Longer recovery segments stay available for final recognition. No model is downloaded automatically, and no cloud backend is admitted.

A shared lifecycle lease protects inference from helper replacement. An exclusive archive lock serializes it with draft writers, delivery and cleanup. Current metadata can continue accumulating observations while immutable closed audio is processed. Audio inode, timestamps, size and a streamed SHA-256 are checked; source changes or cancellation prevent publication. Folder renaming acquires the same archive lock. If Stop cannot acquire it during speculative inference, the final queue retries the title rename after that engine call finishes. The checkpoint and stable recording identity move with the folder. The naming CLI also holds a lifecycle lease.

## Healthy writer rotation

Only local Parakeet capture with transcription enabled rotates automatically. Every successful buffer belongs to one file. Preparation creates the next empty private CAF without holding the audio-write lock and refuses existing or linked paths. A token binds that file to its writer, generation and inode. The recorder persists a provisional segment and `rotation_pending` gap before committing the handoff. Commit finalizes the old CAF, swaps writers, preserves the device epoch and concurrent failure flags, then returns the exact old frame count. The final manifest records that boundary before submitting speculative recognition.

If the helper stops between declaration and final publication, the pending marker survives. Recovery keeps audio, marks timing uncertain and refuses remote speaker-name alignment for that provisional segment. Failed preparation or manifest writes leave current capture running and back off for 30 seconds. A failed handoff can leave an empty declared CAF for review. Atomic manifest replacement is not a power-loss durability guarantee.

Continuous file clocks advance by successful frame duration rather than callback scheduling jitter. A discrepancy of at least two seconds between that clock and the last write becomes an explicit coverage gap and suppresses time-based speaker naming for that file; the next file reanchors to its first observed buffer. Filenames use one monotonically increasing counter across rotation and recovery. The manifest admits 1,024 files, with the last 16 slots reserved for device recovery. Once healthy rotation reaches its limit, the current file keeps recording. Speculative recognition retains its separate 256-file attempt limit; remaining files still enter final recognition.

Retention verifies coverage to the next file from the same source instead of expecting every file to extend to call end. Missing sources, duplicate offsets, pending handoffs and short or overlapping interior coverage keep audio. Final-tail tolerances retain their previous behavior. Recognition alone never authorizes deletion.

## Durable checkpoint and final reconciliation

Optional `state.json.recognitionChunks` records one speculative attempt per filename and an optional completed checkpoint SHA-256. It uses the existing state lock and compare-and-swap. The reservation precedes engine preparation. Failed or interrupted speculative attempts do not repeat automatically and do not spend the meeting's final transcription or delivery budgets.

`.speech-<capture filename>.json` contains timed speech and word spans, recording identity/revision, source filename/offset/duration, audio SHA-256, and actual engine/model. It has private file permissions and an 8 MB limit. It contains no inferred participant names. A successful file write followed by a failed state commit leaves an untrusted orphan. Existing orphans and linked files are preserved rather than adopted or overwritten.

The final job visits every declared capture file. It reuses checkpoint spans only when their exact bytes match the authoritative state reference and their identity, revision, filename, offset, duration, engine, model, audio hash and timing bounds match the current source. Missing, malformed, changed or incompatible checkpoints fall back to normal recognition. Independent final source-identity checks reject audio changed during the pass.

Final speaker alignment uses the completed session's observations, roster and configured personal microphone name. Missing tracks and capture gaps remain explicit. Final publication, Gateway text delivery, notes generation and audio verification retain their existing separate checks. A checkpoint alone cannot create `transcript.json`, deliver a meeting, generate notes or authorize audio removal. No checkpoint text or audio is sent to the Gateway.

## Scheduling and backpressure

The existing coordinator owns one recognition engine and schedules both finished meetings and speculative requests. Finished meetings take priority at inference boundaries. An already running inference completes before switching jobs. Requests are deduplicated and limited to 16 waiting items. Overflow skips speculative work only. Audio files and final jobs are never dropped. Finishing a meeting removes its waiting speculative requests, including requests for the same recording identity before a folder rename.

Background recognition has a separate visible status. Active recording remains the primary activity. A speculative failure does not create a final transcription failure or trigger Gateway retries. Model weights are released when both queues drain.

## Evidence and remaining work

Synthetic PCM tests compare every sample across concurrent writer handoffs, exercise disk failure before switching, token ownership, file replacement, stale callbacks, crash markers, long manifests and split-file retention. The test reader loops through EOF because AVAudioFile can return fewer frames than requested. Other synthetic tests exercise close acknowledgement, final reuse after recreating the worker, preserved words and offsets, evidence-based final microphone naming, unknown remote names, cloud/receipt rejection, durable failed-attempt limits, altered audio, corrupted caches, different models, cancellation, linked sources, orphans, malformed timings, bounded work, duplicate requests, final-job priority and queue overflow. An isolated full native suite covers the existing recovery, delivery and retention paths. These tests execute no real capture or provider completion.

Still open:

- Reconcile speech crossing file boundaries with shared context before treating this as complete incremental transcription. Independent per-file inference can clip a word at a seam.
- Measure capture continuity, recognition latency, memory, event-loop delay and battery use on the installed helper over a meaningful live interval.
- Verify actual Parakeet output at segment boundaries and speaker alignment across segments. Synthetic engine results establish control flow only.
- Evaluate FluidAudio's pinned streaming support separately. No streaming or provisional Gateway notes are enabled.

No helper/Gateway installation, activation, restart, reload or real recording was performed for this checkpoint.
