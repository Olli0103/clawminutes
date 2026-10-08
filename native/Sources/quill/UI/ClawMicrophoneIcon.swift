import AppKit
import CoreImage

/// Keep the supplied logos intact. The menu bar uses only their central mark.
@MainActor
enum ClawMicrophoneIcon {
    private static func load(_ name: String) -> NSImage {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")!
        return NSImage(contentsOf: url)!
    }
    private static let light = load("ocmh-light")
    private static let dark = load("ocmh-dark")
    private static let menuMark: NSImage = {
        let cg = dark.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        // Supplied 1254 px artwork: exclude the background panel and export speckles.
        let cropped = cg.cropping(to: CGRect(x: 240, y: 319, width: 774, height: 640))!
        // The dark logo's black panel is opaque. Alpha alone would render a rectangle.
        let mask = CIImage(cgImage: cropped).applyingFilter("CIMaskToAlpha")
        let mark = CIContext().createCGImage(mask, from: mask.extent)!
        return NSImage(cgImage: mark, size: NSSize(width: 774, height: 640))
    }()

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func logo(size: NSSize, appearance: NSAppearance) -> NSImage {
        let original = isDark(appearance) ? dark : light
        return NSImage(size: size, flipped: false) { _ in
            original.draw(in: fitted(original.size, inside: size))
            return true
        }
    }

    private static func fitted(_ source: NSSize, inside size: NSSize) -> NSRect {
        let scale = min(size.width / source.width, size.height / source.height)
        let width = source.width * scale, height = source.height * scale
        return NSRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func image(size: NSSize = NSSize(width: 22, height: 20),
                      appearance: NSAppearance = NSAppearance(named: .darkAqua)!,
                      active: Bool = false, activeColor: NSColor = .controlAccentColor) -> NSImage {
        let dark = isDark(appearance)
        let original = menuMark
        let image = NSImage(size: size, flipped: false) { _ in
            let rect = fitted(original.size, inside: size)
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
        // Idle marks adapt to highlighted menu bars. Working marks retain the status dot.
        image.isTemplate = !active
        return image
    }
}
