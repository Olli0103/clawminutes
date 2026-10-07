import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class MeetingAssistant {
    var onStart: (() async -> Bool)?
    var onStop: (() -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onSpeakers: ((SpeakerObservation) -> Void)?
    private var policy = MeetingPolicy()
    private let scanner = MeetingScanner()
    private var timer: Timer?
    private var speakerTimer: Timer?
    private var samplingSpeakers = false
    private var tracking = SpeakerTrackingState()
    private var recordingGeneration = 0
    private var recordingSpeakerMeetingID: String?
    private var scanning = false
    private let recordingNotification: (String, String) -> Void
    private var automaticStart: DetectedMeeting?
    private var consentPromptInProgress = false
    private var enabled = Config.meetingDetection()
    private var lastStatus: String?
    private var consent = ConsentPromptState(prompted: Set(UserDefaults.standard.stringArray(forKey: "teamsPromptedMeetingIDs") ?? []))
    private var needsZoomScreenPermission = false

    init(recordingNotification: @escaping (String, String) -> Void = notifyUser) {
        self.recordingNotification = recordingNotification
    }

    func start() {
        _ = policy.setAutomationEnabled(enabled)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
        speakerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleSpeakers() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        speakerTimer?.invalidate()
        speakerTimer = nil
    }

    func toggleEnabled() {
        guard Config.setMeetingDetection(!enabled) else {
            notifyUser(title: "ocmh settings", body: "Could not save the meeting detection setting. Check the configuration file.")
            return
        }
        enabled.toggle()
        if !enabled { tracking = SpeakerTrackingState() }
        if policy.setAutomationEnabled(enabled) == .stop { onStop?() }
        // Permission requests are explicit in Settings; enabling prompts never opens a system alert.
        poll()
    }

    func requestPermission() {
        if AXIsProcessTrusted() {
            poll()
            return
        }
        if needsZoomScreenPermission {
            _ = CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func recordingStarted() {
        recordingContextID = contextForStart?.meeting_id
        if let id = recordingContextID {
            _ = consent.observe(DetectedMeeting(id: id, app: "Teams", service: "Microsoft Teams"))
            persistConsent()
        }
        recordingGeneration += 1
        policy.recordingStarted(for: automaticStart, automatic: automaticStart != nil)
        recordingSpeakerMeetingID = tracking.recordingMeetingID(preferred: automaticStart?.id, previous: nil)
        if let id = recordingSpeakerMeetingID, let roster = tracking.seed(meetingID: id, at: Date().timeIntervalSince1970) {
            onSpeakers?(roster)
        }
        recordingNotification("ocmh: Recording started", automaticStart.map { "\($0.service) in \($0.app)" } ?? "Recording microphone and system audio.")
    }

    func recordingStopped() {
        recordingGeneration += 1
        recordingContextID = nil
        policy.recordingStopped()
        recordingSpeakerMeetingID = nil
        recordingNotification("ocmh: Recording stopped", "Your recording is being prepared for transcription.")
    }

    func keepRecording() {
        policy.keepRecording()
        report("Automatic stop off for this recording", enabled)
    }

    var onMeetingContext: ((MeetingContext) -> Void)?
    var onMeetingTitle: ((String?) -> Void)?
    private var contexts: [String: MeetingContext] = [:]
    private var availableMeetingIDs: [String] = []
    private var recordingContextID: String?
    var contextForStart: MeetingContext? {
        let candidate = automaticStart.flatMap { contexts[$0.id] }
            ?? (availableMeetingIDs.count == 1 ? contexts[availableMeetingIDs[0]] : nil)
        return candidate?.isCurrent(at: Date().timeIntervalSince1970) == true ? candidate : nil
    }
    private func report(_ text: String, _ enabled: Bool) {
        if text != lastStatus {
            FileHandle.standardError.write(Data("meeting detection: \(text)\n".utf8))
            lastStatus = text
        }
        onStatus?(text, enabled)
    }

    private func poll() {
        guard enabled else {
            report("Meeting detection off", false)
            return
        }
        guard !scanning else { return }
        scanning = true
        let apps = MeetingApp.running()
        let generation = recordingGeneration
        Task { [weak self, scanner] in
            let captureSpeakers = Config.speakerDetection()
            let scan = await scanner.scan(apps: apps, captureSpeakers: captureSpeakers,
                                          enableCaptions: self?.policy.recording == true && captureSpeakers && Config.autoMeetingCaptions(),
                                          captionMeetingID: self?.recordingSpeakerMeetingID)
            guard let self else { return }
            self.scanning = false
            guard self.enabled else { return }
            for (id, context) in scan.contexts { self.contexts[id] = context }
            self.availableMeetingIDs = scan.observations.compactMap { id, value in if case .present = value { return id }; return nil }.sorted()
            if self.policy.recording, self.recordingContextID == nil, self.availableMeetingIDs.count == 1 { self.recordingContextID = self.availableMeetingIDs[0] }
            if self.policy.recording, let id = self.recordingContextID, let context = scan.contexts[id] { self.onMeetingContext?(context) }
            let displayID = self.recordingContextID ?? (self.availableMeetingIDs.count == 1 ? self.availableMeetingIDs[0] : nil)
            self.onMeetingTitle?(displayID.flatMap { self.contexts[$0]?.title })
            self.tracking.update(scan.observations, at: scan.observedAt)
            for roster in scan.rosters { self.tracking.observe(roster) }
            let previousMeeting = self.recordingSpeakerMeetingID
            let promptedBefore = self.consent.prompted
            self.consent.update(scan.observations, now: ProcessInfo.processInfo.systemUptime,
                                promptInProgress: self.consentPromptInProgress)
            if self.policy.recording {
                for observation in scan.observations.values {
                    if case .present(let meeting) = observation { _ = self.consent.observe(meeting) }
                }
            }
            if self.consent.prompted != promptedBefore { self.persistConsent() }
            let action = self.policy.update(scan.observations, now: ProcessInfo.processInfo.systemUptime)
            self.recordingSpeakerMeetingID = self.policy.recording
                ? self.tracking.recordingMeetingID(preferred: self.policy.recordingMeeting?.id, previous: previousMeeting) : nil
            if self.policy.recording, let id = self.recordingSpeakerMeetingID, id != previousMeeting,
               let roster = self.tracking.seed(meetingID: id, at: Date().timeIntervalSince1970) { self.onSpeakers?(roster) }
            self.needsZoomScreenPermission = scan.needsZoomScreenPermission && self.policy.recordingMeeting?.service == "Zoom"
            if generation == self.recordingGeneration, let id = self.recordingSpeakerMeetingID, let names = scan.speakers[id] {
                self.onSpeakers?(SpeakerObservation(observed_at: scan.speakerObservedAt[id] ?? scan.observedAt,
                                                    meeting_id: id, names: names))
            }
            for caption in scan.captions + scan.rosters where generation == self.recordingGeneration && caption.meeting_id == self.recordingSpeakerMeetingID {
                self.onSpeakers?(caption)
            }
            if scan.needsPermission {
                self.report("Meeting detection needs Accessibility permission", true)
                return
            } else if let meeting = self.policy.recordingMeeting {
                self.report(scan.speakerNameWarnings[meeting.id] ?? "Watching \(meeting.service) in \(meeting.app)", true)
            } else if self.policy.recording {
                self.report(self.policy.automaticStop ? "No meeting linked; stop recording manually" : "Automatic stop off for this recording", true)
            } else {
                self.report(scan.observations.values.contains { if case .present = $0 { return true }; return false } ? "Teams meeting detected" : "No active Teams meeting detected", true)
            }
            switch action {
            case .start(let meeting):
                guard !self.consentPromptInProgress else { break }
                let shouldPrompt = self.consent.observe(meeting)
                self.persistConsent()
                self.policy.startFailed(for: meeting)
                if shouldPrompt { await self.requestConsent(for: meeting) }
            case .countdown(let seconds):
                self.report("Meeting ended; stopping automatically in \(seconds)s", true)
            case .stop:
                self.onStop?()
            case .unavailable:
                self.report("Meeting status unavailable; recording continues", true)
            case .none:
                break
            }
        }
    }

    private func persistConsent() {
        UserDefaults.standard.set(Array(consent.prompted).sorted(), forKey: "teamsPromptedMeetingIDs")
    }

    private func requestConsent(for meeting: DetectedMeeting) async {
        consentPromptInProgress = true
        defer { consentPromptInProgress = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = MeetingConsentPrompt.make(title: contexts[meeting.id]?.title)
        if alert.runModal() == .alertFirstButtonReturn {
            automaticStart = meeting
            _ = await onStart?()
            automaticStart = nil
        }
    }

    private func sampleSpeakers() {
        guard enabled, Config.speakerDetection(), !samplingSpeakers, !tracking.meetingIDs.isEmpty else { return }
        samplingSpeakers = true
        let ids = tracking.meetingIDs
        let generation = recordingGeneration
        Task { [weak self, scanner] in
            for id in ids {
                guard self?.enabled == true else { break }
                let observation = await scanner.speakerActivity(for: id)
                guard let self, let observation, generation == self.recordingGeneration,
                      self.policy.recording, self.recordingSpeakerMeetingID == id else { continue }
                self.onSpeakers?(observation)
            }
            self?.samplingSpeakers = false
        }
    }

}
