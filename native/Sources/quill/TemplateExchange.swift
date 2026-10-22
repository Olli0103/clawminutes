import Foundation

enum TemplateExchange {
    struct Package: Codable { let schemaVersion: Int; let template: NoteTemplate }
    static let maximumBytes = 1_000_000
    static func decode(_ data: Data) throws -> NoteTemplate {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "template"],
              let template = object["template"] as? [String: Any],
              Set(template.keys) == ["id", "name", "context", "sections"],
              let sections = template["sections"] as? [[String: Any]],
              sections.allSatisfy({ Set($0.keys) == ["title", "instructions"] }) else {
            throw TranscriptionFailure("Choose a ClawMinutes template JSON file under 1 MB.")
        }
        let package = try JSONDecoder().decode(Package.self, from: data)
        guard package.schemaVersion == 1 else { throw TranscriptionFailure("This template format needs a newer ClawMinutes version.") }
        try package.template.validate()
        // Import is a new draft, never an overwrite of an existing template.
        var copy = package.template; copy.id = UUID().uuidString
        return copy
    }
    static func read(_ file: URL) throws -> NoteTemplate {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize ?? Int.max <= maximumBytes else {
            throw TranscriptionFailure("Choose a regular ClawMinutes template JSON file under 1 MB.")
        }
        return try decode(Data(contentsOf: file))
    }
    static func encode(_ template: NoteTemplate) throws -> Data {
        try template.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Package(schemaVersion: 1, template: template))
        guard data.count <= maximumBytes else { throw TranscriptionFailure("Template file exceeds 1 MB.") }
        return data
    }
    static func write(_ template: NoteTemplate, to output: URL) throws {
        let data = try encode(template)
        let descriptor = open(output.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
    }
}
