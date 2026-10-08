import SwiftUI

@MainActor
struct MeetingLibraryView: View {
    @ObservedObject var controller: MenuBarController
    @State private var query: String
    @State private var attentionOnly = false
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Focus meeting search").help("Focus search (⌘F)")
                TextField("Search titles, notes and transcripts", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search titles, notes and transcripts").focused($searchFocused)
                Toggle("Needs attention", isOn: $attentionOnly).toggleStyle(.checkbox)
            }
            HStack {
                Text(searching ? "Searching on this Mac…" : "Search stays on this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if searching { ProgressView().controlSize(.small).accessibilityLabel("Searching meetings") }
                else if !query.isEmpty { Text("\(matches.count) " + (matches.count == 1 ? "meeting" : "meetings")).font(.caption).foregroundStyle(.secondary) }
            }
            if let notice = report?.notice, !searching { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if matches.isEmpty {
                ContentUnavailableView(searching ? "Searching meetings" : (query.isEmpty ? "No meetings here yet" : "No matching meetings"), systemImage: "doc.text.magnifyingglass")
            } else {
                List(matches) { match in
                    let meeting = match.meeting
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: meeting.symbol).foregroundStyle(meeting.needsAttention ? .orange : (meeting.ready ? .green : .secondary))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.title).font(.headline).lineLimit(2)
                            HStack {
                                if let started = meeting.started { Text(started, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                                Text("· " + meeting.statusTitle)
                            }.font(.caption).foregroundStyle(.secondary)
                            if let excerpt = match.excerpt {
                                Text(match.field.rawValue + ": " + excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                    .accessibilityLabel("\(match.field.rawValue) match. \(excerpt)")
                            }
                            if meeting.needsAttention { Text(meeting.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                        Spacer()
                        if meeting.ready && !meeting.needsAttention {
                            Button("Open") { controller.openMeeting(meeting) }
                            Menu {
                                Button("Copy notes") { controller.copyNotes(meeting) }
                                Button("Details") { controller.showMeetingDetails(meeting) }
                                Button("Show files") { controller.openDocument(meeting.directory) }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("More actions for \(meeting.title)")
                        } else { Button("Details") { controller.showMeetingDetails(meeting) } }
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
        }.padding(18).frame(minWidth: 550, minHeight: 420)
            .foregroundStyle(.primary).background(Color(nsColor: .windowBackgroundColor))
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
