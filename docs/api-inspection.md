# Installed API findings

OpenClaw 2026.9.7 build c074824 was inspected from an existing installed runtime. The selected public Gateway subsequently reported version 2026.9.7 through an authenticated WebSocket hello. The recording Mac has no OpenClaw CLI requirement. A copied development runtime supports isolated contract and archive checks; it is not the helper's runtime.

The public SDK exposes `registerCli`, `registerService`, `registerNodeHostCommand`, and `registerHttpRoute`. This feature plugin registers only Gateway HTTP routes, a status action, and helper export commands. It registers no node commands, capture services, or remote Start. The helper sends native HTTPS requests through URLSession and uses a bundled Cloudflare Access client for GitHub browser sign-in. It needs neither Node.js nor a local OpenClaw package.

The public SDK has no helper install or uninstall lifecycle hook for an arbitrary remote recording Mac. The plugin therefore owns a bundled `ocmh.app`, downloadable helper archive, and `helper.py` installer with install, run, update, and remove actions. Explicit helper removal preserves recordings and configuration. Gateway plugin removal cannot automatically uninstall software on an offline remote Mac.

The installed Teams Meetings transport joins through Chrome or a Chrome node and reads meeting captions. It cannot supply bot-free local Teams process capture. This plugin reuses Quill's microphone recording and Accessibility observations, with application-filtered ScreenCaptureKit output for the separate Teams audio track.

Meetings uses the shared state database. The `transcripts/` directory contains exports rather than the canonical archive. The inspected SDK has no public completed-record import method. The Gateway adapter checks the exact supported runtime version and finds its installed `src/transcripts/store.ts` module. It calls `TranscriptsStore.writeSession`, `appendUtteranceForSession`, and `writeSummary`, which use OpenClaw's own lease and schema code, then reads the saved utterances and notes back. It never guesses database tables.

This internal archive adapter is a compatibility limit. Unsupported versions fail closed and retain the local recording. Local recognition executes on the recording Mac. ElevenLabs recognition uploads directly from that Mac to ElevenLabs; no Gateway-side recognition is assumed. Meeting notes carry their own provenance. AI mode uses a zero-tool simple completion with the Gateway credential owner and selected model; simple highlights and transcript-only mode use no model.

A documentation contradiction was observed: the handshake example uses client mode `operator`, but the installed schema and live Gateway reject that value. The installed valid mode for the inspected development client is `cli`. The helper's production archive connection uses authenticated HTTP rather than that WebSocket client.

## OpenClaw 2026.9.8

The authenticated Control UI separately reported the connected Gateway and UI versions as 2026.9.8 on 5 October. The npm SDK archive passed its published SHA-512 integrity check. The internal transcript store retains writeSession, appendUtteranceForSession, writeSummary, and the corresponding read methods. Its isolated save/readback test preserves timestamps, names, gaps, and idempotency. Both verified SDK versions are accepted; other releases remain rejected. The simple-completion export remains present, but actual model preparation and completion on this Gateway still require runtime verification.
