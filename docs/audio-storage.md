# Compact local audio storage

New microphone and Teams capture files use signed 16-bit PCM in CAF containers. The audio callback still supplies its original processing format. AVAudioFile converts samples while writing, preserving the source sample rate, channel count and frame order. The prepared-file handoff uses the same encoding. System audio can open its writer lazily from the first actual buffer, including interleaved stereo.

This halves PCM payload compared with the previous 32-bit float files. At 48 kHz, a mono microphone plus stereo Teams track needs 1,036,800,000 PCM bytes per hour, about 1.04 GB, before container headers. Other sample rates scale that estimate. Two one-second synthetic files measured 100,096 bytes for mono and 196,096 bytes for stereo, including 4,096-byte CAF headers. The previous writer produced 196,096 and 388,096 bytes respectively. These are fixture sizes, not a measured live meeting.

## Precision and recovery

This is quantization, not lossless compression. Decoded normalized samples differ by at most one 16-bit step in the synthetic checks. Values beyond full scale clip to the signed integer range. This change does not establish speech-recognition accuracy, speaker separation or audio quality. No gain, sample-rate reduction, channel mixing or AAC codec was added.

Microphone and Teams files remain separate. Successful disk-write frame counts drive the same clocks, gap evidence and closed-file checkpoints. Concurrent handoff tests retain exact frame order using distinct normalized values representable in both formats. Boundary decoding reads owned floats from the integer files and accepts mixed historical float/new integer sources. Duration and recovery readers use actual frames and source rate. A format change alone does not authorize audio deletion.

Historical recordings, cached transcript inputs and audio receipts are not rewritten. Existing deletion policies and explicit historical cleanup remain separate. Reads do not convert source files in place. A live file can still be lost or damaged by a disk or hardware failure; the synthetic checks do not establish power-loss durability.

## Verification and acceptance

Tests exercise mono and stereo, planar and interleaved inputs, eager and lazy opening, both sides of an actual prepared-file handoff, file header/payload size, every decoded sample, saturation, exact frame counts, source-rate clocks and concurrent no-loss/no-duplication writes. Separate checks use the real boundary converter and duration reader with mixed historical Float32/new PCM16 files and verify unchanged source bytes. Existing rotation, partial-track recovery, recognition checkpoints and retention checks remain in the full native suite.

No real capture device or model/provider was invoked for this change. Installed capture continuity, actual decoder quality, CPU, energy, conversion latency and long-meeting memory remain `needs_evidence`. Installation/activation and any helper/Gateway lifecycle action require approval. These source changes leave the installed helper and all existing audio untouched.
