# Helper installation and interrupted updates

This describes source behavior. Actual LaunchAgent activation, process exit, signed updates and macOS permission continuity still need approved installed acceptance. Never install, update, remove or restart an installed helper or Gateway without explicit approval. Finish active recording and processing first.

## What an update preserves

Every lifecycle action, including `run`, takes the exclusive installer lease. Native recording and processing hold shared leases, so an installer cannot interrupt them. The lock file stays in place after release.

The installer verifies the existing app identity and LaunchAgent executable path. It copies and verifies the new app in a private `.ocmh-install-*` directory. It saves exact configuration, LaunchAgent and installation-receipt bytes with their original permission modes, and prepares replacements before unloading the job. The active and parked LaunchAgent locations are both snapshotted, including absence, so a disabled-login choice survives update and rollback. Conflicting files block lifecycle actions. See [launch at login](launch-at-login.md). Backup files are private even if the original had broader permissions. A manifest records original file hashes, replacement hashes, backup names and whether the old job was loaded.

Before replacement, `installation-pending.json` publishes that manifest. The old apps, including the legacy helper path, move into the private stage. Configuration, LaunchAgent and receipt publish through separate atomic file replacements. The receipt contains the version, binary hash, launch-request result and a Gateway-configured boolean. It excludes the Gateway URL, token and configuration contents. A successful bootstrap means launchd accepted the job, not that recording, permissions or delivery passed acceptance.

On ordinary failure, the installer unloads any attempted candidate job, confirms its exact helper processes exited, and restores the previous apps and exact file bytes/modes. Previously absent files remain absent. It resumes the previous job only if it was loaded beforehand and launch was requested. `--no-launch` suppresses bootstrap, including rollback bootstrap. It still unloads/stops an idle installed helper to replace it, so it is not a read-only command.

An unconfirmed unload/exit, changed file or replaced app, rollback failure, or interrupted publication preserves the stage for review. The installer refuses to overwrite an external settings edit. It never deletes an unknown old `.next`, `.previous` or installer stage to make room for another update.

## When an interrupted update is found

Do not delete the marker or run another installer to bypass the gate. `run`, install, update and remove refuse pending markers and leftover stages. Native code in this candidate also checks for any pending marker after acquiring its work lease. A malformed marker or dangling link blocks recording and processing. This gate is not present in older installed binaries, which must be treated separately during recovery.

Review the following locally without sharing credentials:

1. Identify the exact helper process and launchd job state. Do not stop or relaunch them until approved. A released installer lock alone does not prove the installation is coherent.
2. Read the marker and its private stage. Treat manifest paths as evidence to verify, not commands to execute. Confirm the expected installation root, LaunchAgent path, bundle identity, file hashes and backup contents. Backup configurations may contain credentials.
3. Compare the live files with the staged before/after files. Preserve unrelated edits and all recordings. Some apps may already have been restored before a later rollback step failed.
4. Prepare a concrete restoration or completion plan, including exact app/file destinations and whether a previously loaded job needs resuming. Obtain approval before installed writes or activation.
5. After approved restoration, verify app signatures, exact configuration/LaunchAgent/receipt consistency and job ownership. Resolve the marker/stage only once that state is established. Then perform approved functional acceptance.

No automatic crash-recovery command consumes the manifest. Manual review prevents a stale or altered manifest from selecting files to overwrite. A cleanup failure after commit leaves a coherent published installation and an installer stage requiring review; it does not roll back a running committed app.

## Evidence and limits

Isolated tests exercise the actual Python entry point in temporary homes. OS command and signal calls are stubbed. They cover launch failure, receipt/write failures before and after replacement, fresh-install absence, exact bytes/modes, loaded/unloaded prior jobs, no-launch behavior, legacy apps, failed rollback, concurrent edits, stale stages and private credential-free receipts. A child installer exits abruptly during bootstrap, bypassing Python rollback. Its backups remain and the next lifecycle invocation refuses to run. Native tests terminate a synthetic lock-holder process and show that a pending marker still blocks recording creation and engine preparation.

This is not a multi-file filesystem transaction, a hostile-process isolation guarantee or a power-loss guarantee. Atomic replacements and fsync narrow failure windows. The marker and backups make uncertainty visible. Directory identity checks detect replacement, not every in-place content edit. Real launchd behavior, signed-app ownership, rollback under an actual failed activation and permission continuity remain `needs_evidence`.
