# Verification and known limits

ClawMinutes is an experimental source release. These observations come from development checks on 1, 2, and 5 October 2026. Private recordings, meeting content, machine identifiers, credentials, and runtime receipts are not part of the public repository.

## Observed behavior

- Local Parakeet recognition produced timestamped transcripts on the recording Mac. A synthetic recognition run also completed with networking denied.
- Application-filtered, audio-only ScreenCaptureKit capture produced separate microphone and system CAF tracks. The capture path registers no screen output.
- The helper saved text transcripts through the authenticated Gateway and read back the Meetings archive.
- A real completed meeting produced Gateway AI notes with the configured model. Successful note generation does not prove general Gateway event-loop or memory health.
- Timestamped Teams observations supported participant names in real transcripts. Other segments remained Unknown speaker.
- Audio was automatically removed after a real finished meeting passed transcript, archive, export, and coverage checks. Text artifacts and deletion receipts remained.
- Generated notes folders were migrated to timestamp-and-title names. Notes and transcript hashes were unchanged, and current recording/export pointers were checked.
- Updates signed with the same local certificate retained the helper's designated signing requirement. This is local signing, not Developer ID notarization.

## Limits

- Native source builds currently require Xcode 27.2 beta with Swift 6.4. Stable Xcode 16.4 and 26.3 failed clean builds.
- The archive adapter supports only OpenClaw 2026.9.7 and uses an internal store interface. Other versions fail closed.
- Meeting titles, call clocks, and participant lists depend on available Teams UI evidence. Observations are partial. A stale title must not be treated as evidence of the current call.
- Unknown speaker labels remain when identity evidence is absent or ambiguous. Acoustic clusters and roster membership do not establish identity.
- Some development captures had incomplete microphone coverage. Version 0.2.6 adds continuous written-frame monitoring and up to three recovery attempts per audio source. Recovery creates separate files with wall-clock offsets and keeps earlier PCM. Deterministic tests cover stalled callbacks, frame shortfalls, write failures, offset-preserving transcription, and gap-based retention. Recovery during a real device change or long live call remains unverified.
- A prior Core Audio tap hung during callback registration. Production uses ScreenCaptureKit; the original tap is retained for provenance and is not a silent fallback.
- ElevenLabs support is implemented, but a real cloud transcription was not verified in the development acceptance run.
- A live desktop theme toggle was not observed. Light and dark icon renders were inspected separately.
- Capture fixtures, injected speaker names, and unit tests are not live-call acceptance evidence.

Run the tests documented in the README for the current checkout. Hardware, credential, and model tests need separate setup. Keep live-call verification separate from unit-test results.

## Connection diagnosis

HTTP 404 at the plugin endpoint establishes an unavailable route. It does not prove that the plugin is uninstalled. Check registration, enabled state, Gateway version, and proxy routing before changing the server. The helper preserves captured audio and transcripts on failure.

New helper capture-gap exports require the matching Gateway plugin contract. A Gateway that rejects the new field leaves the meeting pending locally. It does not silently discard gap evidence.

## Version 0.2.6 checks

- 77 focused native tests and 18 JavaScript tests passed locally. The native tests include recovered segment timing, bounded retry decisions, separate cluster identities, gap rendering, and retaining audio despite otherwise valid archive receipts.
- The release helper was built, signed, installed, and observed in its Settings window. The designated signing requirement and configuration remained unchanged.
- With Settings open, the old process used 88.6% of one CPU core over 30 seconds. The updated process used 6.4% over 60 seconds. This comparison includes a process restart; it does not isolate each UI change or establish long-term resource stability.
- Device-change recovery during a live call and Gateway event-loop or memory behavior still require separate runtime evidence.
