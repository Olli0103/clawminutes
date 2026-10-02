# Meeting notes, templates and generated files

Recording and generated notes folders use `yyyy.MM.dd-HHmm_Meeting-title`. Notes retain the year/month hierarchy. Names strip Teams account/organization suffixes and collapse punctuation and spaces into single hyphens. Archive IDs stay in metadata, outside the folder name. A numeric suffix is used only when separate archives have an identical timestamp and cleaned title, preserving both versions. Existing generated exports are moved without replacing edited notes or transcripts; the recording's export pointer is updated. The title comes from fresh meeting UI evidence or an explicit user correction. If a title appears after recording starts, the helper renames the folder after Stop, when both audio tracks are closed. The local `recording_id` remains stable through renames so retries refer to the same Gateway archive. Active folders are never renamed by the migration command. Ended or stale call contexts cannot bind a new recording or block a fresh call's speaker observations. Missing speaker-name evidence still produces Unknown speaker rather than a guessed participant name.

Speech recognition and note generation are separate choices. Parakeet v3 recognizes audio on the recording Mac. The helper sends finished text and a closed metadata envelope to the authenticated Gateway; no raw audio is accepted by this plugin endpoint.

Choose AI notes to use the configured Gateway system agent's primary model through OpenClaw's simple completion SDK. The plugin passes the configured system owner explicitly, which is required for a Gateway with multiple agents. `notesAgentId` can select another configured credential owner. It does not start an agent session. The completion contains only the selected template, meeting metadata, and transcript. It has no tools, agent session, workspace prompts, or file access. A configured cloud model receives that text. The actual response provider and model are recorded independently of the speech model. Simple highlights and transcript-only mode use no language model. AI errors preserve the transcript and recording and never silently switch models or fabricate notes.

Settings has a template picker and editor. Built-in Meeting, 1:1, and SAP meeting examples can be edited, duplicated, or deleted. Edit the context and ordered section headings/instructions; add, remove and reorder sections, then Save templates. Each recording keeps a snapshot of the selected template from Start. New template edits apply to subsequent recordings. Templates can request action or people-evidence candidates, but no Todoist tasks, people files, messages or calendar items are created.

Choose notes folder selects a generated export root on the recording Mac. Default:

```
~/Documents/ocmh/Meetings/
  YYYY/MM/YYYY.MM.DD-HHmm_Meeting-title/
    notes.md
    transcript.md
    metadata.json
```

The SDK's canonical Meetings archive remains on the Gateway. Audio stays in the helper's private recording directory until the configured retention check passes. Set `audio_retention` to `delete_after_verification` in the helper configuration to remove finished raw tracks automatically. The check requires valid transcript timestamps, a matching transcript hash and utterance count in the Gateway receipt, readable notes and transcript exports matching that receipt, and audio coverage within 5 seconds or 1 percent of the expected recording length. Active, failed, incomplete or conflicting recordings retain their audio. The default for users who have not selected this policy is to keep audio. Each deletion writes `audio-retention-receipt.json`; transcripts, metadata, templates and notes remain. Folder retries preserve edits to existing exports, reject conflicting folders and symlinks below the chosen root, and can export an existing saved receipt without calling the model again. Deleting audio prevents later retranscription or speaker reanalysis from those tracks.

A positively detected native Teams call window supplies its specific Accessibility window title. Generic Teams/window titles remain unavailable and use a Teams meeting fallback. The helper records first/last observation times and a positive end observation separately from recording times. First seen does not prove the exact call start; last seen does not prove a participant's leave time. A manual recording with no linked call has no observed call clock.

Joined names come only from timestamped Teams participant/speaker observations. Coverage remains partial; the helper does not claim that all people were visible throughout the call. Invitees are a separate list. Without invitation evidence, the notes say needs_evidence: invitation list unavailable. This implementation does not access Apple Calendar. Read-only Calendar matching requires separate authorization. A real Teams call on 2 October 2026 evidenced automatic title capture, four roster entries, and an 834-segment local transcript. Coverage remains partial. An earlier end observation was disproved by later active observations; the scanner now clears that stale end when activity resumes.

Set **Your voice → Your name** to your Teams display name for the personal microphone track. Enable **Shared microphone** when it can capture multiple local people; those segments remain unknown. This setting does not identify remote voices or establish attendance.

In Gateway plugin settings, **Notes model** selects the notes model as `provider/model`; for example `openai/gpt-6-sol`. It uses the credential owner selected by **Model credential owner** and does not change agent defaults or speech recognition.

Microphone startup is confirmed only after frames reach the audio file. If the engine starts without callbacks, startup retries once, then reports an input-device error and preserves the attempted capture. This check does not recover audio that was never captured, and no hardware route cause is inferred.
