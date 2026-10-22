import SwiftUI

/// Related recovery tasks leave the transient popover before opening this view.
@MainActor
struct AttentionReviewView: View {
    @ObservedObject var controller: MenuBarController
    let groupID: String?
    var close: () -> Void
    private var meetings: [RecentMeeting] {
        guard let groupID else { return controller.appState.attentionMeetings }
        return controller.appState.attentionGroups.first { $0.id == groupID }?.meetings ?? []
    }
    var body: some View {
        VStack(spacing: 0) {
            if !meetings.isEmpty {
                List(meetings) { meeting in
                    HStack {
                        MeetingRow(meeting: meeting)
                        Button("Review…") { controller.showMeetingDetails(meeting) }.buttonStyle(.bordered)
                    }
                }.listStyle(.plain)
            } else {
                ContentUnavailableView("Nothing left to finish", systemImage: "checkmark.circle", description: Text("These meetings no longer need this check."))
            }
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.cancelAction) }.padding(12)
        }.frame(minWidth: 500, minHeight: 180).tint(CMTheme.accent)
    }
}
