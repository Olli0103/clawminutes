import AppKit
import SwiftUI

@MainActor
struct LegacyReceiptView: View {
    @ObservedObject var controller: MenuBarController
    let meeting: RecentMeeting
    var initialRoot: URL? = nil
    var automaticallyCheck = false
    @Environment(\.dismiss) private var dismiss
    @State private var plan: LegacyReceiptReconciliation.Plan?
    @State private var chosenRoot: URL?
    @State private var reviewing = true
    @State private var busy = false
    @State private var issue: String?
    @State private var failureCode: String?
    @State private var result: LegacyReceiptReconciliation.Result?
    @State private var reviewRevision = 0
    @State private var automaticStarted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Find your saved notes", systemImage: "doc.text.magnifyingglass").font(.title2.weight(.semibold))
            Text(meeting.title).font(.headline)
            Text("Look for this meeting on your Gateway and restore the matching notes on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Text("This checks the transcript and meeting details only. It does not upload audio or generate new AI notes. Your existing edits are kept.")
                .font(.callout).foregroundStyle(.secondary)
            if reviewing { ProgressView("Reviewing local files…") }
            if let plan {
                DisclosureGroup("Comparison details") {
                    Text("\(plan.utterances) transcript entries")
                    Text("Notes folder: " + plan.exportRoot.path).textSelection(.enabled)
                    Text(plan.sessionID).font(.caption.monospaced()).textSelection(.enabled)
                }.font(.caption)
            }
            if let issue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failureMessage).font(.callout)
                    if failureCode == "sign_in_required" {
                        Button("Sign in to Gateway", action: controller.connectGateway).helperButton(prominent: true)
                    } else if ["network_unavailable", "gateway_unavailable", "plugin_unavailable"].contains(failureCode ?? "") {
                        Button("Check connection", action: controller.recheckGateway).helperButton(prominent: true).disabled(controller.gatewayOperation)
                    } else {
                        Button("Save diagnostic report…", action: controller.saveDiagnostics).helperButton()
                    }
                    DisclosureGroup("Technical details") { Text(issue).font(.caption).textSelection(.enabled) }
                }.helperCard(tint: .orange)
            }
            if let result {
                Label(result.exported ? "Your notes are ready" : "Notes found on your Gateway", systemImage: result.exported ? "checkmark.circle.fill" : "doc.text")
                    .font(.headline).foregroundStyle(result.exported ? Color.green : Color.primary)
                Text(result.exported ? "The matching notes are saved on this Mac. Your existing edits and audio were kept." : "The notes could not be copied to this Mac. Open the meeting to retry saving its local copy.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(result.exported ? "Open notes" : "Review local save") {
                    dismiss()
                    if let updated = controller.recentMeetings.first(where: { $0.id == meeting.id }) {
                        if result.exported { controller.openMeeting(updated) }
                        else { controller.showMeetingDetails(updated) }
                    }
                }.helperButton(prominent: true)
            }
            if result == nil {
                DisclosureGroup("Changed your notes folder?") {
                    Text("Choose the original notes folder above the year/month folders. Your default for future meetings stays the same.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose original notes folder…") { chooseFolder() }.helperButton().disabled(busy)
                }
            }
            Spacer()
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Checking saved meeting…").font(.caption) }
                if !busy && !reviewing && result == nil {
                    Button("Try again") { issue = nil; reviewing = true; automaticStarted = false; reviewRevision += 1 }.helperButton()
                }
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.helperButton().keyboardShortcut(.cancelAction).disabled(busy)
                if result == nil {
                    Button("Find my notes", action: verify).helperButton(prominent: true).disabled(busy || reviewing || plan == nil)
                }
            }
        }.padding(24).frame(width: 560, height: 470).helperPanel().interactiveDismissDisabled(busy)
            .task(id: "\(reviewRevision):\(chosenRoot?.path ?? "")") {
                plan = nil
                do {
                    let directory = meeting.directory, root = chosenRoot ?? initialRoot ?? MeetingNotesSettings.folder
                    let work = Task.detached { try LegacyReceiptReconciliation.prepare(directory, notesRoot: root) }
                    let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation(); plan = value; reviewing = false
                    if automaticallyCheck && !automaticStarted {
                        automaticStarted = true; verify()
                    }
                } catch { issue = LegacyReceiptReconciliation.detail(error); failureCode = (error as? DeliveryFailure)?.code; reviewing = false }
            }
    }
    private var failureMessage: String {
        switch failureCode {
        case "sign_in_required": return "Sign in to your Gateway, then try finding these notes again."
        case "archive_not_verified": return "No matching saved meeting was found on the Gateway. Your transcript is still on this Mac. Save a diagnostic report to investigate the earlier save."
        case "revision_conflict": return "The saved meeting contains different text or details. Both versions have been kept. Save a diagnostic report before changing this meeting."
        case "network_unavailable", "gateway_unavailable", "plugin_unavailable": return "The Gateway could not be reached or could not verify this meeting. Check your connection and try again."
        default: return "These notes could not be restored safely. If you moved your notes, choose their original folder below. Otherwise, save a diagnostic report to investigate."
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
            } catch { issue = LegacyReceiptReconciliation.detail(error); failureCode = DeliveryFailure.classify(error).code; self.plan = nil }
            await controller.refreshLocalMeetings()
            busy = false
        }
    }
}
