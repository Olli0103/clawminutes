# Apple design adoption audit

Updated 22 October 2026 during the joint Codex and Claude Desktop design review. This replaces the earlier density pass as the current design direction. Apple HIG alignment is a review requirement, not a certification established by compilation.

## Official guidance and implementation

- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials): keep navigation and important controls in the Liquid Glass layer, with documents and lists in the content layer. The pop-up uses the system popover surface. The primary action uses the native glass style on macOS 26 and newer. No decorative glass footer or privacy capsule remains.
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass): remove custom backgrounds that cover system surfaces. Root window, sheet, split-view and popover fills were removed. Settings and the library use native split navigation. Native controls follow the system accent and focus state.
- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/): toolbar actions use native groups; the library, meeting details and inspector let the framework supply their materials. Controls use system sizes. The recording action retains a shared glass identity inside a container, without a second glass backing. User-opened popovers explicitly request activation and keyboard focus.

Settings now opens at 640 × 480 points, is resizable down to 640 × 440 and keeps its size across pane selection. The seven existing panes remain available. The library uses a searchable sidebar and a detail pane with document actions and technical inspection in its toolbar. Cleanup attaches to an available owner window as a sheet, retains the existing deletion confirmation and never changes verification policy.

## Evidence and limits

Claude Desktop inspected the source snapshot and eight before renders, identified hierarchy and material problems, then revised its advice against Apple’s adoption documentation after the owner explicitly required the complete Liquid Glass language. Codex independently checked the official pages and inspected native preview windows. Suggestions and independently observed behavior are separate evidence.

The 320-point pop-up has secondary metadata, three recent meetings at most, one recovery summary during active work and a flat footer. Secondary-text palette samples exceed 4.5:1 on the exported standard light/dark content backgrounds. This does not establish contrast across translucent native surfaces or every control pixel. System accent swatches are reported separately from native button bezels.

ImageRenderer layouts substitute AppKit-backed controls and cannot prove glass rendering. The debug preview offers a real system popover and standalone Settings window for native inspection. The preview contains synthetic meetings, uses a temporary application home and cannot start real capture or contact the Gateway.

Remaining acceptance includes installed interaction, VoiceOver, macOS 15 fallback, system Reduce Transparency/Reduce Motion, busy-background contrast and active/inactive states. The existing supplied raster app icon is preserved; an Icon Composer release asset is separate release work. No installed helper or Gateway was replaced or restarted for this review.

A second Claude Desktop pass reviewed the revised layouts and requested cause-specific recovery copy, a native recovery-action bezel, and cleanup previews of the real view. Those changes are included. Native Settings inspection then caught clipped form labels; the final native JPEG documents the correction. Claude's unread base64-image inference is not visual evidence and is excluded from acceptance.
