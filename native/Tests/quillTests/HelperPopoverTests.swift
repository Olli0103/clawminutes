import AppKit
import SwiftUI
import XCTest
@testable import quill

final class HelperPopoverTests: XCTestCase {
    @MainActor func testStatusFirstPopoverCanRenderWithoutCaptureCredentialsOrGateway() throws {
        let controller = MenuBarController(preview: true)
        let sample = [
            RecentMeeting(directory: URL(fileURLWithPath: "/fixture/one"), title: "1:1 with Sam", started: Date(timeIntervalSince1970: 1791446400), stage: .exported, issue: nil, detail: "Notes ready", notes: URL(fileURLWithPath: "/fixture/one/notes.md"), transcript: nil),
            RecentMeeting(directory: URL(fileURLWithPath: "/fixture/two"), title: "Weekly planning", started: Date(timeIntervalSince1970: 1791442800), stage: .transcribed, issue: nil, detail: "Waiting for connection", notes: nil, transcript: nil),
            RecentMeeting(directory: URL(fileURLWithPath: "/fixture/three"), title: "Design review", started: Date(timeIntervalSince1970: 1791356400), stage: .needsAttention, issue: .signInRequired, detail: DeliveryFailure.signInRequired.detail, notes: nil, transcript: nil)
        ]
        controller.updateRecentMeetings(sample)
        XCTAssertEqual(controller.recentMeetings.count, 3)
        XCTAssertEqual(sample[0].statusTitle, "Notes ready")
        XCTAssertEqual(sample[1].statusTitle, "Waiting to send")
        XCTAssertTrue(sample[2].needsAttention)
        guard let preview = ProcessInfo.processInfo.environment["CLAWMINUTES_UI_PREVIEW_DIR"] else { return }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)
        for page in HelperSettingsPage.allCases {
            let settings = NSHostingView(rootView: HelperSettings(controller: controller, initialPage: page).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua); window.contentView = settings
            settings.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
            settings.cacheDisplay(in: settings.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: preview).appendingPathComponent("settings-" + page.id + ".png"))
            XCTAssertFalse(window.isVisible)
        }
        for (name, content, size) in [
            ("meeting-library", AnyView(MeetingLibraryView(controller: controller)), NSSize(width: 660, height: 560)),
            ("template-editor", AnyView(NoteTemplateEditor(controller: controller)), NSSize(width: 780, height: 660))
        ] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            let view = NSHostingView(rootView: content.environment(\.colorScheme, .light))
            window.contentView = view; view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: preview).appendingPathComponent(name + ".png"))
            XCTAssertFalse(window.isVisible)
        }
        for dark in [false, true] {
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: name)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: name)
            let view = NSHostingView(rootView: HelperPopover(controller: controller)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = view; window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: preview).appendingPathComponent("popover-" + (dark ? "dark" : "light") + ".png"))
            XCTAssertFalse(window.isVisible)
        }
    }
}
