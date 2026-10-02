import AppKit
import ArgumentParser

@MainActor
enum HelperAppIcon {
    static func image(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.87, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.22, yRadius: size * 0.22).fill()
            let icon = ClawMicrophoneIcon.image(size: NSSize(width: size, height: size))
            icon.draw(in: NSRect(x: size * 0.16, y: size * 0.18, width: size * 0.68, height: size * 0.64))
            return true
        }
    }
}
struct ExportIcon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export-icon", abstract: "Render the helper's supplied icon for packaging. No capture or network.")
    @Option var output: String
    @Option var size: Int = 512
    @Flag var markOnly = false
    @Option var appearance: String = "dark"
    @MainActor mutating func run() async throws {
        guard size > 0 && size <= 1024 else { throw ValidationError("Icon size must be 1 to 1024") }
        guard ["light", "dark"].contains(appearance) else { throw ValidationError("Appearance must be light or dark") }
        let icon = markOnly
            ? ClawMicrophoneIcon.image(size: NSSize(width: size, height: size), appearance: NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)!)
            : HelperAppIcon.image(size: CGFloat(size))
        guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw ValidationError("Could not render app icon") }
        try png.write(to: URL(fileURLWithPath: output))
    }
}
