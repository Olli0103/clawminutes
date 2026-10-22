import SwiftUI

struct CMStandardButton: ViewModifier {
    let prominent: Bool
    var recording = false
    @Environment(\.cmReviewRendering) private var review
    @ViewBuilder func body(content: Content) -> some View {
        if review { content.buttonStyle(CMReviewButtonStyle(prominent: prominent, recording: recording)) }
        else if prominent { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}
extension View {
    func helperButton(prominent: Bool = false, recording: Bool = false) -> some View { modifier(CMStandardButton(prominent: prominent, recording: recording)) }
    func helperPanel() -> some View { self }
    func helperCard(tint: Color = .primary) -> some View { padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading) }
}
