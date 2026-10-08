import AppKit
import SwiftUI

/// Shows consent beside the user's call without activating the helper or
/// entering a nested modal event loop. Closing the panel means Dismiss.
@MainActor
final class MeetingConsentPanel: NSWindowController, NSWindowDelegate {
    private var response: CheckedContinuation<Bool, Never>?
    private var resolved = false
    init(title: String? = nil, fixture: Bool = false, appearance: NSAppearance? = nil) {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ClawMinutes"
        panel.appearance = appearance
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        let copy = MeetingConsentPrompt.make(fixture: fixture, title: title)
        panel.contentView = NSHostingView(rootView: ConsentCard(title: title,
            explanation: copy.informativeText, accept: { [weak self] in self?.dismiss(start: true) },
            dismiss: { [weak self] in self?.dismiss(start: false) }))
        if let view = panel.contentView { panel.setContentSize(view.fittingSize) }
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func present() async -> Bool {
        guard !resolved, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                response = continuation
                if resolved || Task.isCancelled { dismiss(start: false); return }
                window?.orderFrontRegardless()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dismiss(start: false) }
        }
    }
    func dismiss(start: Bool) {
        resolved = true
        window?.orderOut(nil)
        let completion = response
        response = nil
        completion?.resume(returning: start)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(start: false); return true }
}

private struct ConsentCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String?
    let explanation: String
    let accept: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: HelperAppIcon.image(appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua))).resizable().scaledToFit().frame(width: 54, height: 54)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcribe this meeting?").font(.title2.weight(.semibold))
                    Text(title ?? "Teams call detected").font(.headline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text(explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Dismiss", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: accept) {
                    Text("Start recording").foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule())
                }.keyboardShortcut(.defaultAction).buttonStyle(.plain)
            }.controlSize(.large)
            Text("Dismiss keeps audio off. You can start later from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 450, height: 320)
            .foregroundStyle(.primary)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
