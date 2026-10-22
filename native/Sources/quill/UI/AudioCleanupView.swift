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
    init(controller: MenuBarController, meetings: [RecentMeeting], onClose: @escaping () -> Void = {}, onBusyChange: @escaping (Bool) -> Void = { _ in }) {
        self.controller = controller; self.meetings = meetings
        self.onClose = onClose; self.onBusyChange = onBusyChange
    }
    #if DEBUG
    private var fixtureRows: [AudioCleanup.Row]?
    init(controller: MenuBarController, previewRows: [AudioCleanup.Row], onClose: @escaping () -> Void = {}) {
        self.init(controller: controller, meetings: [], onClose: onClose)
        fixtureRows = previewRows
        _rows = State(initialValue: previewRows)
        _selected = State(initialValue: AudioCleanup.defaultSelection(previewRows))
        _reviewing = State(initialValue: false)
    }
    #endif
    private var keptCount: Int {
        rows.filter { ($0.plan == nil || failed.contains($0.id)) && !$0.alreadyRemoved && !completed.contains($0.id) }.count
    }
    private var hasEligibleAudio: Bool {
        rows.contains { $0.plan != nil && !completed.contains($0.id) && !failed.contains($0.id) }
    }
    var selectedPlans: [AudioRetention.Plan] { rows.filter { selected.contains($0.id) && !completed.contains($0.id) }.compactMap(\.plan) }
    var bytes: Int64 { selectedPlans.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete old audio").font(.title2.weight(.semibold))
            Text("Keep your notes and transcripts. Remove audio you no longer need.")
                .font(.callout).foregroundStyle(CMTheme.secondary)
            if reviewing { ProgressView("Checking saved text and audio coverage…") }
            if !reviewing && !rows.isEmpty {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " selected · \(keptCount) kept for recovery")
                    .font(.headline)
            }
            if rows.isEmpty && !reviewing {
                ContentUnavailableView("No old audio to delete", systemImage: "externaldrive.badge.checkmark", description: Text("Your notes and transcripts are kept."))
                    .frame(maxWidth: .infinity)
            } else {
                CleanupTable(rows: rows, selected: $selected, completed: completed, failed: failed, deleting: deleting,
                             review: controller.showMeetingDetails)
            }
            if let reviewError { Text(reviewError).font(.callout).foregroundStyle(.primary) }

            Spacer(minLength: 0)
            HStack {
                if deleting { ProgressView().controlSize(.small); Text("Verifying and deleting…").font(.caption) }
                if !deleting && !reviewing && !rows.isEmpty {
                    Button("Check again") {
                        reviewing = true; selected.removeAll(); failed.removeAll(); reviewError = nil
                        outcomes = outcomes.filter { completed.contains($0.key) }; reviewRevision += 1
                    }.buttonStyle(.bordered)
                }
                Spacer()
                Button(completed.isEmpty ? "Cancel" : "Done") { cancelled = true; onClose() }
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction).disabled(deleting)
                if reviewing || hasEligibleAudio {
                    Button("Delete audio…", role: .destructive) { confirmationPresented = true }.buttonStyle(.borderedProminent).tint(.red)
                        .disabled(reviewing || deleting || selectedPlans.isEmpty)
                }

            }.controlSize(.regular)
        }.padding(20).frame(minWidth: 650, minHeight: rows.isEmpty && !reviewing ? 300 : 480, alignment: .topLeading).helperPanel()
            .alert("Delete \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of recording audio?", isPresented: $confirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Delete audio", role: .destructive, action: delete)
            } message: {
                Text("Permanently delete audio from \(selectedPlans.count) selected meetings. Your notes and transcripts stay. Playback and retranscription from these tracks will no longer be available. Recordings kept for recovery are not included.")
            }
            .task(id: reviewRevision) {
                #if DEBUG
                if let fixtureRows {
                    rows = fixtureRows; selected = AudioCleanup.defaultSelection(fixtureRows); reviewing = false
                    return
                }
                #endif
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
        #if DEBUG
        guard fixtureRows == nil else { return } // Review controls can never delete fixture or real files.
        #endif
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
