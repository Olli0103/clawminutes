import Foundation
import AVFoundation

/// Resolves only validated recording filenames beneath the original meeting.
/// Playback is user initiated, local, and bounded to one eight-second excerpt.
enum MeetingAudioPreview {
    struct Clip {
        let file: URL
        let start: Double
        let duration: Double
    }
    static func clip(directory: URL, segment: Transcript.Segment) throws -> Clip? {
        let metadata = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        var source = directory
        if let version = try MeetingRevisions.descriptor(meta: metadata, directory: directory) {
            let root = directory.deletingLastPathComponent()
            let candidates = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            let originals = candidates.filter { candidate in
                guard (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let meta = try? ArchiveBacklog.object(candidate.appendingPathComponent("meta.json")) else { return false }
                return meta["started"] as? String == metadata["started"] as? String && meta["revision"] == nil &&
                    (meta["recording_id"] as? String ?? candidate.lastPathComponent) == version.baseRecordingId
            }
            guard originals.count == 1, let original = originals.first else { return nil }
            source = original
        }
        guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        let meta = try SessionMeta.read(from: source)
        let trackSource = segment.source ?? (segment.speaker.hasPrefix("me") || segment.speaker.hasPrefix("mic") ? "mic" : "system")
        let tracks = meta.tracks.filter { $0.source == trackSource && $0.offsetMs <= segment.start_ms }
            .sorted { $0.offsetMs > $1.offsetMs }
        for track in tracks {
            let file = source.appendingPathComponent(track.file)
            guard SessionMeta.validTrackFile(track.file), RecentMeeting.readableDocument(file),
                  let audio = try? AVAudioFile(forReading: file), (1...192000).contains(audio.processingFormat.sampleRate) else { continue }
            let start = Double(segment.start_ms - track.offsetMs) / 1000
            let remaining = Double(audio.length) / audio.processingFormat.sampleRate - start
            guard remaining > 0 else { continue }
            return Clip(file: file, start: start, duration: min(8, remaining))
        }
        return nil
    }
}

@MainActor final class MeetingClipPlayer: ObservableObject {
    @Published private(set) var playingIndex: Int?
    @Published private(set) var message: String?
    private var engine: AVAudioEngine?
    private var stopTask: Task<Void, Never>?
    func stop() {
        stopTask?.cancel(); stopTask = nil
        engine?.stop(); engine = nil; playingIndex = nil
    }
    func play(directory: URL, segment: Transcript.Segment, index: Int) {
        if playingIndex == index { stop(); return }
        stop(); message = nil
        do {
            guard let clip = try MeetingAudioPreview.clip(directory: directory, segment: segment) else {
                message = "Audio for this turn is unavailable. It may have been deleted after verification."; return
            }
            let file = try AVAudioFile(forReading: clip.file)
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.scheduleSegment(file, startingFrame: AVAudioFramePosition(clip.start * file.processingFormat.sampleRate),
                                 frameCount: AVAudioFrameCount(clip.duration * file.processingFormat.sampleRate), at: nil)
            try engine.start(); node.play(); self.engine = engine; playingIndex = index
            stopTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(clip.duration)) } catch { return }
                self?.stop()
            }
        } catch { message = "This audio excerpt could not be played. You can still review the text." }
    }
}
