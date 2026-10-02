import Foundation

enum RecordingFolders {
    @discardableResult static func renameFinished(_ dir: URL) throws -> URL {
        let fm = FileManager.default
        guard try dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw TranscriptionFailure("Linked recording folders cannot be renamed")
        }
        let metadata = dir.appendingPathComponent("meta.json")
        guard var meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any],
              meta["status"] as? String != "recording" else { throw TranscriptionFailure("Active recording left untouched") }
        let title: String
        if let confirmed = meta["meeting_title_override"] as? String, let clean = TeamsMeetingTitle.clean(confirmed) {
            title = clean
        } else {
            guard let context = meta["meeting_context"] as? [String: Any],
                  let value = context["title"] as? String, let clean = TeamsMeetingTitle.clean(value),
                  let start = meta["started"] as? String, let date = ISO8601DateFormatter().date(from: start),
                  let last = context["last_observed_at"] as? Double, last >= date.timeIntervalSince1970 - 15,
                  (context["ended_observed_at"] as? Double).map({ $0 >= date.timeIntervalSince1970 }) ?? true else { return dir }
            title = clean
        }
        guard let start = meta["started"] as? String, let date = ISO8601DateFormatter().date(from: start) else {
            throw TranscriptionFailure("Recording timestamp is missing")
        }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy.MM.dd-HHmm"
        let subject = MeetingDocuments.component(title)
        let base = format.string(from: date) + "_" + (subject.isEmpty ? "Meeting" : subject)
        if dir.lastPathComponent == base ||
           (dir.lastPathComponent.hasPrefix(base + "-") && Int(dir.lastPathComponent.dropFirst(base.count + 1)) != nil) { return dir }
        var target = dir.deletingLastPathComponent().appendingPathComponent(base), suffix = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.deletingLastPathComponent().appendingPathComponent(base + "-\(suffix)"); suffix += 1
        }
        meta["recording_id"] = meta["recording_id"] as? String ?? dir.lastPathComponent
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: metadata, options: .atomic)
        try fm.moveItem(at: dir, to: target)
        // Update only the generated local export's recording-folder reference.
        if let text = try? String(contentsOf: target.appendingPathComponent("notes-export-path.txt"), encoding: .utf8) {
            let info = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: info), var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               value["localRecordingFolder"] as? String == dir.path {
                value["localRecordingFolder"] = target.path
                if let updated = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                    try? updated.write(to: info, options: .atomic)
                }
            }
        }
        return target
    }
}
