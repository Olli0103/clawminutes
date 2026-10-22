import Foundation

/// Local text search over the library's explicit document paths. Cache entries
/// are memory-only, bounded, and invalidated by file/ancestor identity changes.
/// No search result is evidence of delivery, attendance or speaker identity.
actor MeetingSearchIndex {
    enum Field: String, Sendable { case title = "Title", notes = "Notes", transcript = "Transcript" }
    struct Match: Identifiable, Sendable {
        let meeting: RecentMeeting
        let field: Field
        let excerpt: String?
        var id: String { meeting.id }
    }
    struct Report: Sendable {
        var matches: [Match] = []
        var unavailableDocuments = 0
        var queryTooLong = false
        var notice: String? {
            if queryTooLong { return "Use up to 256 characters and 32 words in a search." }
            guard unavailableDocuments > 0 else { return nil }
            let subject = unavailableDocuments == 1 ? "1 document could not be searched. It may be" : "\(unavailableDocuments) documents could not be searched. They may be"
            return subject + " missing, linked, unreadable or too large."
        }
    }
    private struct Signature: Equatable { let file: String; let ancestors: [String] }
    private struct Cached {
        let signature: Signature
        let text: String?
        let folded: String?
        let bytes: Int
        var used: UInt64
    }
    private var entries: [String: Cached] = [:]
    private var tick: UInt64 = 0
    private(set) var fileReads = 0
    private(set) var cachedBytes = 0
    private let maximumDocumentBytes: Int
    private let maximumCacheBytes: Int
    init(maximumDocumentBytes: Int = 20_000_000, maximumCacheBytes: Int = 32_000_000) {
        self.maximumDocumentBytes = max(1, min(maximumDocumentBytes, 20_000_000))
        self.maximumCacheBytes = max(0, min(maximumCacheBytes, 32_000_000))
    }
    func clear() { entries.removeAll(); cachedBytes = 0 }
    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func stamp(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    private func signature(_ url: URL) -> Signature? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumDocumentBytes else { return nil }
        let file = Self.stamp(info)
        var parent = url.deletingLastPathComponent(), ancestors: [String] = []
        while parent.path != "/" {
            guard lstat(parent.path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) != S_IFDIR {
                // Foundation standardizes /private/var back to /var. Admit only
                // macOS's exact root aliases, never a linked document ancestor.
                guard ["/var", "/tmp", "/etc"].contains(parent.path), (info.st_mode & S_IFMT) == S_IFLNK,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path),
                      target == "private" + parent.path || target == "/private" + parent.path else { return nil }
                ancestors.append(Self.stamp(info))
                guard lstat("/private" + parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            }
            // Directory mtime changes with unrelated files. Identity and mode
            // detect substitution without invalidating every sibling document.
            ancestors.append("\(info.st_dev):\(info.st_ino):\(info.st_mode)")
            parent.deleteLastPathComponent()
        }
        return Signature(file: file, ancestors: ancestors)
    }
    private func document(_ url: URL) throws -> Cached? {
        let url = url.standardizedFileURL, key = url.path
        guard let before = signature(url) else {
            if let old = entries.removeValue(forKey: key) { cachedBytes -= old.bytes }
            return nil
        }
        tick &+= 1
        if var old = entries[key], old.signature == before {
            old.used = tick; entries[key] = old
            return old
        }
        if let old = entries.removeValue(forKey: key) { cachedBytes -= old.bytes }
        var text: String?
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            if fstat(fd, &opened) == 0, Self.stamp(opened) == before.file {
                fileReads += 1
                if let data = try? handle.read(upToCount: maximumDocumentBytes + 1), data.count <= maximumDocumentBytes,
                   data.count == Int(opened.st_size), let value = String(data: data, encoding: .utf8), signature(url) == before {
                    text = Self.collapsed(value)
                }
            }
        }
        try Task.checkCancellation()
        guard let text else { return nil } // A transient read failure must not poison a later query.
        let folded = Self.folded(text)
        try Task.checkCancellation()
        let bytes = text.utf8.count + folded.utf8.count
        let cached = Cached(signature: before, text: text, folded: folded, bytes: bytes, used: tick)
        if bytes <= maximumCacheBytes {
            while cachedBytes + bytes > maximumCacheBytes || entries.count >= 256, let victim = entries.min(by: { $0.value.used < $1.value.used }) {
                cachedBytes -= victim.value.bytes; entries.removeValue(forKey: victim.key)
            }
            entries[key] = cached; cachedBytes += bytes
        }
        return cached
    }
    private static func collapsed(_ value: String) -> String? {
        var output = "", space = false, count = 0
        output.reserveCapacity(value.utf8.count)
        let whitespace = CharacterSet.whitespacesAndNewlines
        for scalar in value.unicodeScalars {
            count += 1
            if count % 4096 == 0, Task.isCancelled { return nil }
            if whitespace.contains(scalar) { space = true }
            else {
                if space, !output.isEmpty { output.append(" ") }
                output.unicodeScalars.append(scalar); space = false
            }
        }
        return output
    }
    private static func excerpt(_ text: String, terms: [String]) -> String {
        let found = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.min { $0.lowerBound < $1.lowerBound }
        let anchor = found?.lowerBound ?? text.startIndex
        let start = text.index(anchor, offsetBy: -55, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 190, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
    }
    func search(_ meetings: [RecentMeeting], query: String, attentionOnly: Bool = false) throws -> Report {
        try Task.checkCancellation()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = Self.folded(trimmed).split(whereSeparator: \.isWhitespace).map(String.init)
        guard trimmed.count <= 256, terms.count <= 32 else { return Report(queryTooLong: true) }
        let candidates = meetings.filter { !attentionOnly || $0.needsAttention }
        if terms.isEmpty {
            clear()
            return Report(matches: candidates.map { Match(meeting: $0, field: .title, excerpt: nil) })
        }
        let allowed = Set(meetings.flatMap { [$0.notes, $0.transcript].compactMap { $0?.standardizedFileURL.path } })
        for key in Array(entries.keys) where !allowed.contains(key) {
            cachedBytes -= entries.removeValue(forKey: key)!.bytes
        }
        var report = Report()
        for meeting in candidates {
            try Task.checkCancellation()
            let title = Self.folded(meeting.title)
            if terms.allSatisfy({ title.contains($0) }) {
                report.matches.append(Match(meeting: meeting, field: .title, excerpt: nil)); continue
            }
            var hit: Match?
            for (field, file) in [(Field.notes, meeting.notes), (.transcript, meeting.transcript)] {
                try Task.checkCancellation()
                guard let file else { continue }
                let name = field == .notes ? "notes.md" : "transcript.md"
                guard file.lastPathComponent == name,
                      field != .transcript || file.deletingLastPathComponent().standardizedFileURL == meeting.directory.standardizedFileURL,
                      let cached = try document(file), let text = cached.text, let folded = cached.folded else {
                    report.unavailableDocuments += 1; continue
                }
                if terms.allSatisfy({ title.contains($0) || folded.contains($0) }) {
                    hit = Match(meeting: meeting, field: field, excerpt: Self.excerpt(text, terms: terms)); break
                }
            }
            if let hit { report.matches.append(hit) }
        }
        try Task.checkCancellation()
        return report
    }
}
