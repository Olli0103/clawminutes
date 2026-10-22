import SwiftUI

enum CMTheme {
    static let accent = Color.accentColor
    // Strong enough for small text, while dates and explanations remain quieter
    // than titles. Verified in exported light and dark layouts.
    static let secondary = Color.primary.opacity(0.72)
}
