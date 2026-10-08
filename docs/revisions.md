# Meeting versions and speaker correction

Open a saved meeting through **See all → Details**. **Identify speakers…** lets you select exact transcript turns and enter a confirmed name. A voice cluster can contain several people, so the sheet does not bulk-name a cluster. Unselected turns retain their labels and attribution evidence. Confirmed corrections have `manual` provenance.

The play button previews at most eight seconds of local audio from that turn. It never uploads audio, starts capture or calls a model. Audio that was deleted after verification is unavailable; the text remains editable through a new version. Playback stops when the sheet closes or another excerpt starts. Live playback and keyboard interaction still need acceptance testing.

**Regenerate notes…** shows the configured templates and creates a new AI-notes version with the chosen template. It uses the Gateway's current notes model and may incur provider charges. Existing exports, including user edits, stay intact. New exports use the current default notes folder with a cleaned meeting title and a version suffix.

## Identity and recovery

Each revision is a separate archive record and local text-only folder. Version 1 keeps its original identity. Later versions derive a recording identity from the original recording ID and version number. The archive identity remains `sha256(started + newline + recordingId)`, truncated to 24 hex characters and prefixed with `teams-`.

The closed revision descriptor carries the version number, original recording ID, previous archive ID and reason. Both sides validate it. The Gateway requires the previous session, utterances and summary to match before a model call. Completed records remain immutable; resending a completed version returns its stored documents without another completion.

The helper requires a verified source receipt, stages the new text under a private temporary folder, then publishes it by directory rename. It copies no audio, receipt or export binding. A new version enters the existing delivery queue and inherits its capped attempts. Only the latest local version can produce another version; save it before proceeding. This is process-crash recovery, not a hardware-level durability guarantee. Cross-process Gateway ownership remains an open host assumption.

## Command line

These commands create a new local version. They do not themselves send it, capture audio or perform recognition.

```sh
ocmh revise-meeting /path/to/saved-meeting --turns 0 3 --name "Confirmed name"
ocmh revise-meeting /path/to/saved-meeting --template one-to-one
ocmh revise-meeting /path/to/saved-meeting --transcript /path/to/preview/transcript.json
```

Turn indices are zero-based positions in `transcript.json`. To re-transcribe, first use `ocmh transcribe` with a separate `--output` preview folder and the desired speech engine, then pass that preview's transcript to `revise-meeting`. Recognition requires the original audio to remain available. In-place transcription of a saved meeting is refused.

The running helper sends new versions through its queue. If it is stopped, `ocmh archive-session --directory /path/to/new-version` explicitly sends the finished text. Earlier archives and exports remain available. Failed original AI notes with no saved parent require a separate recovery flow; creating a revision does not bypass that failure or reset its paid-attempt budget.
