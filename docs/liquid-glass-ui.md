# Native Liquid Glass UI

Current design checkpoint: 22 October 2026, co-reviewed through the Claude Desktop ClawMinutes session. See [Apple adoption audit](macos-design-audit.md) for sources and explicit acceptance limits.

## State and hierarchy

AppState is a presentation projection. Verified artifacts and state.json retain pipeline authority. MenuBarController owns native windows and routes actions. No UI status change alters a retry budget or proves successful delivery.

The pop-up is 320 points wide with native control sizing, 14-point horizontal insets and a compact vertical rhythm. Headline priority remains recording, live call, processing/sending, attention, ready. Dates and causes are quieter than meeting titles. Recording shows its timer in the header and independent full-width microphone/Teams meters. RMS telemetry remains display-only and samples only while visible.

The main action stays prominent for recording or a detected call. During transcription or sending it becomes secondary, preserving access without overpowering progress. Up to three recent meetings appear, or two during recording. Keyboard selection, Return and Command-R remain available. The footer contains the privacy shortcut and native borderless navigation icons.

During active work, old problems collapse to one summary. A common cause keeps its specific action. Mixed causes open an overview, where each meeting retains its evidence and remedy. Idle attention shows at most two cause rows and a link to the rest. No recovery summary silently invokes model work.

## Native surfaces

The system supplies NSPopover, sidebar, toolbar and sheet materials. Root opaque backgrounds and decorative glass containers were removed. Glass controls and the recording identity use macOS 26 APIs behind availability checks; older systems use standard controls. Reduce Motion disables the custom recording transition. Native controls retain system accessibility behavior.

Settings has a resizable 640 × 480 initial window, a 640 × 440 minimum, stable sizing across seven panes and grouped forms. Values use labeled rows. Explanations are secondary sublabels or short footers. The library uses searchable split navigation; meeting document actions and technical details live in native toolbar groups and an inspector. Cleanup uses an attached sheet when an owner window is available. Confirmation and independent deletion verification remain unchanged.

## Review and validation

Build with full Xcode, then run:

```sh
native/.build/debug/ocmh design-preview
native/.build/debug/ocmh design-preview export /tmp/clawminutes-ui-review
python3 scripts/review-ui-matrix.py /tmp/clawminutes-ui-review
```

The interactive preview offers Native popover and Settings window controls. It enters before runtime startup with a temporary application home and synthetic data. Its recording action only changes fixture state.

Export generates 48 layouts plus light/dark/reduced palette checks. Export-only stand-ins keep AppKit lists and button labels visible; they do not establish native glass appearance. Preview dates are frozen without affecting runtime dates. Private artifacts stay under evidence/ui-collaboration-2026-10-22. Only explicitly reviewed synthetic images enter the public review snapshot.

The full native suite passed 537 tests, including 12 opt-in skips and no failures, during this pass. Native preview interaction demonstrated synthetic Command-R recording/stop, current meeting priority and Settings navigation. Installed acceptance, live capture, accessibility across operating systems and sustained Gateway performance remain separate requirements. No helper or Gateway installation, reload or restart occurred.
