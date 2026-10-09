import AppKit
import ArgumentParser

@MainActor
enum HelperAppIcon {
    static func image(size: CGFloat = 512, appearance: NSAppearance? = nil) -> NSImage {
        ClawMicrophoneIcon.logo(size: NSSize(width: size, height: size),
                               appearance: appearance ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
    }
}
struct ExportIcon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export-icon", abstract: "Render the helper's supplied icon for packaging. No capture or network.")
    @Option var output: String
    @Option var size: Int = 512
    @Flag var markOnly = false
    @Option var appearance: String = "light"
    @MainActor mutating func run() async throws {
        guard size > 0 && size <= 1024 else { throw ValidationError("Icon size must be 1 to 1024") }
        guard ["light", "dark"].contains(appearance) else { throw ValidationError("Appearance must be light or dark") }
        let icon = markOnly
            ? ClawMicrophoneIcon.image(size: NSSize(width: size, height: size), appearance: NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)!)
            : HelperAppIcon.image(size: CGFloat(size), appearance: NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)!)
        guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw ValidationError("Could not render app icon") }
        try png.write(to: URL(fileURLWithPath: output))
    }
}
