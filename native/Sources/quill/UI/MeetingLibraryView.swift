import SwiftUI

@MainActor
struct MeetingLibraryView: View {
    @ObservedObject var controller: MenuBarController
    @State private var query = ""
    @State private var attentionOnly = false
    var meetings: [RecentMeeting] {
        Self.filtered(controller.recentMeetings, query: query, attentionOnly: attentionOnly)
    }
    static func filtered(_ meetings: [RecentMeeting], query: String, attentionOnly: Bool) -> [RecentMeeting] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return meetings.filter { (!attentionOnly || $0.needsAttention) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search meeting titles", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search meeting titles")
                Toggle("Needs attention", isOn: $attentionOnly).toggleStyle(.checkbox)
            }
            Text("Meetings recorded on this Mac. Search covers titles.").font(.caption).foregroundStyle(.secondary)
            if meetings.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No meetings here yet" : "No matching meetings", systemImage: "doc.text.magnifyingglass")
            } else {
                List(meetings) { meeting in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: meeting.symbol).foregroundStyle(meeting.needsAttention ? .orange : (meeting.ready ? .green : .secondary))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.title).font(.headline).lineLimit(2)
                            HStack {
                                if let started = meeting.started { Text(started, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                                Text("· " + meeting.statusTitle)
                            }.font(.caption).foregroundStyle(.secondary)
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
    }
}
