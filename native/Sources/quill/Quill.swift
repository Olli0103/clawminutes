import AppKit
import AVFoundation
import ArgumentParser
import Foundation

@main
struct Quill: AsyncParsableCommand {
    /// AppKit owns the main thread for the menu bar. Enter its event loop
    /// before acquiring a Swift async actor executor; otherwise app.run()
    /// holds that executor and starves the scanner and menu callbacks.
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.first == "run" {
            do {
                let command = try Run.parse(arguments.isEmpty ? [] : Array(arguments.dropFirst()))
                try MainActor.assumeIsolated { try command.runMain() }
            } catch { Self.exit(withError: error) }
        } else if arguments.first == "capture-fixture" {
            do {
                var command = try CaptureFixture.parse(Array(arguments.dropFirst()))
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                Task { @MainActor in
                    do { try await command.run(); Darwin.exit(0) }
                    catch { Self.exit(withError: error) }
                }
                app.run()
            } catch { Self.exit(withError: error) }
        } else {
            Task { await Self.main(arguments); Darwin.exit(0) }
            dispatchMain()
        }
    }
    static let configuration = CommandConfiguration(
        commandName: "ocmh",
        abstract: "Meeting recorder + transcriber. Records mic and system audio, then transcribes locally or with ElevenLabs.",
        subcommands: [Run.self, Doctor.self, Meetings.self, Transcribe.self, Transcription.self, SetupLocal.self, CaptureFixture.self, RecoverSessions.self, GatewayStatus.self, ArchiveSession.self, ArchiveBacklogCommand.self, VerifyAudioRetention.self, NameRecordingFolder.self, NameNotesFolder.self, MigrateNotesFolder.self, ExportIcon.self],
        defaultSubcommand: Run.self
    )
}

struct Notifications: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check ocmh's native notifications or send a test.")
    @Flag(help: "Send a test and confirm Notification Center delivery.")
    var test = false

    func run() throws {
        let test = self.test
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                do {
                    var result = try await NativeNotifications.shared.status()
                    if test {
                        let id = try await NativeNotifications.shared.send(title: "ocmh: Notifications are ready", body: "Recording start and stop will appear here.")
                        result = try await NativeNotifications.shared.status()
                        result["status"] = "delivered"
                        result["notification_id"] = id
                    }
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                    Darwin.exit(0)
                } catch {
                    FileHandle.standardError.write(Data("ocmh notification check failed: \(error)\n".utf8))
                    Darwin.exit(1)
                }
            }
            app.run()
        }
    }
}

struct Meetings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect meeting detection without starting a recording.")

    @Flag(help: "Continuously print detection changes until interrupted.")
    var watch = false

    @Flag(help: "Include currently exposed active-speaker names for diagnostics.")
    var speakers = false
    @Flag(help: "Inspect meeting tile accessibility classes without changing the meeting.")
    var speakerBoxes = false

    func run() async throws {
        await MainActor.run { NSApplication.shared.setActivationPolicy(.accessory) }
        try await Self.inspect(watch: watch, speakers: speakers, speakerBoxes: speakerBoxes)
    }

    @MainActor private static func inspect(watch: Bool, speakers: Bool, speakerBoxes: Bool) async throws {
        let scanner = MeetingScanner()
        repeat {
            let apps = MeetingApp.running()
            let scan = await scanner.scan(apps: apps, captureSpeakers: speakers || speakerBoxes, inspectBoxes: speakerBoxes)
            var rows: [[String: String]] = []
            var tileSpeakers: [String: [String]] = [:]
            for (id, observation) in scan.observations.sorted(by: { $0.key < $1.key }) {
                switch observation {
                case .present(let meeting): rows.append(["id": id, "state": "present", "app": meeting.app, "service": meeting.service])
                case .ended: rows.append(["id": id, "state": "ended"])
                case .unknown: rows.append(["id": id, "state": "unknown"])
                }
                if speakers || speakerBoxes, let activity = await scanner.speakerActivity(for: id) {
                    tileSpeakers[id] = activity.names
                }
            }
            let output: [String: Any] = ["needs_accessibility_permission": scan.needsPermission,
                                         "needs_zoom_screen_permission": scan.needsZoomScreenPermission,
                                         "apps": apps.map(\.name), "meetings": rows, "active_speakers": scan.speakers,
                                         "speaker_capture": scan.speakerCaptureStatus,
                                         "speaker_boxes": scan.speakerBoxes,
                                         "participants": scan.rosters.map { observation -> [String: Any] in
                                             ["meeting_id": observation.meeting_id,
                                              "names": (observation.participants ?? []).map(\.name),
                                              "reported_count": observation.participant_count ?? 0,
                                              "complete": observation.roster_complete ?? false]
                                         },
                                         "tile_speakers": tileSpeakers, "observed_at": scan.observedAt,
                                         "zoom_border_scores": await scanner.zoomBorderScores(),
                                         "zoom_capture_status": await scanner.zoomCaptureStatus(),
                                         "captions": scan.captions.map { ["speaker": $0.names.first ?? "", "text": $0.text ?? ""] }]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            if watch { try await Task.sleep(for: .seconds(2)) }
        } while watch
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?
    @Flag(help: "Show the recording controls on launch.")
    var showMenu = false
    @Flag(help: "Show a synthetic Start/Dismiss prompt without starting audio.")
    var promptFixture = false

    func run() async throws {
        try await MainActor.run { try runMain() }
    }

    @MainActor
    fileprivate func runMain() throws {
        guard let runLock = try AppRunLock.acquire() else {
            print("ocmh is already running.")
            return
        }
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root, checkKeychain: false)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = ApplicationMenu.make()
        app.applicationIconImage = HelperAppIcon.image()

        let controller = AppController(root: root, startupOwner: runLock, showMenuOnLaunch: showMenu, promptFixture: promptFixture)
        app.delegate = controller
        Task {
            do { try await NativeNotifications.shared.authorize() }
            catch { FileHandle.standardError.write(Data("ocmh notifications: \(error)\n".utf8)) }

        }

        let terminationSignals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write(Data("\nshutting down\n".utf8))
                MainActor.assumeIsolated { controller.shutdown() }
            }
            source.resume()
            signal(number, SIG_IGN)
            return source
        }

        FileHandle.standardError.write(Data(
            "ocmh running · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        withExtendedLifetime((runLock, terminationSignals, controller)) { app.run() }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let meetings = MeetingAssistant()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var backlogTask: Task<Void, Never>?
    private var startupReady = false
    private var starting = false
    private var stopping = false
    private let showMenuOnLaunch: Bool
    private let promptFixture: Bool

    init(root: URL, startupOwner: AppRunLock, showMenuOnLaunch: Bool = false, promptFixture: Bool = false) {
        self.root = root
        self.showMenuOnLaunch = showMenuOnLaunch
        self.promptFixture = promptFixture
        super.init()
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)
        menuBar.onDetectionToggle = { [weak self] in self?.meetings.toggleEnabled() }
        menuBar.onPermission = { [weak self] in self?.meetings.requestPermission() }
        menuBar.onKeepRecording = { [weak self] in self?.meetings.keepRecording() }
        menuBar.onRetryArchive = { [transcription, root] in
            let report = try await transcription.retryArchiveBacklog(root: root, force: true)
            return report.busy ? "A backlog check is already running" : "Checked pending saves: \(report.attempted) attempted, \(report.pending) waiting"
        }
        meetings.onStart = { [weak self] in
            guard let self, self.session == nil else { return false }
            return await self.startSession()
        }
        meetings.onStop = { [weak self] in self?.stopSession() }
        meetings.onStatus = { [weak self] text, enabled in self?.menuBar.updateDetection(text, enabled: enabled) }
        meetings.onMeetingContext = { [weak self] context in self?.session?.updateMeetingContext(context) }
        meetings.onMeetingTitle = { [weak self] title in self?.menuBar.setMeetingSubject(title) }
        meetings.onSpeakers = { [weak self] observation in self?.session?.recordSpeakers(observation) }

        backlogTask = Task { [weak self, transcription, root] in
            await transcription.setBacklogHandler { [weak self] count in
                Task { @MainActor [weak self] in self?.menuBar.pendingArchiveCount = count }
            }
            await transcription.setStatusHandler { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            while !Task.isCancelled {
                if await transcription.resumePending(root: root, startupOwner: startupOwner) { break }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.startupReady = true
            self.meetings.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
                do { _ = try await transcription.retryArchiveBacklog(root: root) }
                catch { FileHandle.standardError.write(Data("Archive backlog check unavailable. Recordings preserved.\n".utf8)) }
            }
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        backlogTask?.cancel()
        meetings.shutdown()
        Task {
            if let session { await finishSession(session) }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    private func toggle() {
        if session == nil {
            beginSession()
        } else {
            stopSession()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if showMenuOnLaunch { menuBar.showSettings() }
        if promptFixture {
            Task {
                let panel = MeetingConsentPanel(fixture: true)
                let response = await panel.present()
                FileHandle.standardError.write(Data("Prompt fixture accepted: \(response). No fixture audio is started by this UI-only diagnostic.\n".utf8))
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar.showSettings()
        return true
    }
    func showMenu() { menuBar.openMenu() }
    private func beginSession() {
        Task { _ = await startSession() }
    }
    @discardableResult private func startSession() async -> Bool {
        guard startupReady, !starting, session == nil else { return false }
        starting = true
        menuBar.setStartingRecording(true)
        defer { starting = false; menuBar.setStartingRecording(false) }
        do {
            let newSession = try RecordingSession(root: root, context: meetings.contextForStart)
            try await newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            menuBar.recordingFailed(error)
            return false
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = HousekeepingTimer.schedule(every: 1) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        meetings.recordingStarted()
        return true
    }

    private func stopSession() {
        guard let session, !stopping else { return }
        stopping = true
        Task { await finishSession(session); stopping = false }
    }

    private func finishSession(_ session: RecordingSession) async {
        await session.stopAsync()
        let elapsed = Self.format(Date().timeIntervalSince(session.audioStartedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        meetings.recordingStopped()
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        menuBar.updateTranscriptionStatus(status)
    }

    private func tick() {
        guard let session else { return }
        session.checkpoint()
        menuBar.updateCaptureWarning(session.captureWarning)
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.audioStartedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
