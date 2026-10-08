import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import FluidAudio

@MainActor
final class MenuBarController: NSObject, ObservableObject, NSWindowDelegate {
    private let keychain: ElevenLabsKeychain
    private let statusItem: NSStatusItem?
    private var appearanceObserver: NSKeyValueObservation?
    private var applicationAppearanceObserver: NSKeyValueObservation?
    private let popover = NSPopover()
    @Published private(set) var storageSummary = "Check recording storage usage"
    func checkStorage() {
        Task {
            let root = Config.resolveRoot(cliOverride: nil)
            storageSummary = (try? await Task.detached { try RecordingStorage.summary(root: root) }.value)
                ?? "Recording storage could not be checked."
        }
    }
    private var meetingWindow: NSWindow?
    private var libraryWindow: NSWindow?
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
        } else if window === migrationWindow {
            window.contentViewController = nil; migrationWindow = nil; copyingNotes = false
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Review recorded audio"; window.isReleasedWhenClosed = false; window.delegate = self
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
    @Published private(set) var diagnosing = false
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
                        let report = try HelperDiagnostics.report(root: root, permissions: permissions, localModelAvailable: ready)
                        try HelperDiagnostics.write(report, to: output)
                    }.value
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } catch { self.showError("Could not create the diagnostic report. Choose a new file in a writable folder.") }
            }
        }
    }
    @Published private(set) var recentMeetings: [RecentMeeting] = []
    @Published private(set) var meetingSnapshotRevision: UInt64 = 0
    private var pendingNotesOpen: String?
    func updateRecentMeetings(_ value: [RecentMeeting]) {
        recentMeetings = value
        meetingSnapshotRevision &+= 1
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
    @Published private(set) var captureCheckPhase: CaptureCheckRunner.Phase? { didSet { refreshTitle() } }
    @Published private(set) var captureCheckReport: CaptureCheckRunner.Report?
    @Published private(set) var captureCheckError: String?
    @Published private(set) var captureCheckAllowed = false
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
    @Published private var pipelineStatus: TranscriptionCoordinator.Status = .idle
    @Published private var preparing = false
    @Published private var transcriptionBackend: String?
    private var renderedIconState: String?
    private var credentialOperationInProgress = false
    private var keyStatusTask: Task<Void, Never>?
    @Published private(set) var recording = false
    @Published private(set) var startingRecording = false
    @Published private(set) var elapsed = "0:00"
    @Published private(set) var detail: String?
    @Published var captureHealth = "Checking microphone and Teams audio…"
    @Published private(set) var captureWarning: String?
    func updateCaptureWarning(_ value: String?) {
        guard captureWarning != value else { return }
        captureWarning = value; refreshTitle()
    }
    @Published private(set) var detection = "Checking Teams…"
    @Published private(set) var promptsEnabled = Config.meetingDetection()
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var gatewayStatus = "Checking connection…"
    @Published private(set) var gatewayOperation = false
    private var gatewayConnected = false
    @Published private(set) var gatewaySigningIn = false
    @Published var pendingArchiveCount = 0
    var onSpeechCredentialsInstalled: (() async throws -> Void)?
    var onLocalModelInstalled: (() async throws -> Void)?
    var onRetryArchive: ((GatewayCapabilities?) async throws -> String)?
    var onTextPrepared: (() async throws -> Void)?
    func queuePreparedText() async { try? await onTextPrepared?() }
    private var gatewayCancelled = false
    @Published private(set) var hasAPIKey = false
    @Published private(set) var localModelReady = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    @Published private(set) var selectedEngine = Config.transcriptionEngine()
    @Published private(set) var style = Config.menuBarStyle()
    @Published private(set) var notesMode = Config.notesMode()
    @Published private(set) var templates = MeetingNotesSettings.templates
    @Published private(set) var selectedTemplateID = MeetingNotesSettings.selected.id
    @Published private(set) var notesFolder = MeetingNotesSettings.folder.path
    @Published private(set) var deletesVerifiedAudio = Config.deleteAudioAfterVerification()
    func setAudioRetention(_ enabled: Bool) {
        do {
            try MeetingNotesSettings.update(["audio_retention": enabled ? "delete_after_verification" : "keep",
                                             "audio_retention_opted_in_at": Date().timeIntervalSince1970])
            deletesVerifiedAudio = enabled
        } catch { showError("Could not save audio retention: \(error)") }
    }
    @Published private(set) var localSpeakerName = Config.localSpeakerName() ?? ""
    @Published private(set) var sharedMicrophone = Config.sharedMicrophone()
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
    @Published private(set) var meetingSubject: String?
    func setMeetingSubject(_ subject: String?) {
        guard meetingSubject != subject else { return }
        meetingSubject = subject; refreshTitle()
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
        statusItem = preview ? nil : NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let app = NSApp {
            applicationAppearanceObserver = app.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
                Task { @MainActor in NSApp.applicationIconImage = HelperAppIcon.image() }
            }
        }
        popover.behavior = .transient
        popover.animates = true
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
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: HelperPopover(controller: self))
            window.center()
            controlsWindow = window
        }
        accessibilityGranted = AXIsProcessTrusted()
        refreshCredentials()
        NSApp.activate(ignoringOtherApps: true)
        controlsWindow?.makeKeyAndOrderFront(nil)
        Task { await checkGateway() }
    }
    @objc private func showPopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        accessibilityGranted = AXIsProcessTrusted()
        refreshCredentials()
        Task { await checkGateway() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func toggleRecording() { popover.performClose(nil); if captureCheckBusy { cancelCaptureCheck() } else { onToggle?() } }
    func openMeeting(_ meeting: RecentMeeting) {
        popover.performClose(nil)
        if !meeting.needsAttention, let notes = meeting.notes { NSWorkspace.shared.open(notes); return }
        showMeetingDetails(meeting)
    }
    func showMeetingDetails(_ meeting: RecentMeeting) {
        popover.performClose(nil)
        let window = meetingWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 430),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ClawMinutes meeting"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MeetingDetailView(controller: self, meetingID: meeting.id))
        if meetingWindow == nil { window.center() }
        meetingWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
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
    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClawMinutes settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: HelperSettings(controller: self))
            window.center()
            settingsWindow = window
        }
        refreshCredentials()
        accessibilityGranted = AXIsProcessTrusted()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Task { await checkGateway() }
    }
    func connectGateway() { popover.performClose(nil); gatewayClicked() }
    func cancelSignIn() { cancelGatewayClicked() }
    func retrySaving() { retryArchiveClicked() }
    func setupLocal() { popover.performClose(nil); setupLocalClicked() }
    func editAPIKey() { apiKeyClicked() }
    func removeAPIKey() { removeKeyClicked() }
    func keepRecording() { onKeepRecording?() }
    func checkPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        objectWillChange.send()
    }
    var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var systemAudioGranted: Bool { CGPreflightScreenCaptureAccess() }
    func allowMicrophone() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            if !microphoneGranted { openPrivacy("Microphone") }
            checkPermissions()
        }
    }
    func allowSystemAudio() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess() { openPrivacy("ScreenCapture") }
        checkPermissions()
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane) { NSWorkspace.shared.open(url) }
    }
    func recheckGateway() { Task { await checkGateway() } }
    private func checkGateway() async {
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
        if recording && !self.recording { captureWarning = nil }
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
        case .transcribing(let name, _), .postprocessing(let name, _), .failed(let name), .archivePending(let name), .needsReview(let name, _):
            let metaURL = Config.resolveRoot(cliOverride: nil).appendingPathComponent(name).appendingPathComponent("meta.json")
            let data = try? Data(contentsOf: metaURL)
            if let data, let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                transcriptionBackend = meta["backend"] as? String
            }
            captureWarning = MenuPresentation.restoredCaptureWarning(recording: recording, current: captureWarning, metadata: data)
        case .idle: transcriptionBackend = nil
        }
        detail = MenuPresentation.pipelineDetail(status)
        refreshTitle()
    }

    func updateDetection(_ text: String, enabled: Bool) {
        if detection != text { detection = text }
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
        let state = "\(activity.isWorking)-\(isFailure)-\(recording || captureCheckBusy)-\(captureWarning != nil)-\(appearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? appearance.name.rawValue)"
        if renderedIconState != state {
            renderedIconState = state
            button.contentTintColor = nil
            button.image = Self.clawMicImage(active: activity.isWorking || isFailure, appearance: appearance,
                                            activeColor: captureCheckBusy ? .systemRed : captureWarning != nil || isFailure ? .systemOrange : (recording ? .systemRed : .controlAccentColor))
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
