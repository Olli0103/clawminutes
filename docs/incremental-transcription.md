# Incremental recognition checkpoints

This source checkpoint adds durable local recognition for acknowledged closed capture files and reuses it during final transcription. The live recorder currently closes files only for device recovery. Five-minute capture rotation is still unfinished. This is not a complete near-real-time transcription feature, and it has not been installed or tested against live audio.

## Closed-file contract

`capture_segments[].ended_at` records a requested recovery boundary. It does not prove that a writer closed the file. The recorder now sets `closed: true` only after stopping that source and flushing its writer. It publishes that acknowledgement before submitting a background request. The other audio source keeps running. Stop acknowledges the remaining files after closing capture.

Background admission requires the session's captured backend to be Parakeet, a declared closed file with successful frames, unchanged recording identity/revision, no delivery attempt or saved receipt, and a regular local audio file. Files are limited to ten minutes and 512 MB. Longer recovery segments stay available for final recognition. No model is downloaded automatically, and no cloud backend is admitted.

A shared lifecycle lease protects inference from helper replacement. An exclusive archive lock serializes it with draft writers, delivery and cleanup. Current metadata can continue accumulating observations while immutable closed audio is processed. Audio inode, timestamps, size and a streamed SHA-256 are checked; source changes or cancellation prevent publication. A folder rename during inference may discard that speculative result. The final job still owns the audio and processes it at its new location.

## Durable checkpoint and final reconciliation

Optional `state.json.recognitionChunks` records one speculative attempt per filename and an optional completed checkpoint SHA-256. It uses the existing state lock and compare-and-swap. The reservation precedes engine preparation. Failed or interrupted speculative attempts do not repeat automatically and do not spend the meeting's final transcription or delivery budgets.

`.speech-<capture filename>.json` contains timed speech and word spans, recording identity/revision, source filename/offset/duration, audio SHA-256, and actual engine/model. It has private file permissions and an 8 MB limit. It contains no inferred participant names. A successful file write followed by a failed state commit leaves an untrusted orphan. Existing orphans and linked files are preserved rather than adopted or overwritten.

The final job visits every declared capture file. It reuses checkpoint spans only when their exact bytes match the authoritative state reference and their identity, revision, filename, offset, duration, engine, model, audio hash and timing bounds match the current source. Missing, malformed, changed or incompatible checkpoints fall back to normal recognition. Independent final source-identity checks reject audio changed during the pass.

Final speaker alignment uses the completed session's observations, roster and configured personal microphone name. Missing tracks and capture gaps remain explicit. Final publication, Gateway text delivery, notes generation and audio verification retain their existing separate checks. A checkpoint alone cannot create `transcript.json`, deliver a meeting, generate notes or authorize audio removal. No checkpoint text or audio is sent to the Gateway.

## Scheduling and backpressure

The existing coordinator owns one recognition engine and schedules both finished meetings and speculative requests. Finished meetings take priority at inference boundaries. An already running inference completes before switching jobs. Requests are deduplicated and limited to 16 waiting items. Overflow skips speculative work only. Audio files and final jobs are never dropped. Finishing a meeting removes its waiting speculative requests, including requests for the same recording identity before a folder rename.

Background recognition has a separate visible status. Active recording remains the primary activity. A speculative failure does not create a final transcription failure or trigger Gateway retries. Model weights are released when both queues drain.

## Evidence and remaining work

Synthetic tests exercise close acknowledgement, final reuse after recreating the worker, preserved words and offsets, evidence-based final microphone naming, unknown remote names, cloud/receipt rejection, durable failed-attempt limits, altered audio, corrupted caches, different models, cancellation, linked sources, orphans, malformed timings, bounded work, duplicate requests, final-job priority and queue overflow. An isolated full native suite covers the existing recovery, delivery and retention paths. These tests execute no real capture or provider completion.

Still open:

- Rotate healthy capture writers at buffer boundaries every five minutes without stopping audio devices. Extend manifest and retention coverage checks for long calls before enabling it.
- Measure capture continuity, recognition latency, memory, event-loop delay and battery use on the installed helper over a meaningful live interval.
- Verify actual Parakeet output at segment boundaries and speaker alignment across segments. Synthetic engine results establish control flow only.
- Evaluate FluidAudio's pinned streaming support separately. No streaming or provisional Gateway notes are enabled.

No helper/Gateway installation, activation, restart, reload or real recording was performed for this checkpoint.
