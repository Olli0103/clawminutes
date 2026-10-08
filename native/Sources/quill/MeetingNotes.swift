import Foundation

struct NoteSection: Codable, Equatable, Identifiable, Sendable {
    var title: String
    var instructions: String
    var id: String { title }
}
struct NoteTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var context: String
    var sections: [NoteSection]
    static let defaults: [NoteTemplate] = [
        .init(id: "meeting", name: "Meeting", context: "Use concise, factual notes. Separate discussion, decisions and open questions. Do not infer approvals or commitments.", sections: [
            .init(title: "Summary", instructions: "Main points and outcomes."),
            .init(title: "Decisions", instructions: "Only explicit decisions. Identify proposals separately."),
            .init(title: "Next actions", instructions: "Explicit actions only. Owner and due date only when stated."),
            .init(title: "Open questions", instructions: "Unresolved questions, risks and missing evidence.")]),
        .init(id: "one-to-one", name: "1:1", context: "A recurring 1:1. Keep observations separate from assumptions. Generate review candidates only; do not update tasks or people files.", sections: [
            .init(title: "Priorities and progress", instructions: "Goals, wins and measurable progress."),
            .init(title: "Blockers and support", instructions: "Dependencies and concrete help needed."),
            .init(title: "Feedback and coaching", instructions: "Specific behaviors, feedback and expectations."),
            .init(title: "Growth and stretch", instructions: "Development themes and opportunities when discussed."),
            .init(title: "Next actions", instructions: "Explicit next steps. Separate my tasks, their tasks and waiting items only when owners are known.")]),
        .init(id: "sap", name: "SAP meeting", context: "Short operational notes. Do not invent approvals, scope decisions, delivery commitments, ownership, or commercial facts.", sections: [
            .init(title: "Context", instructions: "Purpose and main discussion."),
            .init(title: "Decisions and open decisions", instructions: "Keep proposed and confirmed decisions separate."),
            .init(title: "Actions and dependencies", instructions: "Only explicit actions, owners and dates."),
            .init(title: "Needs evidence", instructions: "Missing approvals, uncertainties and contradictions.")])
    ]
    func validate() throws {
        guard !id.isEmpty, id.count <= 80, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              context.count <= 12000,
              [id, name] .allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              sections.allSatisfy({ !$0.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              (1...30).contains(sections.count), sections.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 120 && $0.instructions.count <= 4000 }) else {
            throw TranscriptionFailure("Give the template a name and at least one section. Keep section titles under 120 characters.")
        }
    }
    var json: [String: Any] { ["id": id, "name": name, "context": context, "sections": sections.map { ["title": $0.title, "instructions": $0.instructions] }] }
}

enum MeetingNotesSettings {
    static func read() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: Config.path))) as? [String: Any] ?? [:] }
    static var templates: [NoteTemplate] {
        guard let object = read()["note_templates"], let data = try? JSONSerialization.data(withJSONObject: object),
              let saved = try? JSONDecoder().decode([NoteTemplate].self, from: data), !saved.isEmpty,
              saved.allSatisfy({ (try? $0.validate()) != nil }) else { return NoteTemplate.defaults }
        return saved
    }
    static var selected: NoteTemplate { let id = read()["note_template_id"] as? String; return templates.first { $0.id == id } ?? templates[0] }
    static var folder: URL { URL(fileURLWithPath: ((read()["notes_folder"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ocmh/Meetings").path) as NSString).expandingTildeInPath, isDirectory: true) }
    static func update(_ changes: [String: Any]) throws {
        // Never replace a malformed existing configuration with defaults.
        if FileManager.default.fileExists(atPath: Config.path.path) { guard (try JSONSerialization.jsonObject(with: Data(contentsOf: Config.path))) is [String: Any] else { throw TranscriptionFailure("Could not read ocmh configuration.") } }
        var config = read(); for (key,value) in changes { config[key] = value }
        try FileManager.default.createDirectory(at: Config.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: Config.path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.path.path)
    }
    static func save(_ templates: [NoteTemplate], selected: String) throws {
        guard !templates.isEmpty, templates.count <= 100, Set(templates.map(\.id)).count == templates.count else { throw TranscriptionFailure("Keep at least one template and use unique names for copies.") }
        for template in templates { try template.validate() }
        try update(["note_templates": templates.map(\.json), "note_template_id": selected])
    }
}

struct MeetingContext: Codable, Equatable, Sendable {
    var meeting_id: String
    var title: String
    var title_source: String
    var first_observed_at: Double
    var last_observed_at: Double
    var ended_observed_at: Double?
    var timezone = TimeZone.current.identifier
    func isCurrent(at time: Double) -> Bool {
        ended_observed_at == nil && last_observed_at.isFinite && last_observed_at >= time - 15 && last_observed_at <= time + 5
    }
    mutating func observeActive(at time: Double) {
        last_observed_at = time
        // A later active observation disproves the earlier ended observation.
        // This clock describes the current continuous call, not an exact end time.
        ended_observed_at = nil
    }
    var json: [String: Any] {
        var result: [String: Any] = ["meeting_id": meeting_id, "title": title, "title_source": title_source, "first_observed_at": first_observed_at, "last_observed_at": last_observed_at, "timezone": timezone]
        if let ended_observed_at { result["ended_observed_at"] = ended_observed_at }; return result
    }
}

enum TeamsMeetingTitle {
    static func clean(_ windowTitle: String) -> String? {
        var value = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" | Microsoft Teams", " | Microsoft Teams classic", " - Microsoft Teams", " – Microsoft Teams"] where value.hasSuffix(suffix) { value = String(value.dropLast(suffix.count)) }
        let parts = value.components(separatedBy: " | ")
        if parts.count >= 3, let account = parts.last,
           account.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil {
            value = parts.dropLast(2).joined(separator: " | ")
        }
        let compactPrefix = "Meeting compact view | "
        if value.lowercased().hasPrefix(compactPrefix.lowercased()) {
            value = String(value.dropFirst(compactPrefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let generic = ["microsoft teams", "teams", "meeting", "call", "besprechung", "anruf", "microsoft teams meeting", "meeting | microsoft teams", "meeting compact view"]
        guard !value.isEmpty, value.count <= 256, !value.contains("\n"), !generic.contains(value.lowercased()) else { return nil }
        return value
    }
}

/// Organized generated exports. Audio and the canonical Gateway archive stay in their original locations.
enum MeetingDocuments {
    /// Bind each export to its original destination. Changing the default
    /// affects future exports; history requires an explicit migration.
    static func exportRoot(recording: URL, fallbackRoot: URL) throws -> URL {
        let binding = recording.appendingPathComponent("notes-export-location.json")
        if FileManager.default.fileExists(atPath: binding.path) {
            let info = try ArchiveBacklog.object(binding)
            guard info["schemaVersion"] as? Int == 1, let root = info["root"] as? String, root.hasPrefix("/"),
                  let destination = info["destination"] as? String, destination.hasPrefix("/"),
                  let sessionID = info["sessionId"] as? String,
                  let receipt = try? ArchiveBacklog.object(recording.appendingPathComponent("archive-receipt.json")),
                  receipt["sessionId"] as? String == sessionID else {
                throw TranscriptionFailure("Saved export location needs review. Existing notes preserved.")
            }
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            try checkPath(URL(fileURLWithPath: destination), root: rootURL)
            if let marker = try? String(data: ArchiveBacklog.read(recording.appendingPathComponent("notes-export-path.txt")), encoding: .utf8),
               marker.trimmingCharacters(in: .whitespacesAndNewlines) != destination {
                throw TranscriptionFailure("Saved export paths disagree. Existing notes preserved.")
            }
            return rootURL
        }
        let marker = recording.appendingPathComponent("notes-export-path.txt")
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let value = String(data: try ArchiveBacklog.read(marker), encoding: .utf8), value.hasPrefix("/") else {
                throw TranscriptionFailure("Saved export path is unreadable. Existing notes preserved.")
            }
            try checkPath(URL(fileURLWithPath: value.trimmingCharacters(in: .whitespacesAndNewlines)), root: fallbackRoot)
        }
        return fallbackRoot
    }
    static func rememberExport(_ destination: URL, root: URL, recording: URL, sessionID: String) throws {
        try checkPath(destination, root: root)
        let info: [String: Any] = ["schemaVersion": 1, "root": root.path, "destination": destination.path, "sessionId": sessionID]
        let location = recording.appendingPathComponent("notes-export-location.json")
        try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: location, options: .atomic)
        let marker = recording.appendingPathComponent("notes-export-path.txt")
        try Data(destination.path.utf8).write(to: marker, options: .atomic)
        for file in [location, marker] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
    struct MigrationPaths: Sendable { let source: URL; let destination: URL; let sessionID: String }
    static func migrationPaths(recording: URL, to root: URL) throws -> MigrationPaths {
        guard ArchiveBacklog.isFinished(recording) else { throw TranscriptionFailure("Finish the recording before moving notes.") }
        let receipt = try ArchiveBacklog.object(recording.appendingPathComponent("archive-receipt.json"))
        guard let id = receipt["sessionId"] as? String, receipt["saved"] as? Bool == true,
              let text = String(data: try ArchiveBacklog.read(recording.appendingPathComponent("notes-export-path.txt")), encoding: .utf8),
              text.hasPrefix("/") else { throw TranscriptionFailure("No verified notes export is available to migrate.") }
        let old = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let legacyRoot = old.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = try exportRoot(recording: recording, fallbackRoot: legacyRoot)
        guard try existingID(old, root: sourceRoot) == id else { throw TranscriptionFailure("Existing notes do not match this meeting.") }
        let relative = old.standardizedFileURL.path.dropFirst(sourceRoot.standardizedFileURL.path.count + 1)
        let target = root.appendingPathComponent(String(relative), isDirectory: true)
        try checkPath(target, root: root)
        guard !target.standardizedFileURL.path.hasPrefix(old.standardizedFileURL.path + "/") else {
            throw TranscriptionFailure("Choose a destination outside these existing notes. Originals are preserved.")
        }
        if target.standardizedFileURL != old.standardizedFileURL, FileManager.default.fileExists(atPath: target.path) {
            throw TranscriptionFailure("The destination already exists. Existing notes were left untouched.")
        }
        return MigrationPaths(source: old, destination: target, sessionID: id)
    }
    /// Explicit copy preserves edited files and the original. Reviewed content
    /// must still match before staging and before publishing the new location.
    static func migrateExport(recording: URL, to root: URL, expectedSource: NotesFolderSnapshot? = nil, expectedRootIdentity: String? = nil) throws -> URL {
        let paths = try migrationPaths(recording: recording, to: root)
        if let expectedRootIdentity {
            guard try NotesMigration.destinationIdentity(root) == expectedRootIdentity else { throw NotesMigration.changed }
        }
        let old = paths.source, target = paths.destination
        if target.standardizedFileURL == old.standardizedFileURL { return old }
        let snapshot = try NotesFolderSnapshot.capture(old)
        guard expectedSource == nil || snapshot == expectedSource else { throw NotesMigration.changed }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".ocmh-migrate-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: old, to: staging)
        guard try NotesFolderSnapshot.capture(staging) == snapshot,
              try NotesFolderSnapshot.capture(old) == snapshot else { throw NotesMigration.changed }
        try checkPath(target, root: root)
        if let expectedRootIdentity {
            guard try NotesMigration.destinationIdentity(root) == expectedRootIdentity else { throw NotesMigration.changed }
        }
        try fm.moveItem(at: staging, to: target)
        try rememberExport(target, root: root, recording: recording, sessionID: paths.sessionID)
        return target
    }
    static func component(_ text: String) -> String {
        let title = TeamsMeetingTitle.clean(text) ?? text
        var result = "", separator = false
        for scalar in title.precomposedStringWithCanonicalMapping.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let next = (separator && !result.isEmpty ? "-" : "") + String(scalar)
                if result.utf8.count + next.utf8.count > 80 { break }
                result += next; separator = false
            } else { separator = true }
        }
        return result
    }
    private static func checkPath(_ destination: URL, root: URL) throws {
        let manager = FileManager.default
        let base = root.standardizedFileURL
        guard destination.standardizedFileURL.path.hasPrefix(base.path + "/") else {
            throw TranscriptionFailure("Meeting export path is outside the selected folder.")
        }
        var current = base
        for part in destination.standardizedFileURL.path.dropFirst(base.path.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            if manager.fileExists(atPath: current.path), (try current.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw TranscriptionFailure("Meeting export path contains a symbolic link. Choose another folder.")
            }
        }
    }
    private static func existingID(_ folder: URL, root: URL) throws -> String? {
        try checkPath(folder, root: root)
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return nil }
        for name in ["notes.md", "transcript.md", "metadata.json"] {
            let file = folder.appendingPathComponent(name)
            try checkPath(file, root: root)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw TranscriptionFailure("Meeting export folder is incomplete. Existing files preserved.")
            }
        }
        guard let info = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("metadata.json"))) as? [String: Any],
              let id = info["sessionId"] as? String else {
            throw TranscriptionFailure("Meeting export folder already contains other files. Existing files preserved.")
        }
        return id
    }
    /// Rename an existing generated export using its saved receipt. No network requests.
    static func renameExisting(recording: URL, root: URL) throws -> URL {
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: recording.appendingPathComponent("meta.json"))) as? [String: Any]
        guard meta?["status"] as? String == "stopped" else { throw TranscriptionFailure("Active or incomplete recording left untouched.") }
        let text = try String(contentsOf: recording.appendingPathComponent("notes-export-path.txt"), encoding: .utf8)
        let old = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: recording.appendingPathComponent("archive-receipt.json"))) as? [String: Any] ?? [:]
        guard receipt["saved"] as? Bool == true, let id = receipt["sessionId"] as? String, try existingID(old, root: root) == id else {
            throw TranscriptionFailure("Existing notes do not match the saved meeting receipt.")
        }
        let destination = try export(receipt: receipt, root: root, recording: recording)
        try Data(destination.path.utf8).write(to: recording.appendingPathComponent("notes-export-path.txt"), options: .atomic)
        return destination
    }
    struct ValidatedDocuments {
        let id: String, title: String, notes: String, transcript: String
        let date: Date
        let metadata: [String: Any]
    }
    /// Validate without publishing a receipt or touching the notes folder.
    static func validateDocuments(_ receipt: [String: Any]) throws -> ValidatedDocuments {
        guard let id = receipt["sessionId"] as? String, id.range(of: "^teams-[a-f0-9]{24}$", options: .regularExpression) != nil,
              let docs = receipt["documents"] as? [String: Any], let title = docs["title"] as? String,
              let start = docs["startedAt"] as? String, let date = ISO8601DateFormatter().date(from: start),
              let notes = docs["notesMarkdown"] as? String, let transcript = docs["transcriptMarkdown"] as? String,
              let metadata = docs["metadata"] as? [String: Any], metadata["sessionId"] as? String == id,
              notes.utf8.count < 2_000_000, transcript.utf8.count < 16_000_000 else { throw TranscriptionFailure("Gateway returned incomplete meeting documents. Recording preserved.") }
        return ValidatedDocuments(id: id, title: title, notes: notes, transcript: transcript, date: date, metadata: metadata)
    }
    static func export(receipt: [String: Any], root: URL, recording: URL) throws -> URL {
        let documents = try validateDocuments(receipt)
        let id = documents.id, title = documents.title, date = documents.date
        let notes = documents.notes, transcript = documents.transcript, metadata = documents.metadata
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy/MM/yyyy.MM.dd-HHmm"
        let base = root.appendingPathComponent(format.string(from: date) + "_" + (component(title).isEmpty ? "Meeting" : component(title)), isDirectory: true)
        let manager = FileManager.default
        try checkPath(base, root: root)
        let month = base.deletingLastPathComponent()
        // Discover the same archive independently of its old display name. Preserve user edits.
        let candidates = manager.fileExists(atPath: month.path) ? try manager.contentsOfDirectory(atPath: month.path).map { month.appendingPathComponent($0, isDirectory: true) } : []
        var previous: URL?
        for candidate in candidates where manager.fileExists(atPath: candidate.appendingPathComponent("metadata.json").path) {
            try checkPath(candidate.appendingPathComponent("metadata.json"), root: root)
            let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: candidate.appendingPathComponent("metadata.json")))) as? [String: Any]
            if info?["sessionId"] as? String == id {
                guard previous == nil else { throw TranscriptionFailure("Multiple local exports match this meeting. Existing files preserved.") }
                _ = try existingID(candidate, root: root)
                previous = candidate
            }
        }
        var destination = base, suffix = 2
        while manager.fileExists(atPath: destination.path), destination.path != previous?.path {
            _ = try existingID(destination, root: root)
            destination = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-\(suffix)", isDirectory: true); suffix += 1
            try checkPath(destination, root: root)
        }
        if let previous {
            if previous.path != destination.path { try manager.moveItem(at: previous, to: destination) }
            return destination
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".ocmh-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(notes.utf8).write(to: staging.appendingPathComponent("notes.md"), options: .atomic)
        try Data(transcript.utf8).write(to: staging.appendingPathComponent("transcript.md"), options: .atomic)
        var info = metadata; info["localRecordingFolder"] = recording.path
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted,.sortedKeys]).write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
        for name in ["notes.md","transcript.md","metadata.json"] { try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent(name).path) }
        try manager.moveItem(at: staging, to: destination)
        return destination
    }
}
