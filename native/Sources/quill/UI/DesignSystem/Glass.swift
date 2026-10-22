import SwiftUI

/// Only floating chrome uses this modifier. Lists, forms and documents stay flat.
private struct CMGlass: ViewModifier {
    var id: String?
    var namespace: Namespace.ID?
    @Environment(\.accessibilityReduceTransparency) private var systemSolid
    @Environment(\.cmPreviewReduceTransparency) private var previewSolid
    private var solid: Bool { systemSolid || previewSolid }
    @Environment(\.accessibilityReduceMotion) private var systemStill
    @Environment(\.cmPreviewReduceMotion) private var previewStill
    private var still: Bool { systemStill || previewStill }
    @ViewBuilder func body(content: Content) -> some View {
        if solid {
            content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        } else if #available(macOS 26, *) {
            if let id, let namespace, !still {
                content.glassEffect(.regular, in: .rect(cornerRadius: 12)).glassEffectID(id, in: namespace)
            } else { content.glassEffect(.regular, in: .rect(cornerRadius: 12)) }
        } else { content.background(.regularMaterial, in: .rect(cornerRadius: 12)) }
    }
}
struct CMGlassContainer<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var systemSolid
    @Environment(\.cmPreviewReduceTransparency) private var previewSolid
    private var solid: Bool { systemSolid || previewSolid }
    @Environment(\.accessibilityReduceMotion) private var systemStill
    @Environment(\.cmPreviewReduceMotion) private var previewStill
    private var still: Bool { systemStill || previewStill }
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *), !solid, !still { GlassEffectContainer(spacing: 20, content: content) }
        else { content() }
    }
}
private struct CMButton: ViewModifier {
    let prominent: Bool
    @Environment(\.cmReviewRendering) private var review
    @Environment(\.accessibilityReduceTransparency) private var systemSolid
    @Environment(\.cmPreviewReduceTransparency) private var previewSolid
    private var solid: Bool { systemSolid || previewSolid }
    @ViewBuilder func body(content: Content) -> some View {
        if review { content.buttonStyle(CMReviewButtonStyle(prominent: prominent)) }
        else if #available(macOS 26, *), !solid {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered).background(solid ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: .rect(cornerRadius: 6)) }
        }
    }
}
struct CMPopoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemSolid
    @Environment(\.cmPreviewReduceTransparency) private var previewSolid
    private var solid: Bool { systemSolid || previewSolid }
    func body(content: Content) -> some View {
        // The popover's system material surrounds flat, opaque content. Busy video
        // cannot show through text. Never stack a glass panel underneath controls.
        content.background(Color(nsColor: .windowBackgroundColor))
            .transaction { if solid { $0.animation = nil } }
    }
}
extension View {
    func cmGlass(_ id: String? = nil, in namespace: Namespace.ID? = nil) -> some View { modifier(CMGlass(id: id, namespace: namespace)) }
    func cmButton(prominent: Bool = false) -> some View { modifier(CMButton(prominent: prominent)) }
}

/// Applies an identity to the native glass button without adding another layer.
struct CMRecordingIdentity: ViewModifier {
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var systemStill
    @Environment(\.cmPreviewReduceMotion) private var previewStill
    private var still: Bool { systemStill || previewStill }
    @Environment(\.accessibilityReduceTransparency) private var systemSolid
    @Environment(\.cmPreviewReduceTransparency) private var previewSolid
    private var solid: Bool { systemSolid || previewSolid }
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !still, !solid { content.glassEffectID("recording-control", in: namespace) }
        else { content }
    }
}
