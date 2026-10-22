import SwiftUI

private struct CMReviewRenderingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// ImageRenderer cannot rasterize AppKit-backed List/Table containers.
    /// Export mode flattens their rows, using the same row and cell components.
    var cmReviewRendering: Bool {
        get { self[CMReviewRenderingKey.self] }
        set { self[CMReviewRenderingKey.self] = newValue }
    }
}
private struct CMPreviewTransparencyKey: EnvironmentKey { static let defaultValue = false }
private struct CMPreviewMotionKey: EnvironmentKey { static let defaultValue = false }
private struct CMReferenceDateKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    /// Only synthetic previews freeze relative dates. The installed UI uses the current date.
    var cmReferenceDate: Date? {
        get { self[CMReferenceDateKey.self] }
        set { self[CMReferenceDateKey.self] = newValue }
    }
    // System accessibility values are read-only. Debug previews may add stronger
    // restrictions, but can never turn a user's accessibility setting off.
    var cmPreviewReduceTransparency: Bool {
        get { self[CMPreviewTransparencyKey.self] }
        set { self[CMPreviewTransparencyKey.self] = newValue }
    }
    var cmPreviewReduceMotion: Bool {
        get { self[CMPreviewMotionKey.self] }
        set { self[CMPreviewMotionKey.self] = newValue }
    }
}

/// Native macOS button bezels also use AppKit. This export-only style preserves
/// labels and hierarchy instead of ImageRenderer's unsupported-view placeholder.
/// Interactive previews and the installed app always use native button styles.
struct CMReviewButtonStyle: ButtonStyle {
    var prominent = false
    var recording = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : (scheme == .dark ? .white : .black))
            .background(prominent ? (recording || configuration.role == .destructive ? Color(red: 0.72, green: 0.05, blue: 0.08) : CMTheme.accent) : (scheme == .dark ? Color(white: 0.22) : Color(white: 0.90)), in: .rect(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.65)
    }
}
extension View {
    @ViewBuilder func cmLinkButton() -> some View { modifier(CMFlatButton(link: true)) }
    @ViewBuilder func cmBorderlessButton() -> some View { modifier(CMFlatButton(link: false)) }
}
private struct CMFlatButton: ViewModifier {
    var link: Bool
    @Environment(\.cmReviewRendering) private var review
    @ViewBuilder func body(content: Content) -> some View {
        if review { content.buttonStyle(.plain) }
        else if link { content.buttonStyle(.link) }
        else { content.buttonStyle(.borderless) }
    }
}
struct CMReviewProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.15))
                Rectangle().fill(CMTheme.accent).frame(width: geometry.size.width * CGFloat(configuration.fractionCompleted ?? 0))
            }
        }.frame(height: 4)
    }
}
struct CMProgress: ViewModifier {
    @Environment(\.cmReviewRendering) private var review
    @ViewBuilder func body(content: Content) -> some View {
        if review { content.progressViewStyle(CMReviewProgressStyle()) }
        else { content.progressViewStyle(.linear) }
    }
}
extension View { func cmProgress() -> some View { modifier(CMProgress()) } }
