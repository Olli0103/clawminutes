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
            HStack(spacing: 14) {
                Image(systemName: "externaldrive").font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint).frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete old audio").font(.title2.weight(.semibold))
                    Text("Keep your notes. Free up recording space.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Audio from verified saved meetings is selected automatically. Notes and transcripts stay. Unfinished or unverified recordings are kept for recovery.")
                .font(.callout).foregroundStyle(.secondary)
            if reviewing { ProgressView("Checking saved text and audio coverage…") }
            if !reviewing {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedPlans.isEmpty ? (!failed.isEmpty ? "Some audio needs another check" : completed.isEmpty ? "No verified audio selected" : "Audio cleanup finished") : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " ready to delete")
                        .font(.title2.weight(.semibold))
                    Text("\(selectedPlans.count) meetings selected · \(rows.filter { ($0.plan == nil || failed.contains($0.id)) && !$0.alreadyRemoved && !completed.contains($0.id) }.count) kept for recovery")
                        .font(.caption).foregroundStyle(.secondary)
                }.helperCard(tint: .accentColor)
            }
            List(rows) { row in rowView(row) }.listStyle(.inset).scrollContentBackground(.hidden)
            if let reviewError { Text(reviewError).font(.callout).foregroundStyle(.orange) }
            if rows.isEmpty && !reviewing { Text("No recordings are available in this selection.").foregroundStyle(.secondary) }
            Text("Audio deletion is permanent. Playback and transcription from these tracks will no longer be available.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if deleting { ProgressView().controlSize(.small); Text("Verifying and deleting…").font(.caption) }
                if !deleting && !reviewing {
                    Button("Check again") {
                        reviewing = true; selected.removeAll(); failed.removeAll(); reviewError = nil
                        outcomes = outcomes.filter { completed.contains($0.key) }; reviewRevision += 1
                    }.helperButton()
                }
                Spacer()
                Button(completed.isEmpty ? "Cancel" : "Done") { cancelled = true; onClose() }
                    .helperButton().keyboardShortcut(.cancelAction).disabled(deleting)
                Button("Delete audio…", role: .destructive) { confirmationPresented = true }.helperButton(prominent: true).tint(.red)
                    .disabled(reviewing || deleting || selectedPlans.isEmpty)
            }.controlSize(.large)
        }.padding(24).frame(width: 650, height: 560).helperPanel()
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
    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { value in
            if value { _ = selected.insert(id) } else { _ = selected.remove(id) }
        })
    }
    private func rowView(_ row: AudioCleanup.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Toggle(isOn: selectionBinding(row.id)) { Text(row.meeting.title).font(.headline) }
                    .toggleStyle(.checkbox).disabled(deleting || row.plan == nil || completed.contains(row.id) || failed.contains(row.id))
                Spacer()
                if completed.contains(row.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Audio removed") }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let started = row.meeting.started { Text(started, format: .dateTime).foregroundStyle(.secondary) }
                if completed.contains(row.id) {
                    Text("Audio removed. Notes and transcript kept.").foregroundStyle(.secondary)
                } else if let plan = row.plan {
                    Text("\(plan.remaining.count) audio tracks · " + ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))
                    if !plan.missing.isEmpty { Text("Interrupted cleanup can resume after fresh verification.") }
                    DisclosureGroup("Audio files") {
                        ForEach(plan.remaining, id: \.name) { track in
                            Text(track.name + " · " + ByteCountFormatter.string(fromByteCount: track.identity.bytes, countStyle: .file))
                        }
                        Text(plan.directory).textSelection(.enabled)
                    }
                }
                if let issue = outcomes[row.id] ?? row.issue {
                    if failed.contains(row.id) {
                        Text("Cleanup stopped for this meeting. Some audio may already be removed. Choose Check again before retrying.").foregroundStyle(.orange)
                    }
                    if row.plan == nil && !row.alreadyRemoved {
                        Text(AudioCleanup.explanation(row)).foregroundStyle(.secondary)
                        Button("Review meeting") { controller.showMeetingDetails(row.meeting) }.helperButton().controlSize(.small).disabled(deleting)
                    }
                    DisclosureGroup("Technical details") {
                        Text(issue).textSelection(.enabled)
                    }.foregroundStyle(.secondary)
                }
            }.font(.caption).padding(.leading, 22)
        }.padding(.vertical, 4)
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
