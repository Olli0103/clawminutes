import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import FluidAudio

@MainActor
final class MenuBarController: NSObject, ObservableObject, NSWindowDelegate, NSPopoverDelegate {
    let appState = AppState()
    private let keychain: ElevenLabsKeychain
    private let statusItem: NSStatusItem?
    private let previewMode: Bool
    private let loginItem = HelperLoginItem()
    private(set) var loginStatus: HelperLoginItem.Status {
        get { appState.loginStatus }
        set { objectWillChange.send(); appState.loginStatus = newValue }
    }
    private(set) var loginSettingError: String? {
        get { appState.loginSettingError }
        set { objectWillChange.send(); appState.loginSettingError = newValue }
    }
    func refreshLoginSetting() {
        guard !previewMode else { return }
        loginStatus = loginItem.status(); loginSettingError = nil
    }
    func setLaunchAtLogin(_ value: Bool) {
        guard !previewMode else { return }
        do {
            loginStatus = try loginItem.setEnabled(value, expected: loginStatus)
            loginSettingError = nil
        } catch {
            loginSettingError = String(describing: error)
            loginStatus = loginItem.status()
        }
    }
    private var appearanceObserver: NSKeyValueObservation?
    private var applicationAppearanceObserver: NSKeyValueObservation?
    private let popover = NSPopover()
    private(set) var storageSummary: String {
        get { appState.storageSummary }
        set { objectWillChange.send(); appState.storageSummary = newValue }
    }
    func checkStorage() {
        Task {
            let root = Config.resolveRoot(cliOverride: nil)
            let storage = try? await Task.detached { try RecordingStorage.measure(root: root) }.value
            if let storage {
                appState.recordingBytes = storage.audio; appState.freeBytes = storage.free; appState.capacityBytes = storage.capacity
                storageSummary = ByteCountFormatter.string(fromByteCount: storage.audio, countStyle: .file) + " of audio"
            } else { storageSummary = "Recording storage could not be checked." }
        }
    }
    private var meetingWindow: NSWindow?
    private var attentionWindow: NSWindow?
    private var libraryWindow: NSWindow?
    func showAttentionGroup(_ group: AttentionGroup) {
        popover.performClose(nil)
        let window = attentionWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = group.title
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentViewController = NSHostingController(rootView: AttentionReviewView(controller: self, groupID: group.id,
            close: { [weak window] in window?.close() }))
        if attentionWindow == nil { window.center() }
        attentionWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func showLibrary() {
        popover.performClose(nil)
        let window = libraryWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ClawMinutes meetings"; window.isReleasedWhenClosed = false; window.delegate = self
        if libraryWindow == nil {
            window.contentViewController = NSHostingController(rootView: MeetingLibraryView(controller: self))
            window.center()
        }
        libraryWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === libraryWindow {
            window.contentViewController = nil
            libraryWindow = nil // Releases the search view and its memory-only text cache.
        } else if window === attentionWindow {
            window.contentViewController = nil; attentionWindow = nil
        } else if window === migrationWindow {
            window.contentViewController = nil; migrationWindow = nil; copyingNotes = false
        } else if window === controlsWindow {
            appState.popoverVisible = false; enableAudioMeters?(false)
        } else if window === cleanupWindow {
            window.contentViewController = nil; cleanupWindow = nil; deletingAudio = false
        }
    }
    private var cleanupWindow: NSWindow?
    private var deletingAudio = false
    private var migrationWindow: NSWindow?
    private var copyingNotes = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === setupWindow { return !captureCheckBusy }
        if sender === migrationWindow { return !copyingNotes }
        if sender === cleanupWindow { return !deletingAudio }
        return true
    }
    func copyExistingNotes(_ selection: [RecentMeeting]? = nil) {
        if let migrationWindow { migrationWindow.makeKeyAndOrderFront(nil); return }
        let meetings = selection ?? recentMeetings.filter { $0.ready }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a destination for copies of existing notes. You will review the meetings before copying. Originals stay in place."
        panel.prompt = "Review destination"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Copy existing notes"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentViewController = NSHostingController(rootView: NotesMigrationView(controller: self, meetings: meetings, destination: destination,
                onClose: { [weak window] in window?.close() }, onBusyChange: { [weak self, weak window] active in
                    self?.copyingNotes = active
                    window?.standardWindowButton(.closeButton)?.isEnabled = !active
                }))
            self.migrationWindow = window
            window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
    }
    func reviewRecordedAudio(_ selection: [RecentMeeting]? = nil) {
        if let cleanupWindow { cleanupWindow.makeKeyAndOrderFront(nil); return }
        let meetings = selection ?? recentMeetings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Delete old audio"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentViewController = NSHostingController(rootView: AudioCleanupView(controller: self, meetings: meetings,
            onClose: { [weak window] in window?.close() }, onBusyChange: { [weak self, weak window] active in
                self?.deletingAudio = active
                window?.standardWindowButton(.closeButton)?.isEnabled = !active
            }))
        cleanupWindow = window
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func refreshLocalMeetings() async {
        let root = Config.resolveRoot(cliOverride: nil), notesRoot = MeetingNotesSettings.folder
        let snapshot = try? await Task.detached {
            try ArchiveBacklog.scan(root: root, notesRoot: notesRoot).reversed().filter { $0.state != .fixture }.map { RecentMeeting.make($0) }
        }.value
        if let snapshot { updateRecentMeetings(snapshot) }
    }
    func copyNotes(_ meeting: RecentMeeting) {
        guard let file = meeting.notes, let data = try? ArchiveBacklog.read(file),
              let text = String(data: data, encoding: .utf8) else {
            showError("These notes could not be read. Open the meeting details to check its files."); return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private(set) var diagnosing: Bool {
        get { appState.diagnosing }
        set { objectWillChange.send(); appState.diagnosing = newValue }
    }
    func saveDiagnostics() {
        guard !diagnosing else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClawMinutes-diagnostics-\(Int(Date().timeIntervalSince1970)).json"
        panel.message = "A redacted report excludes audio, speech, notes, names, paths and credentials. It does not contact your Gateway. Choose a new file."
        panel.begin { [weak self] response in
            guard response == .OK, let output = panel.url, let self else { return }
            self.diagnosing = true
            let permissions = HelperDiagnostics.Permissions.current()
            let root = Config.resolveRoot(cliOverride: nil)
            let ready = self.localModelReady
            Task {
                defer { self.diagnosing = false }
                do {
                    try await Task.detached {
                        let report = try await HelperDiagnostics.observedReport(root: root, permissions: permissions, localModelAvailable: ready,
                            instanceLock: AppRunLock.path, workerExecutable: Bundle.main.executableURL)
                        try HelperDiagnostics.write(report, to: output)
                    }.value
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } catch { self.showError("Could not create the diagnostic report. Choose a new file in a writable folder.") }
            }
        }
    }
    private(set) var recentMeetings: [RecentMeeting] {
        get { appState.recentMeetings }
        set { objectWillChange.send(); appState.recentMeetings = newValue }
    }
    private(set) var meetingSnapshotRevision: UInt64 {
        get { appState.meetingSnapshotRevision }
        set { objectWillChange.send(); appState.meetingSnapshotRevision = newValue }
    }
    private var pendingNotesOpen: String?
    func updateRecentMeetings(_ value: [RecentMeeting]) {
        recentMeetings = value
        meetingSnapshotRevision &+= 1
        refreshTitle()
        if let pendingNotesOpen, let notes = value.first(where: { $0.id == pendingNotesOpen })?.notes {
            self.pendingNotesOpen = nil; NSWorkspace.shared.open(notes)
        }
    }
    func openNotes(notificationMeetingID: String?) {
        guard let notificationMeetingID else { return }
        if let notes = recentMeetings.first(where: { $0.id == notificationMeetingID })?.notes { NSWorkspace.shared.open(notes) }
        else { pendingNotesOpen = notificationMeetingID }
    }
    private var templateWindow: NSWindow?
    private var setupWindow: NSWindow?
    private let captureCheck: CaptureCheckRunner
    private var captureCheckTask: Task<Void, Never>?
    private(set) var captureCheckPhase: CaptureCheckRunner.Phase? {
        get { appState.captureCheckPhase }
        set { objectWillChange.send(); appState.captureCheckPhase = newValue; refreshTitle() }
    }
    private(set) var captureCheckReport: CaptureCheckRunner.Report? {
        get { appState.captureCheckReport }
        set { objectWillChange.send(); appState.captureCheckReport = newValue }
    }
    private(set) var captureCheckError: String? {
        get { appState.captureCheckError }
        set { objectWillChange.send(); appState.captureCheckError = newValue }
    }
    private(set) var captureCheckAllowed: Bool {
        get { appState.captureCheckAllowed }
        set { objectWillChange.send(); appState.captureCheckAllowed = newValue }
    }
    var captureCheckBusy: Bool { captureCheckPhase != nil }
    var gatewayReady: Bool { gatewayConnected }
    func enableCaptureCheck() { captureCheckAllowed = true }
    func refreshSetupChecks() {
        checkPermissions(); refreshCredentials()
        localModelReady = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }
    func startCaptureCheck() {
        guard captureCheckAllowed, !recording, !startingRecording, captureCheckTask == nil else { return }
        captureCheckPhase = .starting; captureCheckReport = nil; captureCheckError = nil
        captureCheckTask = Task {
            defer { captureCheckTask = nil; captureCheckPhase = nil }
            do { captureCheckReport = try await captureCheck.run { captureCheckPhase = $0 } }
            catch { captureCheckError = "The audio check could not start. Check permissions and finish any other recording or check, then try again." }
        }
    }
    func cancelCaptureCheck() { captureCheckTask?.cancel() }
    func stopCaptureCheck() async {
        let task = captureCheckTask
        task?.cancel(); await task?.value
    }
    func showSetup() {
        popover.performClose(nil)
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 700),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Set up ClawMinutes"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentViewController = NSHostingController(rootView: SetupChecklistView(controller: self))
            window.center(); setupWindow = window
        }
        UserDefaults.standard.set(true, forKey: "clawMinutesSetupShownV1")
        refreshSetupChecks()
        NSApp.activate(ignoringOtherApps: true); setupWindow?.makeKeyAndOrderFront(nil)
    }
    private var settingsWindow: NSWindow?
    private var controlsWindow: NSWindow?
    private var pipelineStatus: TranscriptionCoordinator.Status {
        get { appState.pipelineStatus }
        set { objectWillChange.send(); appState.pipelineStatus = newValue }
    }
    private var preparing: Bool {
        get { appState.preparing }
        set { objectWillChange.send(); appState.preparing = newValue }
    }
    private var transcriptionBackend: String? {
        get { appState.transcriptionBackend }
        set { objectWillChange.send(); appState.transcriptionBackend = newValue }
    }
    private var renderedIconState: String?
    private var credentialOperationInProgress = false
    private var keyStatusTask: Task<Void, Never>?
    private(set) var recording: Bool {
        get { appState.recording }
        set { objectWillChange.send(); appState.recording = newValue }
    }
    private(set) var startingRecording: Bool {
        get { appState.startingRecording }
        set { objectWillChange.send(); appState.startingRecording = newValue }
    }
    private(set) var elapsed: String {
        get { appState.elapsed }
        set { objectWillChange.send(); appState.elapsed = newValue }
    }
    private(set) var detail: String? {
        get { appState.detail }
        set { objectWillChange.send(); appState.detail = newValue }
    }
    var captureHealth: String {
        get { appState.captureHealth }
        set { objectWillChange.send(); appState.captureHealth = newValue }
    }
    private(set) var captureWarning: String? {
        get { appState.captureWarning }
        set { objectWillChange.send(); appState.captureWarning = newValue }
    }
    func updateCaptureWarning(_ value: String?) {
        guard captureWarning != value else { return }
        captureWarning = value; refreshTitle()
    }
    private(set) var detection: String {
        get { appState.detection }
        set { objectWillChange.send(); appState.detection = newValue }
    }
    private(set) var promptsEnabled: Bool {
        get { appState.promptsEnabled }
        set { objectWillChange.send(); appState.promptsEnabled = newValue }
    }
    private(set) var accessibilityGranted: Bool {
        get { appState.accessibilityGranted }
        set { objectWillChange.send(); appState.accessibilityGranted = newValue }
    }
    private(set) var gatewayStatus: String {
        get { appState.gatewayStatus }
        set { objectWillChange.send(); appState.gatewayStatus = newValue }
    }
    private(set) var gatewayOperation: Bool {
        get { appState.gatewayOperation }
        set { objectWillChange.send(); appState.gatewayOperation = newValue }
    }
    private var gatewayConnected = false
    private(set) var gatewaySigningIn: Bool {
        get { appState.gatewaySigningIn }
        set { objectWillChange.send(); appState.gatewaySigningIn = newValue }
    }
    var pendingArchiveCount: Int {
        get { appState.pendingArchiveCount }
        set { objectWillChange.send(); appState.pendingArchiveCount = newValue }
    }
    var onSpeechCredentialsInstalled: (() async throws -> Void)?
    var onLocalModelInstalled: (() async throws -> Void)?
    var onRetryArchive: ((GatewayCapabilities?) async throws -> String)?
    var onTextPrepared: (() async throws -> Void)?
    func queuePreparedText() async { try? await onTextPrepared?() }
    private var gatewayCancelled = false
    private(set) var hasAPIKey: Bool {
        get { appState.hasAPIKey }
        set { objectWillChange.send(); appState.hasAPIKey = newValue }
    }
    private(set) var localModelReady: Bool {
        get { appState.localModelReady }
        set { objectWillChange.send(); appState.localModelReady = newValue }
    }
    private(set) var selectedEngine: String {
        get { appState.selectedEngine }
        set { objectWillChange.send(); appState.selectedEngine = newValue }
    }
    private(set) var style: MenuBarStyle {
        get { appState.style }
        set { objectWillChange.send(); appState.style = newValue }
    }
    private(set) var notesMode: String {
        get { appState.notesMode }
        set { objectWillChange.send(); appState.notesMode = newValue }
    }
    private(set) var templates: [NoteTemplate] {
        get { appState.templates }
        set { objectWillChange.send(); appState.templates = newValue }
    }
    private(set) var selectedTemplateID: String {
        get { appState.selectedTemplateID }
        set { objectWillChange.send(); appState.selectedTemplateID = newValue }
    }
    private(set) var notesFolder: String {
        get { appState.notesFolder }
        set { objectWillChange.send(); appState.notesFolder = newValue }
    }
    private(set) var deletesVerifiedAudio: Bool {
        get { appState.deletesVerifiedAudio }
        set { objectWillChange.send(); appState.deletesVerifiedAudio = newValue }
    }
    func setAudioRetention(_ enabled: Bool) {
        do {
            try MeetingNotesSettings.update(["audio_retention": enabled ? "delete_after_verification" : "keep",
                                             "audio_retention_opted_in_at": Date().timeIntervalSince1970])
            deletesVerifiedAudio = enabled
        } catch { showError("Could not save audio retention: \(error)") }
    }
    private(set) var localSpeakerName: String {
        get { appState.localSpeakerName }
        set { objectWillChange.send(); appState.localSpeakerName = newValue }
    }
    private(set) var sharedMicrophone: Bool {
        get { appState.sharedMicrophone }
        set { objectWillChange.send(); appState.sharedMicrophone = newValue }
    }
    func setSharedMicrophone(_ value: Bool) {
        do { try MeetingNotesSettings.update(["shared_microphone": value]); sharedMicrophone = value }
        catch { showError("Could not save microphone setting: \(error)") }
    }
    func editLocalSpeakerName() {
        let alert = NSAlert(); alert.messageText = "Your microphone name"
        alert.informativeText = "Use your Teams display name for speech on your personal microphone. Remote speakers still need Teams evidence. For a shared microphone, enable Shared microphone instead."
        let field = NSTextField(string: localSpeakerName); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || SpeakerAttribution.cleanName(value) != nil else { showError("Enter your display name, up to 100 characters."); return }
        do { try MeetingNotesSettings.update(["local_speaker_name": value]); localSpeakerName = value }
        catch { showError("Could not save microphone name: \(error)") }
    }
    private(set) var meetingSubject: String? {
        get { appState.meetingSubject }
        set { objectWillChange.send(); appState.meetingSubject = newValue }
    }
    func setMeetingSubject(_ subject: String?) {
        guard meetingSubject != subject else { return }
        meetingSubject = subject; refreshTitle()
    }
    var audioLevels: (() -> (Float, Float))?
    var enableAudioMeters: ((Bool) -> Void)?
    func popoverDidClose(_ notification: Notification) {
        appState.popoverVisible = false; enableAudioMeters?(false)
    }
    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDetectionToggle: (() -> Void)?
    var onPermission: (() -> Void)?
    var onKeepRecording: (() -> Void)?

    var activity: HelperActivity {
        if let phase = captureCheckPhase {
            switch phase {
            case .starting: return .audioCheck("Starting")
            case .recording(let remaining): return .audioCheck("\(remaining)s")
            case .stopping: return .audioCheck("Stopping")
            }
        }
        return MenuPresentation.activity(recording: recording, elapsed: elapsed, status: pipelineStatus, preparing: preparing || startingRecording)
    }
    var displayedBackend: String { recording ? selectedEngine : (transcriptionBackend ?? selectedEngine) }
    var backendTitle: String { captureCheckBusy ? "Audio stays here" : displayedBackend == "parakeet" ? "Local only" : "ElevenLabs" }
    var modelTitle: String { captureCheckBusy ? "No transcription" : displayedBackend == "parakeet" ? "Parakeet v3" : "Scribe v2" }
    var machine: String { ProcessInfo.processInfo.hostName }
    var meetingTitle: String {
        meetingSubject ?? MenuPresentation.meetingTitle(promptsEnabled: promptsEnabled, accessibilityGranted: accessibilityGranted, detection: detection)
    }
    func setStartingRecording(_ value: Bool) { startingRecording = value; refreshTitle() }
    var isFailure: Bool { switch activity { case .failed, .archivePending: return true; default: return false } }

    init(keychain: ElevenLabsKeychain = .shared, preview: Bool = false, captureCheck: CaptureCheckRunner = CaptureCheckRunner()) {
        self.keychain = keychain
        self.captureCheck = captureCheck
        self.previewMode = preview
        statusItem = preview ? nil : NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        loginStatus = preview ? .preview : loginItem.status()
        if let app = NSApp {
            applicationAppearanceObserver = app.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
                Task { @MainActor in NSApp.applicationIconImage = HelperAppIcon.image() }
            }
        }
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: HelperPopover(controller: self))
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(showPopover)
            button.imagePosition = .imageLeft
            appearanceObserver = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshTitle() }
            }
        }
        refreshTitle()
        if !preview {
            refreshCredentials()
            Task { await checkGateway() }
        }
    }

    func recordingFailed(_ error: Error) {
        let failure = error as NSError
        let microphone = error is RecordingPermissionError
        let systemAudio = failure.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && failure.code == -3801
        guard microphone || systemAudio else {
            showError("Could not start recording. " + String(describing: error)); return
        }
        let alert = NSAlert()
        alert.messageText = microphone ? "Allow microphone recording" : "Allow Teams audio recording"
        alert.informativeText = microphone
            ? "Enable ocmh in Microphone in System Settings, then try Start again. Recording remains off."
            : "Enable ocmh in the upper Screen & System Audio Recording list in System Settings. macOS requires this permission; ocmh saves only audio. Reopen ocmh after allowing access. Recording remains off."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openPrivacy(microphone ? "Microphone" : "ScreenCapture") }
    }
    func openMenu() {
        popover.performClose(nil)
        if controlsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClawMinutes"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: HelperPopover(controller: self))
            window.center()
            controlsWindow = window
        }
        accessibilityGranted = AXIsProcessTrusted()
        refreshCredentials()
        NSApp.activate(ignoringOtherApps: true)
        appState.popoverVisible = true
        controlsWindow?.makeKeyAndOrderFront(nil)
        Task { await checkGateway() }
    }
    @objc private func showPopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        accessibilityGranted = AXIsProcessTrusted()
        refreshCredentials()
        Task { await checkGateway() }
        appState.popoverVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func toggleRecording() { if captureCheckBusy { cancelCaptureCheck() } else { onToggle?() } }
    func openMeeting(_ meeting: RecentMeeting) {
        popover.performClose(nil)
        if !meeting.needsAttention, let notes = meeting.notes { NSWorkspace.shared.open(notes); return }
        showMeetingDetails(meeting)
    }
    func showMeetingDetails(_ meeting: RecentMeeting) {
        popover.performClose(nil)
        let window = meetingWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = meeting.title; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MeetingDetailView(controller: self, meetingID: meeting.id))
        if meetingWindow == nil { window.center() }
        meetingWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func renameMeeting(_ meeting: RecentMeeting, title: String) async -> Bool {
        guard meeting.stage != .capturing && meeting.stage != .delivering else { return false }
        do {
            try await Task.detached { try MeetingTitleOverride.save(title, in: meeting.directory) }.value
            await refreshLocalMeetings(); return true
        } catch { return false }
    }
    func openDocument(_ url: URL) { NSWorkspace.shared.open(url) }
    func openRecordings() { popover.performClose(nil); onOpenFolder?() }
    func quit() { popover.performClose(nil); onQuit?() }
    func togglePrompts() { onDetectionToggle?() }
    func allowDetection() {
        popover.performClose(nil)
        onPermission?()
    }
    func chooseStyle(_ value: MenuBarStyle) {
        guard Config.setMenuBarStyle(value) else { showError("Could not save menu bar style."); return }
        style = value
        refreshTitle()
    }
    func chooseNotes(_ mode: String) {
        guard Config.setNotesMode(mode) else { showError("Could not save notes setting."); return }
        notesMode = mode
    }
    func selectTemplate(_ id: String) {
        do { try MeetingNotesSettings.save(templates, selected: id); selectedTemplateID = id }
        catch { showError("Could not save note template: \(error)") }
    }
    func saveTemplates(_ value: [NoteTemplate], selected: String) -> Bool {
        do { try MeetingNotesSettings.save(value, selected: selected); templates = value; selectedTemplateID = selected; return true }
        catch { showError("Could not save templates: \(error)"); return false }
    }
    func chooseNotesFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose a folder for generated meeting notes and transcripts."; panel.directoryURL = MeetingNotesSettings.folder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try MeetingNotesSettings.update(["notes_folder": folder.path]); notesFolder = folder.path }
        catch { showError("Could not save notes folder: \(error)") }
    }
    func openNotesFolder() {
        let folder = MeetingNotesSettings.folder
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
        catch { showError("Could not open notes folder: \(error)") }
    }
    func manageTemplates() {
        if templateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ClawMinutes note templates"; window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: NoteTemplateEditor(controller: self))
            window.center(); templateWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); templateWindow?.makeKeyAndOrderFront(nil)
    }
    func selectEngine(_ value: String) {
        guard let index = TranscriptionEngineKind.allCases.firstIndex(where: { $0.rawValue == value }) else { return }
        let item = NSMenuItem(); item.tag = index
        engineClicked(item)
    }
    func showSettings() { showSettings(page: appState.settingsPage) }
    func showSettings(page: HelperSettingsPage) {
        refreshLoginSetting()
        popover.performClose(nil)
        appState.settingsPage = page
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: page.preferredHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = page.rawValue
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: HelperSettings(controller: self))
            window.center()
            settingsWindow = window
        }
        fitSettingsWindow(page)
        refreshCredentials()
        accessibilityGranted = AXIsProcessTrusted()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Task { await checkGateway() }
    }
    func fitSettingsWindow(_ page: HelperSettingsPage) {
        guard let window = settingsWindow else { return }
        window.title = page.rawValue
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 690, height: page.preferredHeight))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func connectGateway() { guard !previewMode else { return }; popover.performClose(nil); gatewayClicked() }
    func cancelSignIn() { cancelGatewayClicked() }
    func retrySaving() { guard !previewMode else { return }; retryArchiveClicked() }
    func setupLocal() { guard !previewMode else { return }; popover.performClose(nil); setupLocalClicked() }
    func editAPIKey() { guard !previewMode else { return }; apiKeyClicked() }
    func removeAPIKey() { guard !previewMode else { return }; removeKeyClicked() }
    func keepRecording() { onKeepRecording?() }
    func checkPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        objectWillChange.send()
    }
    var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var systemAudioGranted: Bool { CGPreflightScreenCaptureAccess() }
    func allowMicrophone() {
        guard !previewMode else { return }
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            if !microphoneGranted { openPrivacy("Microphone") }
            checkPermissions()
        }
    }
    func allowSystemAudio() {
        guard !previewMode else { return }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess() { openPrivacy("ScreenCapture") }
        checkPermissions()
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane) { NSWorkspace.shared.open(url) }
    }
    func recheckGateway() { Task { await checkGateway() } }
    private func checkGateway() async {
        guard !previewMode else { return }
        guard !gatewayOperation else { return }
        gatewayOperation = true
        defer { gatewayOperation = false }
        let wasConnected = gatewayConnected
        let capabilities: GatewayCapabilities
        do {
            capabilities = try await GatewayArchive.status()
            gatewayStatus = capabilities.description
            gatewayConnected = true
        }
        catch {
            gatewayConnected = false
            gatewayStatus = DeliveryFailure.classify(error).detail
            return
        }
        if !wasConnected {
            do { _ = try await onRetryArchive?(capabilities) }
            catch { gatewayStatus += "\nPending saves could not be checked. Files preserved." }
        }
    }
    private func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "ocmh"; alert.informativeText = text; alert.runModal()
    }

    @objc private func gatewayClicked() {
        guard !gatewayOperation else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect the recording helper to your Gateway"
        alert.informativeText = "GitHub sign-in opens Cloudflare Access in your browser. Local only sends finished transcript text and metadata to the Gateway. Raw audio stays here. For direct Gateway auth, select Gateway token and enter it below."
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        let urlField = NSTextField(frame: NSRect(x: 0, y: 70, width: 420, height: 26))
        urlField.stringValue = Config.gateway()["url"] ?? ""
        urlField.placeholderString = "https://your-gateway.example"
        urlField.setAccessibilityLabel("Gateway URL")
        let method = NSPopUpButton(frame: NSRect(x: 0, y: 36, width: 420, height: 26))
        method.addItems(withTitles: ["GitHub through Cloudflare Access", "Gateway token"])
        method.selectItem(at: Config.gateway()["authentication"] == "token" ? 1 : 0)
        let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        secret.placeholderString = "Gateway token, only for direct token authentication"
        secret.setAccessibilityLabel("Gateway token")
        [urlField, method, secret].forEach { container.addSubview($0) }
        alert.accessoryView = container
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let authentication = method.indexOfSelectedItem == 0 ? "cloudflare" : "token"
        let token = secret.stringValue
        secret.stringValue = ""
        gatewayOperation = true
        gatewayCancelled = false
        gatewayStatus = "Connecting Gateway…"
        Task {
            defer { gatewayOperation = false; gatewaySigningIn = false }
            do {
                let url = try GatewayArchive.origin(value)
                if authentication == "cloudflare" {
                    let cached = await Task.detached { (try? GatewayArchive.cloudflareToken(url)) != nil }.value
                    if !cached {
                        gatewaySigningIn = true
                        gatewayStatus = "Opening GitHub sign-in…"
                        try await Task.detached { try GatewayArchive.login(url) }.value
                        gatewaySigningIn = false
                    }
                } else {
                    try await Task.detached { try GatewayArchive.tokenStore(url).save(token) }.value
                }
                guard !gatewayCancelled else { return }
                try Config.setGateway(url: value, authentication: authentication)
                let capabilities = try await GatewayArchive.status()
                gatewayStatus = capabilities.description
                gatewayConnected = true
                do { _ = try await onRetryArchive?(capabilities) }
                catch { gatewayStatus += "\nPending saves could not be checked. Files preserved." }
            } catch {
                guard !gatewayCancelled else { return }
                gatewayConnected = false
                let unavailableRoute = error is GatewayArchive.ConnectionIssue
                gatewayStatus = unavailableRoute ? "Teams endpoint unavailable · HTTP 404" : "Gateway connection failed; recordings retained"
                let failure = NSAlert()
                failure.messageText = unavailableRoute ? "Check the Gateway plugin connection" : "Could not connect to the Gateway"
                failure.informativeText = String(describing: error)
                failure.runModal()
            }
        }
    }

    @objc private func cancelGatewayClicked() {
        gatewayCancelled = true
        GatewayArchive.cancelLogin()
        gatewayStatus = "Gateway sign-in cancelled; recordings retained"
    }

    @objc private func retryArchiveClicked() {
        guard !gatewayOperation else { return }
        gatewayOperation = true
        gatewayStatus = "Saving pending meetings"
        Task {
            defer { gatewayOperation = false }
            do {
                let capabilities = try? await GatewayArchive.status()
                gatewayStatus = try await onRetryArchive?(capabilities) ?? "Backlog check is not ready"
            } catch { gatewayStatus = "Archive pending; reconnect Gateway. Recordings retained" }
        }
    }

    @objc private func setupLocalClicked() {
        let alert = NSAlert()
        alert.messageText = "Download the Local only model to this Mac?"
        alert.informativeText = "Downloads Parakeet speech recognition models. No recording audio is sent. This download needs Internet access; subsequent recognition runs offline."
        alert.addButton(withTitle: "Download models")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateTranscription("Installing local speech model")
        Task {
            do {
                var setup = SetupLocal(); try await setup.run(); updateTranscription(nil); localModelReady = true
                try await onLocalModelInstalled?()
            }
            catch { updateTranscription("Local model setup failed: \(error)") }
        }
    }

    func update(recording: Bool, elapsed: String?) {
        if recording && !self.recording { captureWarning = nil; appState.micLost = false }
        if !recording { enableAudioMeters?(false) }
        self.recording = recording
        self.elapsed = elapsed ?? "0:00"
        refreshTitle()
    }

    func updateTranscription(_ text: String?) {
        preparing = text != nil && !(text?.contains("failed") ?? false)
        if let text, text.contains("failed") { pipelineStatus = .failed(session: "Local model setup") }
        detail = text
        refreshTitle()
    }

    func updateTranscriptionStatus(_ status: TranscriptionCoordinator.Status) {
        pipelineStatus = status
        switch status {
        case .recognizingChunk(let name, _), .transcribing(let name, _), .postprocessing(let name, _), .failed(let name), .archivePending(let name), .needsReview(let name, _):
            let metaURL = Config.resolveRoot(cliOverride: nil).appendingPathComponent(name).appendingPathComponent("meta.json")
            let data = try? Data(contentsOf: metaURL)
            if let data, let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                transcriptionBackend = meta["backend"] as? String
            }
            let transcript = recording ? nil : try? ArchiveBacklog.read(metaURL.deletingLastPathComponent().appendingPathComponent("transcript.json"))
            captureWarning = MenuPresentation.restoredCaptureWarning(recording: recording, current: captureWarning, metadata: data, transcript: transcript)
        case .idle: transcriptionBackend = nil
        }
        detail = MenuPresentation.pipelineDetail(status)
        refreshTitle()
    }

    func updateDetection(_ text: String, enabled: Bool) {
        let wasDetected = appState.callDetected
        if detection != text { detection = text }
        if appState.callDetected && !wasDetected { appState.callDetectedAt = Date() }
        if !appState.callDetected { appState.callDetectedAt = nil }
        if promptsEnabled != enabled { promptsEnabled = enabled }
        let granted = AXIsProcessTrusted()
        if accessibilityGranted != granted { accessibilityGranted = granted }
        refreshTitle()
    }

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        let activity = activity
        let title = MenuPresentation.title(style: style, activity: activity, backend: backendTitle, meeting: captureCheckBusy ? nil : meetingSubject == nil ? MenuPresentation.callSummary(meetingTitle) : "Teams call")
            + (!captureCheckBusy && captureWarning != nil && style == .descriptive ? " · Audio gap" : "")
        if button.title != title { button.title = title }
        let appearance = button.effectiveAppearance
        let attention = appState.attentionMeetings.count
        let state = "\(recording)-\(attention)-\(captureCheckBusy)"
        if renderedIconState != state {
            renderedIconState = state
            button.contentTintColor = nil
            button.image = ClawMicrophoneIcon.image(appearance: appearance)
            button.subviews.filter { $0.identifier?.rawValue == "cm-status-badge" }.forEach { $0.removeFromSuperview() }
            if recording || captureCheckBusy || attention > 0 {
                let badge = NSTextField(labelWithString: recording || captureCheckBusy ? "●" : "!")
                badge.identifier = NSUserInterfaceItemIdentifier("cm-status-badge")
                badge.font = .systemFont(ofSize: 9, weight: .bold)
                badge.textColor = recording || captureCheckBusy ? .systemRed : .labelColor
                badge.frame = NSRect(x: 17, y: 0, width: 9, height: 12)
                badge.setAccessibilityLabel(recording ? "Recording" : captureCheckBusy ? "Checking audio" : "\(attention) meetings to finish")
                button.addSubview(badge)
            }
        }
        let tip = captureCheckBusy ? "ClawMinutes · \(activity.title)\nMicrophone and Teams audio check. No transcription or upload. Test audio is discarded." : "ocmh · \(activity.title)\n\(meetingTitle)\n\(backendTitle) · \(modelTitle)\n\(displayedBackend == "parakeet" ? "Speech recognition on " + ProcessInfo.processInfo.hostName : "Speech recognition at ElevenLabs; audio uploaded from this Mac")" + (captureWarning.map { "\n" + $0 } ?? "")
        if button.toolTip != tip { button.toolTip = tip }
        let label = "ocmh. \(activity.title). \(meetingTitle). \(backendTitle)."
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
    }

    @objc private func voiceMemoryClicked() {
        do { try Config.setVoiceMemoryEnabled(!Config.voiceMemoryEnabled()) }
        catch { notifyUser(title: "ocmh speaker memory", body: "Could not save the speaker memory setting: \(error)") }
    }

    func refreshCredentials() {
        guard !previewMode else { return }
        guard keyStatusTask == nil, !credentialOperationInProgress else { return }
        keyStatusTask = Task { [weak self, keychain] in
            let hasKey = await Task.detached { [keychain] in keychain.containsKey() }.value
            guard let self else { return }
            self.keyStatusTask = nil
            guard !self.credentialOperationInProgress else { return }
            self.hasAPIKey = hasKey
        }
    }

    @objc private func engineClicked(_ sender: NSMenuItem) {
        guard !credentialOperationInProgress else { return }
        credentialOperationInProgress = true
        Task {
            defer { credentialOperationInProgress = false }
            let kind = TranscriptionEngineKind.allCases[sender.tag]
            if kind == .elevenLabs {
                let hasKey = await Task.detached { [keychain] in keychain.containsKey() }.value
                if !hasKey, !(await enterAPIKey()) { return }
            }
            guard Config.setTranscriptionEngine(kind) else {
                notifyUser(title: "ocmh settings", body: "Could not save the transcription engine setting.")
                return
            }
            selectedEngine = kind.rawValue
            refreshTitle()
            notifyUser(title: "ocmh transcription", body: "\(kind.title) will be used for the next transcription.")
        }
    }

    @objc private func apiKeyClicked() {
        guard !credentialOperationInProgress else { return }
        credentialOperationInProgress = true
        Task {
            defer { credentialOperationInProgress = false }
            _ = await enterAPIKey()
        }
    }

    @discardableResult private func enterAPIKey() async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ElevenLabs API key"
        alert.informativeText = "Your key is stored encrypted in macOS Keychain. Selecting ElevenLabs sends recording audio to Scribe v2 for transcription."
        alert.addButton(withTitle: "Save key")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.usesSingleLineMode = true
        field.placeholderString = "Paste your ElevenLabs API key"
        field.setAccessibilityLabel("ElevenLabs API key")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let value = field.stringValue
        field.stringValue = ""
        do {
            try await Task.detached { [keychain] in try keychain.save(value) }.value
            hasAPIKey = true
            try? await onSpeechCredentialsInstalled?()
            notifyUser(title: "ocmh settings", body: "ElevenLabs API key saved in macOS Keychain.")
            return true
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let failure = NSAlert()
            failure.messageText = "Could not save the API key"
            failure.informativeText = String(describing: error)
            failure.runModal()
            return false
        }
    }

    @objc private func removeKeyClicked() {
        guard !credentialOperationInProgress else { return }
        credentialOperationInProgress = true
        Task {
            defer { credentialOperationInProgress = false }
            do {
                try await Task.detached { [keychain] in try keychain.remove() }.value
                hasAPIKey = false
                notifyUser(title: "ocmh settings", body: "ElevenLabs API key removed. Select Parakeet or save another key to resume transcription.")
            } catch {
                notifyUser(title: "ocmh settings", body: String(describing: error))
            }
        }
    }

    @objc private func detectionClicked() { onDetectionToggle?() }
    @objc private func permissionClicked() { onPermission?() }
    @objc private func keepClicked() { onKeepRecording?() }

    static func clawMicImage(active: Bool, appearance: NSAppearance = NSApp.effectiveAppearance,
                             activeColor: NSColor = .controlAccentColor) -> NSImage {
        ClawMicrophoneIcon.image(appearance: appearance, active: active, activeColor: activeColor)
    }
}
