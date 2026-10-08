import AppKit
import SwiftUI

@MainActor
struct LegacyReceiptView: View {
    @ObservedObject var controller: MenuBarController
    let meeting: RecentMeeting
    var initialRoot: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var plan: LegacyReceiptReconciliation.Plan?
    @State private var chosenRoot: URL?
    @State private var reviewing = true
    @State private var busy = false
    @State private var issue: String?
    @State private var result: LegacyReceiptReconciliation.Result?
    @State private var reviewRevision = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify saved meeting").font(.title2.weight(.semibold))
            Text(meeting.title).font(.headline)
            Text("Compare this transcript and meeting details with the completed Gateway archive. Verification does not create Gateway notes, change its archive or call a model.")
                .font(.callout).foregroundStyle(.secondary)
            Text("A match repairs this Mac's receipt and notes location. Existing edits and audio stay. The original receipt is kept as evidence.")
                .font(.callout).foregroundStyle(.secondary)
            if reviewing { ProgressView("Reviewing local files…") }
            if let plan {
                Text("Transcript utterances: \(plan.utterances). Text and meeting details will be sent for comparison. No audio is sent.")
                Text("Local notes folder: " + plan.exportRoot.path).font(.caption).textSelection(.enabled)
                DisclosureGroup("Archive identity") { Text(plan.sessionID).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if let issue { Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let result { Text(result.detail).foregroundStyle(result.exported ? Color.primary : Color.orange).textSelection(.enabled) }
            if result == nil {
                Button("Choose original notes folder…") { chooseFolder() }.disabled(busy)
                Text("If the default folder changed, select the original root above the year/month folders. This leaves the future default unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Verifying Gateway readback…").font(.caption) }
                if !busy && !reviewing && result == nil { Button("Review again") { issue = nil; reviewing = true; reviewRevision += 1 } }
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.disabled(busy)
                if result == nil {
                    Button("Verify on Gateway", action: verify).buttonStyle(.borderedProminent).disabled(busy || reviewing || plan == nil)
                }
            }
        }.padding(24).frame(width: 560, height: 470).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(busy)
            .task(id: "\(reviewRevision):\(chosenRoot?.path ?? "")") {
                plan = nil
                do {
                    let directory = meeting.directory, root = chosenRoot ?? initialRoot ?? MeetingNotesSettings.folder
                    let work = Task.detached { try LegacyReceiptReconciliation.prepare(directory, notesRoot: root) }
                    let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation(); plan = value; reviewing = false
                } catch { issue = LegacyReceiptReconciliation.detail(error); reviewing = false }
            }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the original notes root above the year/month folders. The future default will not change."
        panel.prompt = "Review folder"
        panel.begin { response in
            guard response == .OK, let root = panel.url else { return }
            issue = nil; reviewing = true; chosenRoot = root
        }
    }
    private func verify() {
        guard let plan, !busy else { return }
        busy = true; issue = nil
        Task {
            do {
                result = try await LegacyReceiptReconciliation.apply(plan)
            } catch { issue = LegacyReceiptReconciliation.detail(error); self.plan = nil }
            await controller.refreshLocalMeetings()
            busy = false
        }
    }
}
