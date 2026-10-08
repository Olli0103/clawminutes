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
- The archive adapter supports OpenClaw 2026.9.7 and 2026.9.8 and uses an internal store interface. Other versions fail closed.
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

## Version 0.2.7 checks

- Fractional-second ISO end timestamps previously caused the audio-retention check to reject a finished recording as incomplete. A failing regression test reproduced that error. Both whole-second and fractional-second clocks now reach the same transcript, archive, export, and coverage checks.
- 88 native tests passed, one live Teams diagnostic test was skipped, and 18 JavaScript tests passed locally.
- The installed, signed helper transcribed a synthetic three-voice recording with networking denied. The recording had two remote audio segments separated by an explicit five-second gap. All 15 utterances and both capture-gap records survived isolated OpenClaw SDK storage, repeated saving, and Markdown export.
- The retention check kept all three fixture audio files because gaps require review. Their SHA-256 hashes remained unchanged. This fixture contacted no Gateway and used injected speaker observations, so it does not establish live Teams attribution or Gateway model completion.
- The packaged plugin and helper report the same version. The extracted helper passed signature verification. Recordings, diagnostic evidence, credentials, and signing material were excluded from the package.

## Version 0.2.8 compatibility checks

The connected Gateway reported OpenClaw 2026.9.8 on 5 October. Its installed-plugin search returned no match for teams-transcribe. That is current discovery evidence; it does not identify whether an old extension directory still exists on disk.

The 2026.9.8 SDK archive was downloaded from npm and checked against its published SHA-512 integrity. An isolated real-store test first reproduced the adapter's version rejection, then passed after adding this verified version. The test covers repeated saving, timestamp and supported-name readback, preserved capture gaps, and rejecting changed speech under an existing archive identity. CI tests both supported SDK releases with their own dependencies.

This compatibility test does not establish current Gateway installation, model completion, or runtime health. No Gateway setting, installation, or restart was performed.

The live read-only plugin inventory subsequently explained the missing entry: the installed package declared the exact plugin API 2026.9.7, so the 2026.9.8 host skipped discovery. Archive tests alone did not catch this separate metadata gate. The unreleased 0.2.8 package now declares the bounded API range `>=2026.9.7 <=2026.9.8`. A real SDK discovery test reproduces the old rejection, admits both verified host versions after the fix, and rejects 2026.9.9. It scans only an isolated copy of the plugin, without loading a Gateway or touching a live plugin registry.


## Version 0.2.9

The lifecycle installer previously guarded updates by scanning only the default recording folder and did not guard removal. It also could not determine whether transcription or archiving was active. An isolated installer regression reproduced unsafe removal during recording, a shared work lock, a concurrent installer, and unreadable metadata.

Native recording preparation, transcription and archive work now hold shared OS leases. Install/update/remove require an exclusive lease before stopping or replacing the helper. Native work cannot start during replacement, and process exit releases ownership even though the lock file remains. Checks include the configured recording folder and fail closed on unreadable metadata. Running pre-0.2.9 helpers require an idle quit before their first protected update. Updates preserve existing preferences instead of resetting voice memory.

Cross-process Swift/Python tests exercise contention, crash release, actual coordinator inference, failure cleanup, and blocking a recording before it creates metadata or starts audio. Installer tests cover busy recording/processing, concurrent installers, legacy helper refusal, preserved preferences, and idle removal with recordings/configuration intact. These tests use isolated homes and fixture engines, without recording audio, contacting a Gateway, or signalling a real helper.

Live interrupted/device-change recovery and current Gateway completion/performance acceptance remain outstanding. This local lifecycle fix does not close those requirements.


A real completed call on 5 October exposed a separate status bug: local Parakeet recognition produced 143 segments, then the unavailable Gateway route returned HTTP 404. The UI called this a processing failure. An isolated real-coordinator regression reproduced that classification. Archive failure now reports `archivePending`, with a Transcript ready title and an explicit connection/retry instruction. Genuine transcription failure retains its own error state. The real call's microphone recovered into a second file; its cumulative frame shortfall marks a conservative timing-review interval, not proof that all speech in the marked span is absent. Audio is preserved.


## Version 0.2.10

Capture warnings were previously held only in the running helper's memory. Reopening a meeting with pending archiving could hide its saved timing-review warning. The controls now restore that warning from the meeting's `capture_gaps`. Cumulative frame shortfalls are described as timing uncertainty, without claiming that the whole marked span is missing or that recovery succeeded. A previous meeting cannot override a current recording's warning.

A focused regression reproduced the missing warning before the fix. Native tests cover restoration, active-recording priority, interruption wording, clearing a previous warning for a clean meeting, and preserving a known warning when metadata cannot be read. The focused native suite passes 59 tests; the Gateway suite passes 20. These checks do not establish fresh Gateway deployment or AI notes.


## Version 0.2.11

Teams can prefix a real call subject with `Meeting compact view | `. The helper now removes that UI label from the meeting title and generated recording and notes folder names. The Gateway also removes it when importing a pending transcript from an older helper, while retaining the original observed title in metadata. Matching native and Gateway regressions reproduced the unwanted prefix before the fix.

Cloudflare Access sessions expire according to the server policy. Renewing sign-in restores authentication but cannot repair an unavailable plugin route. Gateway activation remains a separate operation and can reload or restart the shared service.


## Version 0.2.12

Consent was keyed to a single window and forgotten after one end observation. Two failing native regressions reproduced repeated prompts when Teams replaced its call window or briefly reported an end. Consent now covers the native Teams process's ongoing call windows and clears only after all observed windows continuously report an end for 30 seconds. Unknown or missing observations cancel that confirmation. An open consent dialog blocks another dialog and cannot re-arm consent through nested scans. A manual recording start also marks the detected call as handled.

This groups full-size and compact windows for the current native Teams detector. Calls that follow one another without 30 seconds of confirmed end remain one detection episode; recording can still be started manually. Regression checks cover window replacement, persistence, transient and uncertain observations, dialog scans, manual recording, independent processes, and later calls after old windows retire. 81 focused native tests, 21 Gateway tests using the real 2026.9.8 SDK, and 9 installer tests passed locally. These are automated checks, not observed live-call acceptance. The candidate helper is not installed or restarted until the user approves the idle update.


## Version 0.2.15 activation checks

The first live update exposed two checks missing from earlier archive and discovery tests. A deferred settings obligation from the host upgrade required a Doctor contract. The plugin now validates its retained notes settings without changing them and explicitly declares no separate Gateway state migrations. The host archive SDK owns meeting storage. A real SDK regression first failed to inspect retained settings, then passed and also rejected invalid settings while preserving their values.

The Gateway's synchronous module loader then rejected a top-level asynchronous package-version read in the download module. That read is now synchronous; actual download I/O remains asynchronous. A new full-entry regression reproduced the loader error and passes on both supported SDK versions. The full entry also loaded on the server's actual Node 24 runtime before activation.

Live verification exposed an overlap between startup recovery and a manual retry. Both generated notes for the same meeting. Concurrent identical saves now share a single completion and receipt; conflicting concurrent text is rejected. The real-store regression first observed two completions, then passed with one completion, one utterance and identical receipts.

24 JavaScript checks pass against each supported SDK. The unchanged native implementation previously passed 81 focused checks, including 10 consent tests; the installer suite passed 9 checks. The helper's designated signing requirement is preserved.

The authenticated plugin endpoint returned success after activation. Three completed meetings have Gateway model provenance for the configured OpenAI model and matching text exports. The two gap-free recordings passed retention verification and their raw audio was removed; the recording with a capture gap retained its audio. Two versions produced by the retry overlap were preserved before reconciling the generated export with the Gateway receipt. No invitation list or unsupported speaker identity was fabricated.

The shared Gateway process remained running during activation. Its updater also refused to move a previous package file that was hardlinked to an immutable runtime capture. The complete previous package was preserved outside the watched extension tree before retrying installation into an empty path. This deployment finding does not establish that the host's broader plugin or capture ownership behavior is resolved. Live observation of event-loop metrics and memory is recorded separately from these test results.


Runtime observation on 7 October covered 83 samples over 419.7 seconds during activation and model completion, followed by 60 samples over 298.3 seconds after final activation. Both windows kept the same Gateway PID and returned ready at every sample. The first window contained four degraded samples and a sampled event-loop p99 window value as high as 3,848.3 ms. In the final window, sampled p99 window values ranged from 21.7 to 65.5 ms, with median 23.2 ms. One sample reported CPU degradation. Final-window RSS ranged from 4440 to 4717 MiB, starting at 4655 and ending at 4615 MiB. These are host-provided roughly one-second metric windows sampled about every five seconds, not whole-interval latency percentiles. They do not establish absence of a memory leak or attribute the transient stalls to a particular plugin.

The updater reported forced retirement after five seconds with one outstanding call and no retained consumers for eight unrelated plugins: brave, codex, firecrawl, deepseek, acpx, family-bring, imessage and llama-cpp. Its output also warned that additional cleanup messages were in the host log. The call origins and eventual resource cleanup remain `needs_evidence`. The successful endpoint, completed notes and unchanged process do not close that investigation. The config file's byte hash changed during installation, but comparison with the pre-install backup found identical parsed values and no changed setting paths.

## Version 0.2.16 backlog and call-end checks

The delivery queue previously ran only during startup or after transcription. Receipt-file existence could suppress a failed save, and a retry could include an active recording with a transcript file. Failing coordinator regressions reproduced both cases. The helper now checks finished transcript delivery every minute, persists retry backoff across relaunch, and shares one save path between automatic checks, reconnection and manual retry. Receipts must match the session identity, utterance count and current transcript hash. Local exports must have the required files and matching session metadata. Live recordings and fixtures are excluded; legacy saved receipts without a hash require review.

A separate real-SDK regression reproduced sequential retries regenerating AI notes after a successful save. Completed saves now return the stored documents without another completion or archive write. Changed speech or meeting metadata is rejected as a conflicting revision. A real-store test also verifies recovery from a partial archive with only one of two utterances saved.

Call-end regressions reproduced missed German Teams controls and end text, and loss of a confirmed end during partial Accessibility reads. The detector now retains positive end evidence until new call controls appear, and scopes browser call controls to the tracked document. Missing controls alone remain unknown. The existing 30-second stop countdown and Keep recording override remain.

On 7 October, 97 focused native tests, 25 JavaScript tests against each supported SDK release, and 9 installer tests passed. Both supported SDK archives used the local installed development dependencies. These checks used isolated fixture stores and did not call a live AI provider or mutate the Gateway. A read-only scan of the real recordings found eight verified deliveries, three legacy receipts requiring content verification, two finished recordings without transcripts, and one active recording. It found no confirmed upload backlog.

The candidate is not activated. The active recorder was left running, and no Gateway configuration, installation, reload or restart was performed. Live call-end acceptance and retry after a real connection outage remain `needs_evidence` until the update is deployed and exercised.
