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
    @State private var confirmed = false
    @State private var cancelled = false
    @State private var reviewRevision = 0
    var onClose: () -> Void = {}
    var onBusyChange: (Bool) -> Void = { _ in }
    var selectedPlans: [AudioRetention.Plan] { rows.filter { selected.contains($0.id) && !completed.contains($0.id) }.compactMap(\.plan) }
    var bytes: Int64 { selectedPlans.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review recorded audio").font(.title2.weight(.semibold))
            Text("Only verified meetings are eligible. Notes and transcripts stay. Deleting audio prevents playback, re-transcription and further voice analysis.")
                .font(.callout).foregroundStyle(.secondary)
            Text("This review does not change the setting for future recordings.").font(.caption).foregroundStyle(.secondary)
            if reviewing { ProgressView("Checking saved text and audio coverage…") }
            List(rows) { row in rowView(row) }.listStyle(.inset)
            if rows.isEmpty && !reviewing { Text("No recordings are available in this selection.").foregroundStyle(.secondary) }
            Text("\(selectedPlans.count) meetings selected · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            Toggle("I understand that the selected audio will be permanently deleted.", isOn: $confirmed)
                .disabled(reviewing || deleting || selectedPlans.isEmpty)
            HStack {
                if deleting { ProgressView().controlSize(.small); Text("Verifying and deleting…").font(.caption) }
                if !deleting && !reviewing {
                    Button("Review again") {
                        reviewing = true; confirmed = false; selected.removeAll(); failed.removeAll()
                        outcomes = outcomes.filter { completed.contains($0.key) }; reviewRevision += 1
                    }
                }
                Spacer()
                Button(completed.isEmpty ? "Cancel" : "Done") { cancelled = true; onClose() }.disabled(deleting)
                Button("Delete selected audio", role: .destructive, action: delete).buttonStyle(.borderedProminent).tint(.red)
                    .disabled(reviewing || deleting || !confirmed || selectedPlans.isEmpty)
            }
        }.padding(22).frame(width: 650, height: 560).background(Color(nsColor: .windowBackgroundColor))
            .task(id: reviewRevision) {
                do {
                    let list = meetings
                    let work = Task.detached { try AudioCleanup.review(list) }
                    let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation()
                    rows = value; reviewing = false
                } catch { reviewing = false }
            }
            .onDisappear { cancelled = true }
    }
    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { value in
            if value { _ = selected.insert(id) } else { _ = selected.remove(id) }
            confirmed = false
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
                if let plan = row.plan {
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
                    Text(issue).foregroundStyle(completed.contains(row.id) || row.alreadyRemoved ? Color.secondary : Color.orange)
                }
            }.font(.caption).padding(.leading, 22)
        }.padding(.vertical, 4)
    }
    private func delete() {
        guard confirmed, !deleting else { return }
        let selection = rows.filter { selected.contains($0.id) && !completed.contains($0.id) && $0.plan != nil }
        deleting = true; confirmed = false; onBusyChange(true)
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
