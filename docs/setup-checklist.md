# Setup and short audio check

The helper shows the setup checklist once on its first launch. General Settings can reopen it at any time. Opening it reads the current permission, speech-model/key and cached Gateway status; it does not request access, download a model, sign in or capture audio. Each operation has an explicit button. Closing setup is allowed without finishing it, and does not imply readiness. Accessibility detection and Gateway connection are optional for a manual local recording. Missing speech models and credentials still pause their matching pipeline stage.

The checklist's audio check requires microphone and system-audio permission and completion of startup recovery. Start records microphone and application-filtered Teams audio for ten seconds after device startup. The user should speak and play a sound in Teams. This diagnostic explicitly disables the global-system fixture fallback. It uses a new private UUID folder under the helper's `capture-checks` directory, outside the recordings queue, without `meta.json`, meeting context, transcription or delivery. It does not create a meeting or contact the Gateway/provider.

The menu bar names the active audio check, shows its countdown and uses the recording color. The popover's primary action cancels the check. The setup window offers Cancel, including Escape. A meeting's explicitly approved Start cancels and waits for an outstanding check before opening its own capture. Closing the setup window is blocked while capture is running or stopping, and normal helper Quit waits for check cleanup. Startup failures and cancellation stop both devices before removing test files.

## Ownership and results

Meeting recordings and audio checks acquire one exclusive `capture.lock`, as well as the shared lifecycle lease. A second process cannot open another capture through these paths. The installer requires the exclusive lifecycle lease. Lock failure occurs before a check constructs devices or creates its test folder. A check cannot stop an existing meeting recording.

After stopping, a bounded local PCM read checks each track. A readable track must contain at least eight seconds and a sample magnitude of at least 0.001, about -60 dBFS, to report Sound received. Short, silent, missing, unreadable, linked, oversized and invalid-format tracks cannot pass. This detects a signal, not speech accuracy, participants, echo quality or whole-meeting reliability. No permanent readiness certificate is saved.

Cleanup checks the root and UUID directory identities and removes only the two expected regular test audio files. Replaced folders, links and unexpected files are preserved and produce a visible cleanup failure with Show test files. Cleanup can be partial if a later unlink fails; it never claims success unless the test directory is removed. Existing meeting audio is outside this operation. A hard crash can leave a private check folder behind. It is not automatically sent or transcribed and may require manual removal. The short check does not establish operating-system startup/stop timeout behavior.

## Evidence and acceptance

Isolated tests use fake devices and real synthetic PCM files. They cover permission refusal without capture, ten countdown ticks, both-track signal inspection, silent/short/missing audio, partial startup failure, actual task cancellation, lifecycle/capture exclusion, lock release, replaced folders, linked audio and unrelated-file preservation. Offscreen light/dark checklist renders are inspected without opening a window or calling a permission/capture API.

Installed first-run behavior, keyboard/VoiceOver focus, permission changes, actual Teams filtering, ten-second timing, cancellation during operating-system startup/stop, microphone routing and menu-bar color remain `needs_evidence`. No real check was run during source verification. Installation/activation and live acceptance still require approval.
