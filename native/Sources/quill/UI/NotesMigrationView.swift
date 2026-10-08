import AppKit
import SwiftUI

@MainActor
struct NotesMigrationView: View {
    @ObservedObject var controller: MenuBarController
    let meetings: [RecentMeeting]
    let destination: URL
    @State private var rows: [NotesMigration.Row] = []
    @State private var selected = Set<String>()
    @State private var outcomes: [String: String] = [:]
    @State private var completed = Set<String>()
    @State private var reviewing = true
    @State private var copying = false
    @State private var confirmed = false
    @State private var cancelled = false
    @State private var reviewRevision = 0
    @State private var failed = Set<String>()
    var onClose: () -> Void = {}
    var onBusyChange: (Bool) -> Void = { _ in }
    var selectedPlans: [NotesMigration.Plan] { rows.filter { selected.contains($0.id) && !completed.contains($0.id) }.compactMap(\.plan) }
    var bytes: Int64 { selectedPlans.reduce(0) { $0 + $1.snapshot.bytes } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy existing notes").font(.title2.weight(.semibold))
            Text("Keeps your edits and the original folders. Selected meetings will open their copied notes. The default for future meetings stays unchanged.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination").font(.caption.weight(.semibold))
                Text(destination.path).font(.caption).textSelection(.enabled).lineLimit(3)
            }
            if reviewing { ProgressView("Checking saved notes…") }
            List(rows) { row in rowView(row) }.listStyle(.inset)
            if rows.isEmpty && !reviewing { Text("No saved notes are available in this selection.").foregroundStyle(.secondary) }
            Text("\(selectedPlans.count) meetings selected · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.callout)
            Toggle("I reviewed these folders and want to copy the selected notes.", isOn: $confirmed).disabled(reviewing || copying || selectedPlans.isEmpty)
            HStack {
                if copying { ProgressView().controlSize(.small); Text("Copying selected notes…").font(.caption) }
                if !copying && !reviewing {
                    Button("Review again") {
                        reviewing = true; confirmed = false; selected.removeAll(); failed.removeAll()
                        outcomes = outcomes.filter { completed.contains($0.key) }; reviewRevision += 1
                    }
                }
                Spacer()
                Button(completed.isEmpty ? "Cancel" : "Done") { cancelled = true; onClose() }.disabled(copying)
                Button("Copy selected notes", action: copy).buttonStyle(.borderedProminent)
                    .disabled(reviewing || copying || !confirmed || selectedPlans.isEmpty)
            }
        }.padding(22).frame(width: 650, height: 560).background(Color(nsColor: .windowBackgroundColor))
            .task(id: reviewRevision) {
                do {
                    let list = meetings, root = destination
                    let work = Task.detached { try NotesMigration.review(list, to: root) }
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
    private func rowView(_ row: NotesMigration.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Toggle(isOn: selectionBinding(row.id)) { Text(row.meeting.title).font(.headline) }
                    .toggleStyle(.checkbox).disabled(copying || row.plan == nil || completed.contains(row.id) || failed.contains(row.id))
                Spacer()
                if completed.contains(row.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Copied")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let plan = row.plan {
                    Text("\(plan.snapshot.files.count) files · " + ByteCountFormatter.string(fromByteCount: plan.snapshot.bytes, countStyle: .file))
                    DisclosureGroup("Folder locations") {
                        Text("From: " + plan.source.path).textSelection(.enabled)
                        Text("To: " + plan.destination.path).textSelection(.enabled)
                    }
                }
                if let issue = outcomes[row.id] ?? row.issue {
                    Text(issue).foregroundStyle(completed.contains(row.id) ? Color.secondary : Color.orange)
                }
            }.font(.caption).padding(.leading, 22)
        }.padding(.vertical, 4)
    }
    private func copy() {
        guard confirmed, !copying else { return }
        let selection = rows.filter { selected.contains($0.id) && !completed.contains($0.id) && $0.plan != nil }
        copying = true; confirmed = false; onBusyChange(true)
        Task {
            for row in selection {
                guard !cancelled, let plan = row.plan else { break }
                do {
                    _ = try await Task.detached { try NotesMigration.execute(plan) }.value
                    completed.insert(row.id); selected.remove(row.id)
                    outcomes[row.id] = "Copied. Original notes are still available."
                } catch {
                    outcomes[row.id] = NotesMigration.detail(error)
                    failed.insert(row.id)
                    selected.remove(row.id)
                }
            }
            copying = false; onBusyChange(false)
            await controller.refreshLocalMeetings()
        }
    }
}
