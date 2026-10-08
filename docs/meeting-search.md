# Find a past meeting

Choose **See all** in the menu-bar popover. Search finds titles, saved notes and transcripts for meetings recorded on this Mac. Use **Needs attention** to show only meetings with an unresolved issue. Press Command-F or choose the search icon to focus the field.

Search ignores case and accents. All entered words must occur in the title or in one document together with the title. For example, `weekly budget` finds a meeting titled Weekly planning whose notes mention budget. Results retain the library's date order and show a matching excerpt from notes or the transcript. Open and Details use the same document and recovery actions as the meeting list. A matching excerpt is source text, not evidence that a decision was approved or a speaker was identified.

Search stays on this Mac. It makes no Gateway, model, credential or capture request. Only the library's explicit Markdown document paths are read. Audio, logs, participant files, arbitrary folders and canonical notes are not indexed.

## Coverage and resources

An empty search lists meetings without reading their speech. Text reads run in an actor away from the UI thread. Queries are debounced and cancellation prevents an earlier query from publishing results. New meeting snapshots refresh the current search.

The cache is memory-only, limited to 32 MB of original/normalized text and 256 documents. Eviction affects reuse, not coverage; every eligible meeting is still checked. Clearing the search drops the cache, and closing the library releases its view. No persistent copy or search database is created. File identities, sizes, modification/change times and ancestor identities invalidate cached text. A file changed while reading is rejected. Transient read failures are not cached.

Documents must be regular UTF-8 Markdown files no larger than 20 MB. Linked files and linked document ancestors are excluded. The exact macOS root aliases `/var`, `/tmp` and `/etc` are accepted only when they point to their expected `/private` locations. Missing, unreadable, linked and oversized documents encountered by a query produce a coverage notice. Results never silently truncate a large document. Up to 256 characters and 32 words are accepted per query.

A cold search over a large library can take longer while documents are read. There is no latency guarantee yet. Search does not repair legacy receipts, recover missing speech or change an archive's verified status. Full-history latency and keyboard/VoiceOver behavior in the installed helper remain acceptance work.

## Verification

The original title-only implementation failed a synthetic search for a word present only in a transcript. Isolated tests now cover transcript/notes matches, title-plus-body terms, Unicode, attention filtering, order, unchanged-cache reuse, edits with restored mtime, removed files, linked ancestors/leaves, query/document/cache limits, cancellation and clearing/removing cached sources. Offscreen light/dark previews exercise the real debounced query and show matching notes/transcript excerpts and a coverage notice.

These are source checks using temporary text, not live helper activation or searches of user meetings.
