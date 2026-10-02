import AppKit

/// The user-supplied mark. Theme changes tint its alpha, never redraw its shape.
@MainActor
enum ClawMicrophoneIcon {
    private static let source: NSImage = {
        let url = Bundle.main.url(forResource: "ocmh-dark", withExtension: "png")
            ?? Bundle.module.url(forResource: "ocmh-dark", withExtension: "png")!
        let supplied = NSImage(contentsOf: url)!
        let cg = supplied.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        // Visible bounds in the original 1254 px image, with a little edge padding.
        // Near-transparent export speckles outside the mark are excluded.
        let cropped = cg.cropping(to: CGRect(x: 275, y: 273, width: 634, height: 764))!
        return NSImage(cgImage: cropped, size: NSSize(width: 634, height: 764))
    }()

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func image(size: NSSize = NSSize(width: 22, height: 20),
                      appearance: NSAppearance = NSAppearance(named: .darkAqua)!,
                      active: Bool = false, activeColor: NSColor = .controlAccentColor) -> NSImage {
        let dark = isDark(appearance)
        let original = source
        let image = NSImage(size: size, flipped: false) { _ in
            let scale = min(size.width / original.size.width, size.height / original.size.height)
            let width = original.size.width * scale, height = original.size.height * scale
            let rect = NSRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            original.draw(in: rect)
            if !dark {
                NSColor.black.setFill()
                rect.fill(using: .sourceAtop)
            }
            if active {
                activeColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - 3, y: 0, width: 3, height: 3)).fill()
            }
            return true
        }
        // Preserve the supplied pink in dark mode; AppKit must not template-tint it.
        image.isTemplate = false
        return image
    }
}
