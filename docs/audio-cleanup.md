# Delete old audio

Use **Settings → Privacy & storage → Delete old audio…** to review historical recordings, or **More options → Delete this meeting's audio…** in a meeting's details. This action is independent of the future-only automatic-retention setting.

The review is read-only. It lists eligible and blocked meetings, remaining declared tracks, their sizes and recording locations. All verified recordings are selected automatically; unfinished or unverified recordings remain unselected and show the next recovery step. Deselect any meeting you want to keep. Choose **Delete audio…**, review the total size and meeting count, then confirm **Delete audio** once. Deletion removes only their declared capture tracks. Notes, transcripts, metadata, templates and other files remain. Audio playback, re-transcription and further voice analysis are unavailable after removal.

Each selected meeting is verified again under its save lock and a helper lifecycle lease. Active or incomplete captures, capture gaps, missing Teams speech, invalid timestamps, missing or mismatched Gateway readback, changed exported notes, unreadable tracks and incomplete coverage block deletion. Existing user edits are preserved rather than overwritten to make cleanup eligible.

A fresh check must match the reviewed text hashes, recording and export directory identities, track identities, sizes, timestamps and durations. The verifier reads audio headers to check duration against expected capture coverage within five seconds or one percent. It does not read or hash every audio sample, assess recognition accuracy or prove speaker identity. Verification runs outside the UI thread and makes no Gateway or model request.

Each meeting reports its outcome. Failed rows require another review before retrying. Closing the review window is disabled during deletion. The batch can continue with other selected meetings after one fails, and it never changes the preference for future recordings.

## Interrupted cleanup

Before the first unlink, a schema-2 `audio-retention-receipt.json` records the verified text hashes, track identities, durations and declared files. Each successful unlink updates progress. Completion is recorded only when all declared tracks are absent. A prepared or partial audit does not report audio as removed.

A fresh review can resume a partial schema-2 cleanup only when its text proofs and directory identities still match and surviving tracks pass both identity and duration checks. If a process exits after unlinking but before updating progress, the prepared audit can account for that missing track. If a surviving track or text proof changed, cleanup stops and keeps the remaining audio. Missing tracks without a matching schema-2 audit require manual review. Older partial audits do not contain enough evidence to resume automatically.

The receipt is an audit of local removal, not a Gateway ownership claim or a transaction covering every file. A crash or write failure can leave some tracks removed and others retained. The UI says so and offers a fresh review. The checks protect against ordinary edits and cooperating processes using the locks; they do not defend against a hostile process replacing ancestor paths between checks and unlinking. Unlinking declared files does not erase backups or other copies.

## Command line

`ocmh verify-audio-retention --directory <recording>` now defaults to a read-only review. It reports eligible remaining tracks and bytes without creating a deletion receipt. Add `--delete` to explicitly verify again and remove the eligible tracks under the save lock and lifecycle lease. This changes the earlier command's implicit deletion behavior.

## Verification boundary

Synthetic tests cover dry-run behavior, real PCM-header probing, changed proof/audio rejection, locks, partial deletion, lost progress after unlink, remaining-track changes, missing-audit refusal, false completion markers and linked-folder rejection. Offscreen light/dark reviews exercise eligible and blocked rows without opening a window or deleting audio. Fault injection represents interrupted operations; installed process-crash behavior, keyboard/accessibility and live-call regression acceptance remain unverified. No user recording was deleted while implementing this candidate.
