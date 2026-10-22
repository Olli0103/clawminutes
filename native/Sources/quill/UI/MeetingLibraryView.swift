import SwiftUI

@MainActor
struct MeetingLibraryView: View {
    @ObservedObject var controller: MenuBarController
    @State private var query: String
    @State private var attentionOnly = false
    @State private var selectedMeetingID: String?
    @State private var report: MeetingSearchIndex.Report?
    @State private var searching = false
    @State private var index = MeetingSearchIndex()
    @FocusState private var searchFocused: Bool
    private struct Request: Hashable {
        let query: String
        let attentionOnly: Bool
        let revision: UInt64
    }
    init(controller: MenuBarController, initialQuery: String = "", initialReport: MeetingSearchIndex.Report? = nil) {
        self.controller = controller
        _query = State(initialValue: initialQuery); _report = State(initialValue: initialReport)
    }
    private var matches: [MeetingSearchIndex.Match] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return controller.recentMeetings.filter { !attentionOnly || $0.needsAttention }
                .map { .init(meeting: $0, field: .title, excerpt: nil) }
        }
        return report?.matches ?? []
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = report?.notice, !searching {
                    Text(notice).font(.caption).foregroundStyle(CMTheme.secondary).padding(.horizontal, 12)
                }
                if matches.isEmpty {
                    ContentUnavailableView(searching ? "Searching meetings" : (query.isEmpty ? "No meetings here yet" : "No matching meetings"), systemImage: "doc.text.magnifyingglass")
                } else {
                    List(matches, selection: $selectedMeetingID) { match in
                        VStack(alignment: .leading, spacing: 4) {
                            MeetingRow(meeting: match.meeting, rename: { await controller.renameMeeting(match.meeting, title: $0) })
                            if let excerpt = match.excerpt {
                                Text(match.field.rawValue + ": " + excerpt).font(.caption).foregroundStyle(CMTheme.secondary).lineLimit(2)
                            }
                        }.tag(match.id)
                    }.listStyle(.sidebar)
                }
                HStack {
                    Text(searching ? "Searching…" : "\(matches.count) \(matches.count == 1 ? "meeting" : "meetings")")
                    Spacer()
                    Image(systemName: "lock.shield").help("Search stays on this Mac")
                }.font(.caption).foregroundStyle(CMTheme.secondary).padding(.horizontal, 12).padding(.bottom, 10)
            }.navigationTitle("Meetings").navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            if let selectedMeetingID, controller.recentMeetings.contains(where: { $0.id == selectedMeetingID }) {
                MeetingDetailView(controller: controller, meetingID: selectedMeetingID)
            } else {
                ContentUnavailableView("Choose a meeting", systemImage: "doc.text", description: Text("Review its notes, transcript and next steps."))
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search meetings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $attentionOnly) { Label("Needs attention", systemImage: "exclamationmark.circle") }
                    .toggleStyle(.button).help("Show only meetings that need attention")
            }
        }
        .frame(minWidth: 780, minHeight: 460)
            .task(id: Request(query: query, attentionOnly: attentionOnly, revision: controller.meetingSnapshotRevision)) {
                let source = controller.recentMeetings, currentQuery = query, filter = attentionOnly
                searching = !currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                report = nil
                do {
                    if searching { try await Task.sleep(for: .milliseconds(200)) }
                    let value = try await index.search(source, query: currentQuery, attentionOnly: filter)
                    try Task.checkCancellation()
                    report = value; searching = false
                } catch { /* Cancellation cannot publish results for an earlier query. */ }
            }
    }
}
