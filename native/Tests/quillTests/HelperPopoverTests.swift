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
        let transcript = Transcript(engine: "parakeet", model: "fixture", created_at: "2026-10-08T08:00:00Z", segments: [
            .init(speaker: "system_unknown", start_ms: 125000, end_ms: 130000, text: "Let's confirm who will prepare the proposal before assigning an owner.", source: "system"),
            .init(speaker: "system_unknown", start_ms: 131000, end_ms: 133000, text: "The decision is still open.", source: "system")])
        for kind in [NotesRecovery.Kind.retryAI, .transcriptOnly] {
            let view = NSHostingView(rootView: NotesRecoveryEditor(controller: controller, meeting: sample[2], kind: kind)
                .environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view; view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: preview).appendingPathComponent("notes-recovery-" + kind.rawValue + ".png"))
            XCTAssertFalse(window.isVisible)
        }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for mode in [MeetingRevisionEditor.Mode.speakers, .template] {
                let view = NSHostingView(rootView: MeetingRevisionEditor(controller: controller, meeting: sample[0], mode: mode, loadedTranscript: transcript)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSApp.appearance; window.contentView = view; view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: preview).appendingPathComponent("revision-" + mode.rawValue + (dark ? "-dark" : "-light") + ".png"))
                XCTAssertFalse(window.isVisible)
            }
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

extension HelperPopoverTests {
    @MainActor func testFullTextResultsRenderInLightAndDarkWithoutOpeningAWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes.md"), speech = root.appendingPathComponent("transcript.md")
        try Data("Discussed the budget forecast. No approval was given; the decision remains open.".utf8).write(to: notes)
        try Data("The budget needs review before the next planning meeting.".utf8).write(to: speech)
        let meetings = [
            RecentMeeting(directory: root.appendingPathComponent("ready"), title: "Weekly planning", started: Date(timeIntervalSince1970: 1791446400),
                stage: .exported, issue: nil, detail: "", notes: notes, transcript: nil),
            RecentMeeting(directory: root, title: "Design review", started: Date(timeIntervalSince1970: 1791442800),
                stage: .needsAttention, issue: .signInRequired, detail: DeliveryFailure.signInRequired.detail, notes: nil, transcript: speech),
            RecentMeeting(directory: root.appendingPathComponent("missing"), title: "Earlier meeting", started: nil,
                stage: .needsAttention, issue: nil, detail: "", notes: nil, transcript: root.appendingPathComponent("missing/transcript.md"))
        ]
        let report = try await MeetingSearchIndex().search(meetings, query: "budget")
        XCTAssertEqual(report.matches.count, 2); XCTAssertEqual(report.unavailableDocuments, 1)
        let controller = MenuBarController(preview: true)
        controller.updateRecentMeetings(meetings)
        guard let destination = ProcessInfo.processInfo.environment["CLAWMINUTES_UI_PREVIEW_DIR"] else { return }
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: MeetingLibraryView(controller: controller, initialQuery: "budget", initialReport: report)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSApp.appearance; window.contentView = view
            try await Task.sleep(for: .milliseconds(600)) // Allow the view's real debounced query to finish.
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: destination).appendingPathComponent("fulltext-library-" + (dark ? "dark" : "light") + ".png"))
            XCTAssertFalse(window.isVisible)
        }
    }
}
