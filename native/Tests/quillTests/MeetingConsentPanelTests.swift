import AppKit
import XCTest
@testable import quill

final class MeetingConsentPanelTests: XCTestCase {
    @MainActor func testConsentDoesNotActivateTheAppAndClosingMeansDismiss() async throws {
        let controller = MeetingConsentPanel(title: "Fixture meeting", fixture: true)
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.isVisible, "Creating consent must not display it or start recording")
        if let preview = ProcessInfo.processInfo.environment["CLAWMINUTES_UI_PREVIEW_DIR"] {
            let oldAppearance = NSApp.appearance
            defer { NSApp.appearance = oldAppearance }
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: name)
                let sample = MeetingConsentPanel(title: "Weekly planning", fixture: true, appearance: NSAppearance(named: name))
                let view = try XCTUnwrap(sample.window?.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: preview).appendingPathComponent(name.rawValue + ".png"))
            }
        }
        controller.dismiss(start: false)
        let result = await controller.present()
        XCTAssertFalse(result)
        XCTAssertFalse(panel.isVisible)
    }
}
