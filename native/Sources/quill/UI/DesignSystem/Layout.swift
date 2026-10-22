import SwiftUI

/// App layout constraints, not replacements for native control metrics.
enum CMLayout {
    static let popoverWidth: CGFloat = 320
    static let popoverInset: CGFloat = 14
    static let recentRowHeight: CGFloat = 40
    static let recentLimit = 3
    static let settingsWidth: CGFloat = 640
    static let settingsHeight: CGFloat = 480
}

extension View {
    func cmFormFootnote() -> some View {
        font(.caption).foregroundStyle(CMTheme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
    }
}
