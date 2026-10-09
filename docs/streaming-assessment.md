# Local streaming assessment

This is a source assessment of FluidAudio 0.15.5 at revision `19600a485baa4998812e4654b70d2bab8f2c9949`, verified against the checkout and `native/Package.resolved`. No streaming engine, capture device or new meeting provider was activated. Latency, memory and battery results remain `needs_evidence`.

## What the pinned code provides

- [Offline TDT recognition](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/ChunkProcessor.swift) uses overlapping model windows inside a single audio source. Our separate CAF calls start fresh decoding states. The final boundary-context pass addresses that separate file seam using the offline manager's owned sample-array API, without writing excerpts to disk.
- [SlidingWindowAsrManager](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift) accepts PCM, resamples to 16 kHz mono and exposes volatile/confirmed text with token timings. Its default layout is 2 seconds left context, 11 seconds center and 2 seconds right context. These are configuration values, not measured end-to-end latency. It trims consumed sample storage, but its input AsyncStream has no explicit buffering bound. Feeding buffers faster than inference consumes them can accumulate queued audio. This is an inferred integration risk, not a measured leak.
- That manager accepts explicitly preloaded `AsrModels`. Its convenience loader and [SlidingWindowAsrSession](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/SlidingWindowAsrSession.swift) can download models. A local-only adapter must load the verified installed cache with offline mode enabled and must never call those download paths during capture.
- [StreamingAsrManager](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ASR/Parakeet/Streaming/StreamingAsrManager.swift) is a separate protocol for streaming model variants. TDT sliding windows intentionally do not conform. True streaming variants have different model assets and configuration. Their advertised chunk size does not prove latency, language quality, timestamp quality or resource use on this Mac.

## Integration decision

Keep durable file capture and the bounded closed-file queue as the recovery authority. Streaming can later provide a local provisional view, with explicit replacement of volatile text. It must not publish a final transcript, authorize deletion, start paid notes attempts or reset existing budgets. Final reconciliation still applies completed participant evidence and produces the text-only Gateway input.

Do not feed the present synchronous capture buffers directly to an asynchronous recognizer. Teams PCM uses a no-copy view whose backing memory is retained only through the callback. A streaming adapter needs owned PCM copies, a bounded queue, consumption acknowledgement and a policy that drops provisional work while preserving every durable audio frame. The upstream unbounded input queue also needs a bound or a verified admission contract. A bounded queue outside an unacknowledged unbounded queue is insufficient.

Keep microphone and Teams decoder state separate. Share installed model assets only where the engine supports it; measure actual memory rather than assuming two managers share all allocations. Device recovery, sample-rate changes, overload and final-job priority must preserve source clocks and mark lost provisional context. A stream error cannot stop recording or fall back to cloud.

## Required evidence before activation

Use approved recorded fixtures first, covering German and English, sentence/word boundaries, silence, repeated phrases, overlapping speakers and route changes. Compare the final transcript with the same audio under the existing offline path. Check token timing, retractions, clock resets, partial output and crash recovery, not just final text.

For an approved live interval, include at least 45 minutes of two-track recording and deliberate slow-consumer/outage cases. Record first-partial and confirmed-text latency, real-time recognition factor, queue depth/age/drops, capture continuity, process memory over time, CPU and energy use, and finalization time. Report the machine, model, installed version and observation interval. A successful launch or restart is insufficient evidence.

The separate Gateway ownership investigation still requires actual notes completions, event-loop-delay distributions and memory over a meaningful interval. Local streaming does not settle that investigation. Activation, installation, reloads and restarts remain approval-gated.
