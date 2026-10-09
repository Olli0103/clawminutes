import SwiftUI

/// Native Liquid Glass for controls on macOS 26+, with an opaque accessibility
/// alternative and standard controls on supported older versions of macOS.
struct HelperButtonStyle: ViewModifier {
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent).buttonBorderShape(.capsule) }
            else { content.buttonStyle(.glass).buttonBorderShape(.capsule) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

struct HelperPanelStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

extension View {
    func helperButton(prominent: Bool = false) -> some View { modifier(HelperButtonStyle(prominent: prominent)) }
    func helperPanel() -> some View { modifier(HelperPanelStyle()) }
    func helperCard(tint: Color = .primary) -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.09), lineWidth: 1) }
    }
}
