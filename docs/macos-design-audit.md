# macOS design audit

Reviewed on 9 October 2026 against Apple's current public guidance. The review covered 14 relevant Human Interface Guidelines chapters and the SwiftUI Liquid Glass adoption documentation. It did not attempt to audit every platform-specific HIG page.

| Apple guidance | ClawMinutes decision |
| --- | --- |
| [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | Keep comfortable desktop density and keyboard access. Use a 384-point task popover, two-line meeting rows and content-sized exports. Keep native control sizes. |
| [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers/) | Recording is the primary action. Recent meetings and recovery remain secondary. Close the popover before opening a recovery window. Do not put a sheet over the transient popover. |
| [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) | Use regular glass sparingly for floating controls. Keep content flat and opaque so video cannot obscure text. Use native control styles and avoid glass inside grouped forms. |
| [Applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) | Centralize availability checks, glass identity and container transitions in DesignSystem. Start and recording controls share an identity. Disable morphing for Reduce Motion. |
| [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Color](https://developer.apple.com/design/human-interface-guidelines/color), [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) | Preserve system text styles, use primary text for explanations, label icon buttons, and pair status colour with text and glyphs. Reduce Transparency uses solid controls. Verify text against bright and dark backgrounds. |
| [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Use native buttons and one prominent recording action. Footer icons have help and accessibility labels. The cleanup entry opens a review; the final destructive action retains its confirmation. |
| [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Native Recent selection supports arrows and Return. Reuse the same compact meeting row in the library. Cleanup focus and inspection stay separate from deletion selection. |
| [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [Windows](https://developer.apple.com/design/human-interface-guidelines/windows), [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) | Use grouped forms, pane-specific window heights, the selected pane as the window title, and remember the pane while the helper runs. Explanations use leading-aligned form footers. Content windows resize. Recovery sheets belong to the meeting window. |

## Explicit choices and limits

Apple describes toolbar-based macOS settings panes. This implementation retains the requested `NavigationSplitView` instead, with native sidebar selection and grouped forms. No custom window frame or imitation toolbar is added.

The popover has an opaque content background over its system material. This deliberately prioritizes the requested video legibility over maximum translucency. Glass remains visible on the recording controls, privacy shortcut and footer.

The installed OS is macOS 27.2 and the compiler is Xcode 27.0. The UI uses macOS 26 APIs only behind availability checks and still targets macOS 15. Compilation does not prove the macOS 15 or macOS 26 runtime appearance. Those runtime checks remain `needs_evidence`.

ImageRenderer exports are synthetic layouts. AppKit-backed control chrome needs native compositor inspection; exported button and list styles do not prove native focus or glass transitions. The native preview caught a glass label rendering problem inside a grouped form. The storage row now stays flat.

No recording, speech recognition, delivery, retry or cleanup verification policy changes are part of this density pass. The installed helper and Gateway are not updated or restarted for these checks.
