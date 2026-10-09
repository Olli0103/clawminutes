import SwiftUI

@MainActor struct NotesRecoveryEditor: View {
    @ObservedObject var controller: MenuBarController
    let meeting: RecentMeeting
    let kind: NotesRecovery.Kind
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var prepared = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            Text(kind == .retryAI ? "Try AI notes again?" : "Save transcript-only notes?").font(.title2.weight(.semibold))
            Text(meeting.title).font(.headline).lineLimit(2)
            if kind == .retryAI {
                Text("This requests one more attempt using your Gateway's current notes model. It may incur model charges. The existing three-attempt limit stays in place.")
            } else {
                Text("Save the transcript and meeting information without another AI generation. If AI notes were already saved and their reply was lost, the Gateway returns those notes instead.")
            }
            Text("The original transcript and prior failure history are preserved. Nothing starts recording or uploads audio.")
                .font(.callout).foregroundStyle(.secondary)
            if prepared {
                Label("Recovery queued", systemImage: "checkmark.circle").foregroundStyle(.green)
                Text("Check the meeting's status for the result. Connection failures can wait safely on this Mac.").font(.callout)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(prepared ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if !prepared {
                    Button(saving ? "Preparing…" : kind == .retryAI ? "Request one attempt" : "Save transcript-only", action: prepare)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
                }
            }
        }.padding(24).frame(width: 480, height: 340)
            .foregroundStyle(.primary).background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled(saving)
    }
    private func prepare() {
        guard !saving, !prepared else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                _ = try await Task.detached { try NotesRecovery.prepare(meeting.directory, kind: kind) }.value
                prepared = true
                await controller.queuePreparedText()
            } catch {
                self.error = (error as? DeliveryFailure)?.detail ?? (error as? TranscriptionFailure)?.description
                    ?? "The recovery request could not be prepared. Original files and attempt limits are preserved."
            }
        }
    }
}
