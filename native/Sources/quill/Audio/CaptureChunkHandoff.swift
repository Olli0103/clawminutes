import Foundation

/// The production handoff order, independently exercisable without devices.
/// Caller publishes the returned state before submitting its closed file.
enum CaptureChunkHandoff {
    struct Result {
        var capture: CaptureRecovery
        var closedFile: String?
        var failed: Bool
    }
    static func perform(source: String, capture original: CaptureRecovery, progress: CaptureProgress.Snapshot,
                        prepare: (String) throws -> PCMChunkWriter.Prepared,
                        persist: (CaptureRecovery) throws -> Void,
                        commit: (PCMChunkWriter.Prepared) throws -> CaptureProgress.Snapshot) -> Result {
        var capture = original
        let filename = capture.nextFilename(source: source)
        do {
            let prepared = try prepare(filename)
            try capture.planChunk(source: source, file: filename, progress: progress)
            try persist(capture) // Required before any frame reaches the new file.
            let closed = try commit(prepared)
            let oldFile = try capture.commitChunk(source: source, file: filename, closed: closed)
            return Result(capture: capture, closedFile: oldFile, failed: false)
        } catch {
            capture.failedChunk(source: source, file: filename)
            return Result(capture: capture, failed: true)
        }
    }
}
