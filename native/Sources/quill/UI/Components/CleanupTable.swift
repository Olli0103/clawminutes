import SwiftUI

/// Selection for deletion stays separate from table focus and inspection.
/// Only the existing verified AudioRetention.Plan can enable a checkbox.
struct CleanupTable: View {
    @Environment(\.cmReviewRendering) private var reviewRendering
    let rows: [AudioCleanup.Row]
    @Binding var selected: Set<String>
    let completed: Set<String>
    let failed: Set<String>
    let deleting: Bool
    var review: (RecentMeeting) -> Void
    @State private var inspectedID: String?
    @State private var showInspector = false
    var body: some View {
        if reviewRendering {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow { Text("Delete").bold(); Text("Meeting").bold(); Text("Audio").bold(); Text("Status").bold() }
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Image(systemName: selected.contains(row.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(row.plan == nil ? CMTheme.secondary : CMTheme.accent)
                        VStack(alignment: .leading) { Text(row.meeting.title); Text(MeetingDate.string(row.meeting.started)).font(.caption) }
                        Text(row.plan.map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? "Kept")
                        if row.plan == nil {
                            VStack(alignment: .leading) {
                                Text(row.meeting.canVerifyLegacyReceipt ? "Notes not confirmed" : "Audio needs review").font(.caption)
                                Button("Review") { review(row.meeting) }.cmLinkButton()
                            }
                        } else { Text("Ready to delete") }
                    }
                }
            }
        } else { nativeTable }
    }
    private var nativeTable: some View {
        Table(rows, selection: $inspectedID) {
            TableColumn("Delete") { row in
                Toggle("Delete audio for \(row.meeting.title)", isOn: Binding(get: { selected.contains(row.id) }, set: { value in
                    if value { selected.insert(row.id) } else { selected.remove(row.id) }
                })).labelsHidden().toggleStyle(.checkbox)
                    .disabled(deleting || row.plan == nil || completed.contains(row.id) || failed.contains(row.id))
                    .help(row.plan == nil ? "Kept for recovery" : "Select audio to delete")
            }.width(44)
            TableColumn("Meeting") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.meeting.title).lineLimit(1)
                    Text(MeetingDate.string(row.meeting.started)).font(.caption)
                }
            }.width(min: 150, ideal: 220)
            TableColumn("Audio") { row in
                Text(row.plan.map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? "Kept")
            }.width(75)
            TableColumn("Status") { row in
                if completed.contains(row.id) || row.alreadyRemoved { Label("Removed", systemImage: "checkmark.circle") }
                else if failed.contains(row.id) { Text("Check again") }
                else if row.plan != nil { Text("Ready to delete") }
                else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.meeting.canVerifyLegacyReceipt ? "Notes not confirmed" : "Audio needs review")
                            .font(.caption).foregroundStyle(CMTheme.secondary)
                        Button("Review") { review(row.meeting) }.disabled(deleting)
                    }
                }
            }.width(min: 100, ideal: 125)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Review meeting") { review(row.meeting) }
                Button("Technical details") { inspectedID = id; showInspector = true }
            }
        }
        .inspector(isPresented: $showInspector) {
            if let row = rows.first(where: { $0.id == inspectedID }) {
                Form {
                    Section("Technical details") {
                        Text(row.issue ?? "Saved text and audio coverage verified.").textSelection(.enabled)
                        if let plan = row.plan { Text(plan.directory).textSelection(.enabled) }
                    }
                }.formStyle(.grouped).inspectorColumnWidth(260)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { showInspector.toggle() } label: { Image(systemName: "info.circle") }
                .help("Show technical details for selected meeting").accessibilityLabel("Show technical details")
                .disabled(inspectedID == nil).buttonStyle(.borderless).padding(8)
        }
    }
}
