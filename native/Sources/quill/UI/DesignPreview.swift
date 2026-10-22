#if DEBUG
import AppKit
import SwiftUI

/// Debug-only, synthetic and isolated. Never starts the runtime, takes its lock,
/// contacts a Gateway, reads real meetings or installs a helper.
@MainActor
enum DesignPreview {
    static let states = ["idle", "call-detected", "recording", "recording-mic-lost", "processing", "sending", "notes-ready", "attention", "cleanup-empty", "cleanup-items", "call-same-cause", "call-mixed-causes"]
    static let appearances = ["light", "dark", "reduced-light", "reduced-dark"]
    static let now = Date(timeIntervalSince1970: 1791531000)

    static func controller(for name: String) -> MenuBarController {
        let controller = MenuBarController(preview: true)
        let state = controller.appState
        state.detection = "Waiting for a Teams call"; state.accessibilityGranted = true
        state.selectedEngine = "parakeet"; state.popoverVisible = false
        state.notesFolder = "/Users/demo/Documents/Meetings"
        state.localSpeakerName = "Sample person"
        state.gatewayStatus = "Gateway connected: preview.invalid"
        state.localModelReady = true
        state.recordingBytes = 180_000_000; state.freeBytes = 281_000_000_000; state.capacityBytes = 512_000_000_000
        controller.onToggle = { state.recording.toggle(); state.elapsed = "0:00" }
        controller.audioLevels = { (0.32, 0.67) }
        state.callDetectedAt = now; state.meetingSubject = "Portfolio planning"
        switch name {
        case "call-detected", "call-same-cause", "call-mixed-causes": state.detection = "Teams meeting detected"
        case "recording", "recording-mic-lost":
            state.recording = true; state.elapsed = "12:34"; state.micLevel = 0.32; state.teamsLevel = 0.67
            state.micLost = name == "recording-mic-lost"
        case "processing":
            state.pipelineStatus = .transcribing(session: "Portfolio planning", queued: 0)
            state.recentMeetings = [meeting("Portfolio planning", stage: .transcribing)]
        case "sending": state.recentMeetings = [meeting("Portfolio planning", stage: .delivering)]
        case "notes-ready": state.recentMeetings = [meeting("Portfolio planning", stage: .exported)]
        case "attention": state.recentMeetings = [meeting("Portfolio planning", cause: .unconfirmed)]
        default: break
        }
        if name == "call-same-cause" {
            state.recentMeetings = (1...3).map { meeting("Planning \($0)", cause: .signIn) }
        } else if name == "call-mixed-causes" {
            state.recentMeetings = [meeting("Weekly planning", cause: .signIn), meeting("Design review", cause: .gateway), meeting("Customer call", cause: .aiNotes)]
        }
        return controller
    }
    static func meeting(_ title: String, stage: MeetingPipelineState.Stage = .needsAttention, cause: AttentionCause? = nil) -> RecentMeeting {
        let code: String
        switch cause {
        case .signIn: code = "sign_in_required"
        case .gateway: code = "network_unavailable"
        case .aiNotes: code = "ai_generation_failed"
        default: code = "fixture_review"
        }
        return RecentMeeting(directory: URL(fileURLWithPath: "/synthetic/" + title), title: title,
            started: now.addingTimeInterval(-3600), stage: stage,
            issue: cause.map { _ in DeliveryFailure(code: code, detail: "Synthetic preview only", retryable: cause == .gateway, completionAttempted: cause == .aiNotes) },
            detail: "Synthetic preview only", notes: stage == .exported ? URL(fileURLWithPath: "/synthetic/notes.md") : nil,
            transcript: URL(fileURLWithPath: "/synthetic/transcript.md"),
            pipelineCompletion: stage == .exported ? 4 : stage == .delivering ? 2 : stage == .transcribing ? 1 : 0,
            canVerifyLegacyReceipt: cause == .unconfirmed)
    }
    static func run(arguments: [String]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-preview-" + UUID().uuidString)
        setenv("OPENCLAW_TEAMS_HOME", root.path, 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = ApplicationMenu.make()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu; app.mainMenu?.insertItem(fileItem, at: 1)
        if arguments.first == "export", arguments.count == 2 {
            try export(to: URL(fileURLWithPath: arguments[1])); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ClawMinutes UI matrix · synthetic data"
        window.contentView = NSHostingView(rootView: MatrixBrowser())
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }
    static func export(to output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var entries: [[String: String]] = []
        for name in states {
            for appearance in appearances {
                let dark = appearance.contains("dark"), reduced = appearance.hasPrefix("reduced")
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if name == "idle" {
                    let palette = HStack(spacing: 0) {
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                        Rectangle().fill(CMTheme.secondary)
                        Rectangle().fill(Color.primary)
                        Rectangle().fill(CMTheme.accent)
                    }.frame(width: 80, height: 20).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let colors = ImageRenderer(content: palette); colors.scale = 2
                    if let image = colors.cgImage,
                       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        try png.write(to: output.appendingPathComponent("palette-" + appearance + ".png"))
                    }
                }
                let content = MatrixScene(name: name, controller: controller(for: name), busy: name.hasPrefix("call-"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.cmPreviewReduceTransparency, reduced)
                    .environment(\.cmPreviewReduceMotion, true)
                    .environment(\.cmReviewRendering, true)
                    .environment(\.cmReferenceDate, now)
                let renderer = ImageRenderer(content: content)
                renderer.proposedSize = ProposedViewSize(width: name.hasPrefix("cleanup-") ? 712 : CMLayout.popoverWidth + 32, height: nil)
                renderer.scale = 2
                guard let image = renderer.cgImage else { throw TranscriptionFailure("Preview render failed for \(name)") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TranscriptionFailure("Preview PNG failed") }
                let filename = name + "-" + appearance + ".png"
                try png.write(to: output.appendingPathComponent(filename), options: .atomic)
                entries.append(["state": name, "appearance": appearance, "file": filename,
                                "width": String(image.width), "height": String(image.height),
                                "popoverWidth": String(Int(CMLayout.popoverWidth * renderer.scale))])
            }
        }
        try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("matrix.json"))
        print("Exported \(entries.count) ImageRenderer PNGs to \(output.path)")
    }
}

private struct MatrixBrowser: View {
    @State private var surface = "Popover"
    @State private var systemPopover = false
    @State private var cleanupSheet = false
    @State private var name = "call-same-cause"
    @State private var appearance = "dark"
    @State private var reduceMotion = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Screen", selection: $surface) {
                    Text("Popover").tag("Popover")
                    Text("Settings").tag("Settings")
                }
                Picker("State", selection: $name) { ForEach(DesignPreview.states, id: \.self) { Text($0) } }
                Picker("Appearance", selection: $appearance) { ForEach(DesignPreview.appearances, id: \.self) { Text($0) } }
                Toggle("Reduce motion", isOn: $reduceMotion)
            }.padding().background(Color(nsColor: .windowBackgroundColor))
            Group {
                if surface == "Settings" { HelperSettings(controller: DesignPreview.controller(for: name)) }
                else { MatrixScene(name: name, controller: DesignPreview.controller(for: name), busy: name.hasPrefix("call-")) }
            }
                .id(name + appearance)
                .environment(\.colorScheme, appearance.contains("dark") ? .dark : .light)
                .environment(\.cmPreviewReduceTransparency, appearance.hasPrefix("reduced"))
                .environment(\.cmPreviewReduceMotion, reduceMotion)
                .environment(\.cmReferenceDate, DesignPreview.now)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Native popover") { systemPopover = true }
                    .popover(isPresented: $systemPopover, arrowEdge: .top) {
                        HelperPopover(controller: DesignPreview.controller(for: name))
                            .environment(\.colorScheme, appearance.contains("dark") ? .dark : .light)
                            .environment(\.cmReferenceDate, DesignPreview.now)
                            .environment(\.cmPreviewReduceTransparency, appearance.hasPrefix("reduced"))
                            .environment(\.cmPreviewReduceMotion, reduceMotion)
                    }
                Button("Settings window") { DesignPreview.controller(for: name).showSettings() }
                Button("Cleanup sheet") { cleanupSheet = true }
            }
        }
        .sheet(isPresented: $cleanupSheet) {
            CleanupPreview(hasItems: name == "cleanup-items", onClose: { cleanupSheet = false })
                .frame(width: 680, height: name == "cleanup-items" ? 480 : 340)
        }
        .onChange(of: appearance, initial: true) { _, value in
            NSApp.appearance = NSAppearance(named: value.contains("dark") ? .darkAqua : .aqua)
        }
    }
}

private struct MatrixScene: View {
    let name: String
    let controller: MenuBarController
    let busy: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.cmReviewRendering) private var reviewRendering
    var body: some View {
        ZStack {
            if busy { VideoBackdrop(dark: scheme == .dark) }
            else { Color(nsColor: .windowBackgroundColor) }
            VStack(spacing: 12) {
                Text("ClawMinutes · \(name.replacingOccurrences(of: "-", with: " "))").font(.caption).padding(6).background(Color(nsColor: .windowBackgroundColor))
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                if name.hasPrefix("cleanup-") { CleanupPreview(hasItems: name == "cleanup-items") }
                else {
                    // A matrix isn't an NSPopover. Its layout-only export needs a
                    // surrogate backing. Use Native popover to inspect system glass.
                    if reviewRendering { HelperPopover(controller: controller).background(Color(nsColor: .windowBackgroundColor)) }
                    else { HelperPopover(controller: controller).background(.regularMaterial, in: .rect(cornerRadius: 16)) }
                }
                Text("Synthetic layout · inspect native controls in the preview app").font(.caption).fixedSize(horizontal: false, vertical: true).padding(6).background(Color(nsColor: .windowBackgroundColor))
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            }.padding(16)
        }.frame(width: name.hasPrefix("cleanup-") ? 712 : CMLayout.popoverWidth + 32)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CleanupPreview: View {
    let hasItems: Bool
    let onClose: () -> Void
    init(hasItems: Bool, onClose: @escaping () -> Void = {}) {
        self.hasItems = hasItems
        self.onClose = onClose
    }
    private var previewRows: [AudioCleanup.Row] {
        // Display-only synthetic plan. Preview buttons never call deletion.
        let identity = AudioRetention.FileIdentity(device: 0, inode: 1, bytes: 180_000_000, modified: 0, modifiedNS: 0, changed: 0, changedNS: 0)
        let plan = AudioRetention.Plan(directory: "/synthetic/saved", directoryIdentity: "fixture", exportDirectory: "/synthetic/notes", exportIdentity: "fixture", sessionID: "fixture", evidence: [:], tracks: [.init(name: "mic.caf", identity: identity, seconds: 900)], missing: [])
        return [.init(meeting: DesignPreview.meeting("Weekly planning", stage: .exported), plan: plan, issue: nil),
                .init(meeting: DesignPreview.meeting("Portfolio planning", cause: .unconfirmed), plan: nil, issue: "Synthetic unconfirmed receipt")]
    }
    var body: some View {
        AudioCleanupView(controller: DesignPreview.controller(for: "idle"), previewRows: hasItems ? previewRows : [], onClose: onClose)
            .frame(width: 680)
    }

}

/// Synthetic bright/dark conferencing mosaic. It contains no screen capture.
private struct VideoBackdrop: View {
    let dark: Bool
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<4) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3) { column in
                        ZStack {
                            Rectangle().fill(Color(hue: Double(row * 3 + column) / 12, saturation: 0.65, brightness: dark ? 0.22 : 0.98))
                            Image(systemName: "person.crop.rectangle.fill").resizable().scaledToFit().padding(25)
                                .foregroundStyle(dark ? Color.white.opacity(0.35) : Color.black.opacity(0.35))
                            VStack { Spacer(); Text("Video tile \(row * 3 + column + 1)").font(.title3.bold()).padding() }
                        }
                    }
                }
            }
        }
    }
}
#endif
