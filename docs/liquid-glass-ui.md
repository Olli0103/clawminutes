# Native UI redesign

The UI has one observable `AppState`. `MenuBarController` owns AppKit windows and routes actions, with forwarding properties for existing runtime callbacks. It no longer stores the presentation fields. `RecentMeeting.make` projects the existing verified backlog and `state.json` stages. UI updates do not change the durable state, retry budgets, transcription, delivery or retention policy.

The headline order is recording, detected live call, processing or sending, attention, ready. A retained meeting subject does not prove a live call. Attention is grouped by structured cause. Unknown causes stay separate by failure code, with their existing recovery guidance. A group opens either the shared sign-in/connection action or a review list. It does not silently request model completions.

The Recent list uses native selection, arrow keys and Return. A row's context menu offers inline Rename. Titles are cleaned with `TeamsMeetingTitle.clean`, saved only as `meeting_title_override` under `archive.lock`, and read ahead of the observed Teams title. Active recording and delivery cannot be renamed through the UI. Rename does not change a recording folder, transcript, pipeline state or delivery envelope. `MeetingDate` is the single locale-aware date presentation API. Missing titles use `Teams call · HH:mm` when a start time is available; missing time is explicitly shown as `--:--`.

## Controls and accessibility

Settings and templates use `NavigationSplitView`. Settings use a grouped `Form`. Cleanup uses a native `Table`, independent checkbox selection, and an inspector for technical details. The meeting window has an inline title field, `PipelineSteps`, sheets for recovery and revisions, and a technical inspector. Empty states use `ContentUnavailableView`.

The density pass uses a 384-point popover with 16-point insets. The privacy shortcut shares the headline row. Recent meetings have a title and one date/cause line, with four visible meetings at most. More than three different recovery causes scroll within a bounded area. Shared recovery lists open in a separate window after the popover closes. Settings remember the selected pane while the helper runs, use the pane as the window title, and resize between 280 and 470 content points. Native grouped forms retain scrolling for longer or conditional content. Form footers hold explanations; the storage row stays flat, with cleanup and file actions together.

See [the Apple design audit](macos-design-audit.md) for the source guidance and explicit choices.

`DesignSystem/Glass.swift` contains all glass APIs. `cmGlass` decorates floating controls only. The start button uses the native `.glassProminent` style; its glass identity is shared with the recording bar inside `GlassEffectContainer`. The recording bar uses a standard stop button within one glass surface. No glass control is nested inside another glass surface. Content remains flat and opaque over the system popover material so video cannot bleed through labels.

macOS 26 glass is guarded by availability checks. macOS 15 uses regular material and bordered controls. Reduce Transparency uses solid surfaces and standard buttons. Reduce Motion disables the container morph and explicit recording transition. Status colours belong to glyphs, with text remaining in the primary label colour. One blue accent is used. Menu-bar artwork is always a template. Recording gets a separate red dot; attention gets a monochrome exclamation badge, never an orange dot.

`AudioLevelMeter` is display-only RMS telemetry on the already-produced PCM buffers. Microphone and Teams recorders expose independent RMS. Reading telemetry cannot change capture progress or recovery. The recording bar enables telemetry only while visible and recording, samples at 80 ms intervals, and disables it on cancellation, disappearance, stop and popover close. No waveform or audio buffers are retained for the UI. Microphone-loss presentation reads the existing buffer-progress evidence, not a quiet RMS value.

## Review matrix

Build with full Xcode, then run the debug-only export entry point:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path native
native/.build/debug/ocmh design-preview export /tmp/clawminutes-ui-matrix
```

Run `native/.build/debug/ocmh design-preview` to open the interactive matrix. This enters an isolated preview before runtime startup, sets a temporary home, does not acquire the helper's runtime lock, and does not contact the Gateway. Its Start/Stop action changes synthetic UI state only.

The export writes 48 content-sized PNGs plus a manifest with actual pixel dimensions: idle, call detected, recording, recording with microphone lost, processing, sending, notes ready, attention, cleanup empty, cleanup with items, call detected with three identical attention causes, and call detected with mixed causes. Each has light, dark, reduced-transparency light and reduced-transparency dark appearances. Detected-call cases use a synthetic busy conferencing background. No real meeting data is included. A missing microphone displays an empty meter rather than retaining a misleading audio level.

`ImageRenderer` does not draw AppKit-backed lists, tables, progress bars or button bezels. PNG export therefore reuses row/cell views in flat SwiftUI containers and uses export-only control styles. Native control chrome, focus rings, keyboard selection and glass morphing require the interactive preview. The PNGs are review layouts, not proof of native compositor behavior. The interactive app always uses native controls.

macOS 15 and macOS 26 runtime appearance and a live recording acceptance check remain `needs_evidence` until tested on those environments. Native inspection here uses macOS 27.2 and Xcode 27.0. The redesigned helper has not been installed or activated as part of this source change. No Gateway restart is required for UI review.

## Verification on 9 October 2026

The native suite passed 537 tests, with 12 opt-in tests skipped and no failures. Presentation tests cover headline priority, grouped and mixed causes, relative dates, display-only RMS, and rename isolation from the delivery envelope. Debug and release builds were checked with full Xcode.

The isolated native preview verified arrow-key selection, Return opening a selected meeting, Command-R switching the synthetic recording state, the technical inspector, and cleanup table focus remaining separate from deletion checkboxes. The density pass additionally inspected native General, Privacy & storage and Notes panes, including the capacity bar. Light appearance was inspected over the bright conferencing mosaic. PNG checks over bright and dark mosaics measured primary-text contrast of 9.71–17.78:1 and white-on-accent contrast of 8.01:1. These measurements do not establish contrast for every native control pixel or a live glass transition.

Review artifacts are local and ignored by Git under `evidence/liquid-glass-2026-10-09/`: a filterable `index.html`, the latest 48 PNGs in `compact-matrix/`, native compositor screenshots in `native-screenshots/`, a contrast report and `ClawMinutes-UI-review.zip`. Re-run `scripts/review-ui-matrix.py <export-directory>` to check image dimensions and measured text contrast after an export. The installed helper process was not replaced or stopped, and the Gateway was not changed.
