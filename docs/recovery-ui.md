# Recovery and storage controls

Version 0.2.17 gives each unfinished meeting a specific explanation and one recommended action. The idle menu header stays **ClawMinutes**; an older meeting issue no longer makes the whole helper appear broken. Recording and transcription still take priority while active.

| Observed condition | Recommended action |
| --- | --- |
| Older or absent save confirmation | **Find my notes** compares the text package with the existing Gateway meeting and restores a provable match. No model completion or audio upload. |
| Verified Gateway notes, missing local export | **Save notes on this Mac** retries the local export offline. |
| Saved meeting with capture gaps or uncertain boundaries | **Review transcript** opens the transcript. Audio remains available for recovery. |
| Missing local speech model | **Download model** opens the existing setup path. |
| Missing cloud speech credential | **Add API key** opens the credential editor. |
| Expired Gateway access | **Sign in to Gateway** starts the existing sign-in flow. |
| Retryable Gateway connection failure | **Check connection** checks the existing connection and eligible delivery backlog. |
| Supported AI generation failure | **Try AI notes again…** opens the explicit recovery sheet when an attempt remains. Otherwise **Save transcript…** offers recovery without another completion. |
| Changed saved transcript | **Open transcript** enables review without overwriting the saved meeting. |
| Unclassified failure | **Save diagnostic report…** gathers the existing redacted report; no repair is invented. |

Technical causes remain under **Technical details**. **More options** retains corrections, separate note versions, transcript-only recovery, Finder access and per-meeting audio cleanup. Presentation changes do not clear attempt counts, unknown paid budgets, fingerprints or delivery failures. Unknown speakers remain unknown.

## Delete old audio

**Settings → Privacy & storage → Delete old audio…** reviews all listed recordings locally and selects only verified, eligible audio. It shows the selected meeting count, space to free and recordings kept for recovery. The user can deselect meetings and confirms permanent deletion once. The existing lock, fresh text/audio verification and partial-cleanup receipts still apply. Notes, transcripts and metadata stay. A failed deletion shows a plain explanation and requires another check. See [audio cleanup](audio-cleanup.md).

The automatic-retention switch is separate and still applies only to recordings started after opt-in. Opening settings, reviewing storage or finding saved notes does not delete audio.

## Appearance and verification

Controls use native SwiftUI Liquid Glass styles on macOS 26 or later, with standard bordered controls on older supported systems and when Reduce Transparency is enabled. Panels use the same accessibility preference and a material fallback. The sidebar, spacing, action hierarchy and light/dark colors use system controls and semantic colors. Apple describes these APIs in [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

An isolated native preview was inspected in light and dark appearances, including meeting recovery, the menu, storage settings and a blocked cleanup row. Offscreen snapshots did not reliably capture the glass compositing and are not visual acceptance evidence. The preview used synthetic meetings and a temporary home. No real audio was deleted and the installed helper/Gateway were not restarted. Full native and packaging checks are recorded in [verification](verification.md). Installed interaction, VoiceOver, Reduce Transparency and confirmation on real user recordings remain `needs_evidence` until approved activation.
