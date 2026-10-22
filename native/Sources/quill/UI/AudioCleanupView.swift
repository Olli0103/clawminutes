import AppKit
import SwiftUI

@MainActor
struct AudioCleanupView: View {
    @ObservedObject var controller: MenuBarController
    let meetings: [RecentMeeting]
    @State private var rows: [AudioCleanup.Row] = []
    @State private var selected = Set<String>()
    @State private var outcomes: [String: String] = [:]
    @State private var completed = Set<String>()
    @State private var failed = Set<String>()
    @State private var reviewing = true
    @State private var deleting = false
    @State private var confirmationPresented = false
    @State private var cancelled = false
    @State private var reviewRevision = 0
    @State private var reviewError: String?
    var onClose: () -> Void = {}
    var onBusyChange: (Bool) -> Void = { _ in }
    var selectedPlans: [AudioRetention.Plan] { rows.filter { selected.contains($0.id) && !completed.contains($0.id) }.compactMap(\.plan) }
    var bytes: Int64 { selectedPlans.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete old audio").font(.title2.weight(.semibold))
            Text("Audio from verified saved meetings is selected automatically. Notes and transcripts stay. Unfinished or unverified recordings are kept for recovery.")
                .font(.callout).foregroundStyle(.primary)
            if reviewing { ProgressView("Checking saved text and audio coverage…") }
            if !reviewing {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedPlans.isEmpty ? (!failed.isEmpty ? "Some audio needs another check" : completed.isEmpty ? "No verified audio selected" : "Audio cleanup finished") : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " ready to delete")
                        .font(.title2.weight(.semibold))
                    Text("\(selectedPlans.count) meetings selected · \(rows.filter { ($0.plan == nil || failed.contains($0.id)) && !$0.alreadyRemoved && !completed.contains($0.id) }.count) kept for recovery")
                        .font(.caption).foregroundStyle(.primary)
                }.helperCard(tint: .accentColor)
            }
            if rows.isEmpty && !reviewing {
                ContentUnavailableView("No old audio to delete", systemImage: "externaldrive.badge.checkmark", description: Text("Your notes and transcripts are kept."))
            } else {
                CleanupTable(rows: rows, selected: $selected, completed: completed, failed: failed, deleting: deleting,
                             review: controller.showMeetingDetails)
            }
            if let reviewError { Text(reviewError).font(.callout).foregroundStyle(.primary) }

            Text("Audio deletion is permanent. Playback and transcription from these tracks will no longer be available.")
                .font(.caption).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if deleting { ProgressView().controlSize(.small); Text("Verifying and deleting…").font(.caption) }
                if !deleting && !reviewing {
                    Button("Check again") {
                        reviewing = true; selected.removeAll(); failed.removeAll(); reviewError = nil
                        outcomes = outcomes.filter { completed.contains($0.key) }; reviewRevision += 1
                    }.buttonStyle(.bordered)
                }
                Spacer()
                Button(completed.isEmpty ? "Cancel" : "Done") { cancelled = true; onClose() }
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction).disabled(deleting)
                Button("Delete audio…", role: .destructive) { confirmationPresented = true }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(reviewing || deleting || selectedPlans.isEmpty)
            }.controlSize(.regular).padding(8).cmGlass()
        }.padding(20).frame(minWidth: 650, minHeight: 480).helperPanel()
            .alert("Delete \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of recording audio?", isPresented: $confirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Delete audio", role: .destructive, action: delete)
            } message: {
                Text("Permanently delete audio from \(selectedPlans.count) selected meetings. Your notes and transcripts stay. Recordings kept for recovery are not included.")
            }
            .task(id: reviewRevision) {
                do {
                    let list = meetings
                    let work = Task.detached { try AudioCleanup.review(list) }
                    let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation()
                    rows = value; selected = AudioCleanup.defaultSelection(value).subtracting(completed); reviewing = false
                } catch is CancellationError { /* Closing the window cannot delete audio. */ }
                catch { reviewing = false; reviewError = "The recordings could not be checked. Close this window and try again." }
            }
            .onDisappear { cancelled = true }
    }
    private func delete() {
        guard !reviewing, !deleting, !selectedPlans.isEmpty else { return }
        let selection = rows.filter { selected.contains($0.id) && !completed.contains($0.id) && $0.plan != nil }
        deleting = true; onBusyChange(true)
        Task {
            for row in selection {
                guard !cancelled, let plan = row.plan else { break }
                do {
                    let count = try await Task.detached { try AudioCleanup.execute(plan) }.value
                    completed.insert(row.id); selected.remove(row.id)
                    outcomes[row.id] = "Removed \(count) audio tracks. Notes and transcripts remain."
                } catch {
                    outcomes[row.id] = "Cleanup stopped. Some tracks may already be removed. " + AudioCleanup.detail(error)
                    failed.insert(row.id); selected.remove(row.id)
                }
            }
            deleting = false; onBusyChange(false)
            await controller.refreshLocalMeetings(); controller.checkStorage()
        }
    }
}
