import Foundation
import ApplicationServices
import AVFoundation
import CoreGraphics
import ArgumentParser

enum HelperDiagnostics {
    struct Permissions: Codable, Sendable {
        let accessibility: Bool
        let microphone: Bool
        let systemAudio: Bool
        @MainActor static func current() -> Self {
            Self(accessibility: AXIsProcessTrusted(), microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                 systemAudio: CGPreflightScreenCaptureAccess())
        }
    }
    struct Meeting: Codable {
        let recordingRef: String
        let artifactState: ArchiveBacklog.State
        let pipelineStage: MeetingPipelineState.Stage?
        let transcriptionAttempts: Int?
        let deliveryAttempts: Int?
        let errorCode: String?
        let stateVerified: Bool
    }
    struct Report: Codable {
        let schemaVersion: Int
        let generatedAt: Double
        let helperVersion: String
        let operatingSystem: String
        let permissions: Permissions
        let configurationReadable: Bool
        let localModelAvailable: Bool
        let freeBytes: Int64?
        let meetings: [Meeting]
        let events: [PipelineEvents.Event]
        let lockOwnership: String
        let excluded: [String]
    }
    static func report(root: URL, settings: URL = Config.path, permissions: Permissions,
                       localModelAvailable: Bool, limit: Int = 25) throws -> Report {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let candidates = files.filter { $0.lastPathComponent.first != "." }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var meetings: [Meeting] = []
        for directory in candidates where meetings.count < max(0, min(limit, 25)) {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let item = ArchiveBacklog.inspect(directory)
            let state = try? MeetingPipelineState.load(directory, inspected: item)
            meetings.append(Meeting(recordingRef: AudioRetention.digest(Data((state?.recordingIdentity ?? directory.lastPathComponent).utf8)).prefix(24).description,
                                    artifactState: item.state, pipelineStage: state?.stage,
                                    transcriptionAttempts: state?.transcription.count,
                                    deliveryAttempts: item.retry?.attempts ?? state?.delivery.count,
                                    errorCode: PipelineEvents.safeCode(state?.transcription.lastError?.code ?? item.retry?.lastError?.code ?? state?.delivery.lastError?.code),
                                    stateVerified: state != nil))
        }
        let config = try? ArchiveBacklog.object(settings)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Report(schemaVersion: 1, generatedAt: Date().timeIntervalSince1970,
                      helperVersion: version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) == nil ? "development" : version,
                      operatingSystem: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", permissions: permissions,
                      configurationReadable: config != nil, localModelAvailable: localModelAvailable,
                      freeBytes: try? RecordingStorage.available(at: root), meetings: meetings,
                      events: PipelineEvents.recent(at: settings.deletingLastPathComponent()),
                      lockOwnership: "needs_evidence: diagnostic does not acquire lifecycle or recording locks or infer their owners",
                      excluded: ["audio", "transcripts", "notes", "meeting titles", "participant names", "paths", "hostname", "credentials", "Gateway URL", "raw errors", "raw configuration", "raw log files"])
    }
    static func data(_ report: Report) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report) + Data("\n".utf8)
    }
    static func write(_ report: Report, to output: URL) throws {
        // A diagnostic must never overwrite a recording, config or earlier report.
        let descriptor = open(output.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data(report)); try handle.synchronize(); try handle.close()
    }
}

struct Diagnose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diagnose", abstract: "Read-only redacted diagnostics. Never captures, contacts providers or acquires recording locks.")
    @Option(help: "Recording root to inspect, defaults to the configured root.") var recordings: String?
    @Option(help: "Create a new report file. Existing files are never replaced. Omit for standard output.") var output: String?
    mutating func run() async throws {
        let permissions = await HelperDiagnostics.Permissions.current()
        let report = try HelperDiagnostics.report(root: Config.resolveRoot(cliOverride: recordings), permissions: permissions,
                                                  localModelAvailable: ParakeetEngine.modelsAvailable)
        if let output { try HelperDiagnostics.write(report, to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath)); print("Redacted diagnostic report created.") }
        else { FileHandle.standardOutput.write(try HelperDiagnostics.data(report)) }
    }
}
