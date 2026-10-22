import SwiftUI

/// App layout constraints, not replacements for native control metrics.
enum CMLayout {
    static let popoverWidth: CGFloat = 384
    static let popoverInset: CGFloat = 16
    static let recentRowHeight: CGFloat = 52
    static let recentLimit = 4
}

extension View {
    func cmFormFootnote() -> some View {
        font(.caption).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
    }
}
