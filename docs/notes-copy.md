# Copy existing notes

Changing the default notes folder affects future exports. To copy saved meetings explicitly, use **Settings → Notes → Copy existing notes…**, or **Copy notes to another folder…** in a meeting's details.

Choose an existing destination folder. The review lists each meeting's files, total size and source/destination paths. Nothing is selected initially. Select meetings, inspect their locations and confirm before copying. The year/month hierarchy and timestamp plus cleaned meeting title remain intact. The action copies the actual files, including user edits, attachments and empty subdirectories. It keeps the originals and updates each successful meeting's local export binding. It leaves the future default unchanged and does not contact the Gateway.

Each selection is checked again when copied. The recording identity, archive receipt, source path and destination folder identity must still match the review. The source file list, directory list, file sizes and SHA-256 hashes must match. The staged copy and source are compared again before publishing the destination and updating the saved location. Concurrent saves and installer operations block copying through OS locks. Existing destinations are never overwritten, and a destination inside the source folder is rejected.

Each meeting reports its own outcome. A failure does not stop other selected meetings. Failed selections require **Review again** before another attempt. Closing the window is disabled during a batch. The original folders remain available even if a copy or location update fails.

## Limits and recovery

The review accepts regular local files and directories. Symbolic links and special files require manual review. Each meeting is limited to 1,000 entries, 16 MB per file and 100 MB in total. These limits bound review work; a larger folder requires a manual copy.

The copy is staged under the destination parent and published with a filesystem rename. Updating the saved export binding is a separate operation. A process crash or write failure between publication and binding can leave a complete copy that is not the meeting's saved location. The original is preserved, and a retry refuses to overwrite that destination. Inspect the destination and saved location before resolving it manually. This is not a transaction across the recording and destination filesystems, nor protection against a hostile process changing ancestor paths during copying.

The command `ocmh migrate-notes-folder --directory <recording> --destination <new-root>` uses the same bounded snapshot and staged-copy checks, without the interactive review. Do not run it on an active recording.

## Verification boundary

Synthetic temporary-folder tests cover edited notes, extra files, empty directories, read-only review, changed sources/receipts/recording identities, replaced destinations, conflicts, nested destinations, links, limits and OS locks. Offscreen light/dark renders exercise the review without opening a window or copying user notes. Installed interaction, accessibility and crash recovery during a copy still need approved live acceptance. No existing user folders were migrated while implementing this source candidate.
