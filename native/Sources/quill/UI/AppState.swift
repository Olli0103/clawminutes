import Foundation
import Observation
import ApplicationServices
import FluidAudio

/// UI projection only. state.json and verified artifacts remain the sole durable
/// pipeline authority. Updating this object never starts recording or retries work.
@MainActor @Observable
final class AppState {
    var loginStatus: HelperLoginItem.Status = .unavailable
    var loginSettingError: String? = nil
    var storageSummary: String = "Check recording storage usage"
    var diagnosing: Bool = false
    var recentMeetings: [RecentMeeting] = []
    var meetingSnapshotRevision: UInt64 = 0
    var captureCheckPhase: CaptureCheckRunner.Phase? = nil
    var captureCheckReport: CaptureCheckRunner.Report? = nil
    var captureCheckError: String? = nil
    var captureCheckAllowed: Bool = false
    var pipelineStatus: TranscriptionCoordinator.Status = .idle
    var preparing: Bool = false
    var transcriptionBackend: String? = nil
    var recording: Bool = false
    var startingRecording: Bool = false
    var elapsed: String = "0:00"
    var detail: String? = nil
    var captureHealth: String = "Checking microphone and Teams audio…"
    var captureWarning: String? = nil
    var detection: String = "Checking Teams…"
    var promptsEnabled: Bool = Config.meetingDetection()
    var accessibilityGranted: Bool = AXIsProcessTrusted()
    var gatewayStatus: String = "Checking connection…"
    var gatewayOperation: Bool = false
    var gatewaySigningIn: Bool = false
    var pendingArchiveCount: Int = 0
    var hasAPIKey: Bool = false
    var localModelReady: Bool = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    var selectedEngine: String = Config.transcriptionEngine()
    var style: MenuBarStyle = Config.menuBarStyle()
    var notesMode: String = Config.notesMode()
    var templates: [NoteTemplate] = MeetingNotesSettings.templates
    var selectedTemplateID: String = MeetingNotesSettings.selected.id
    var notesFolder: String = MeetingNotesSettings.folder.path
    var deletesVerifiedAudio: Bool = Config.deleteAudioAfterVerification()
    var localSpeakerName: String = Config.localSpeakerName() ?? ""
    var sharedMicrophone: Bool = Config.sharedMicrophone()
    var meetingSubject: String? = nil
    var popoverVisible = false
    var settingsPage: HelperSettingsPage = .general
    var micLevel: Float = 0
    var teamsLevel: Float = 0
    var micLost = false
    var callDetectedAt: Date?
    var selectedMeetingID: String?
    var recordingBytes: Int64?
    var freeBytes: Int64?
    var capacityBytes: Int64?
    var previewHeadline: Headline?

    enum Headline: String, CaseIterable {
        case recording = "Recording", callDetected = "Teams call detected"
        case processing = "Transcribing", sending = "Saving your meeting"
        case attention = "Meetings to finish", ready = "Ready"
        var symbol: String {
            switch self {
            case .recording: "record.circle"
            case .callDetected: "video"
            case .processing: "waveform"
            case .sending: "arrow.up.doc"
            case .attention: "exclamationmark.circle"
            case .ready: "checkmark.circle"
            }
        }
    }
    var callDetected: Bool {
        // A retained subject alone does not prove a live call.
        detection == "Teams meeting detected" || detection.hasPrefix("Watching Teams")
            || detection.hasPrefix("Watching Microsoft Teams")
    }
    var callTitle: String { MeetingDate.title(meetingSubject, started: callDetectedAt) }
    var attentionMeetings: [RecentMeeting] {
        recentMeetings.filter(\.presentationNeedsAttention)
    }
    var attentionGroups: [AttentionGroup] { AttentionGroup.group(attentionMeetings) }
    var headline: Headline {
        if recording { return .recording }
        if callDetected { return .callDetected }
        if captureCheckPhase != nil || preparing || startingRecording { return .processing }
        switch pipelineStatus {
        case .recognizingChunk, .transcribing, .postprocessing: return .processing
        default: break
        }
        if recentMeetings.contains(where: { [.delivering, .delivered].contains($0.stage) }) { return .sending }
        if !attentionMeetings.isEmpty { return .attention }
        switch pipelineStatus { case .failed, .needsReview, .archivePending: return .attention; default: break }
        return previewHeadline ?? .ready
    }
    var primaryTitle: String {
        if captureCheckPhase != nil { return "Cancel audio check" }
        if recording { return "Stop recording" }
        if startingRecording { return "Starting…" }
        return callDetected ? "Record \(callTitle)" : "Start recording"
    }
}

enum AttentionCause: String, CaseIterable, Identifiable {
    case signIn, gateway, aiNotes, unconfirmed, interrupted, other
    var id: Self { self }
    var title: String {
        switch self {
        case .signIn: "Sign-in expired"
        case .gateway: "Gateway unavailable"
        case .aiNotes: "AI notes failed"
        case .unconfirmed: "Notes not confirmed"
        case .interrupted: "Interrupted recording"
        case .other: "Meeting needs a check"
        }
    }
    static func forMeeting(_ meeting: RecentMeeting) -> Self {
        if meeting.stage == .interrupted || meeting.hasCaptureWarnings { return .interrupted }
        if meeting.issue?.code == "sign_in_required" { return .signIn }
        if meeting.canVerifyLegacyReceipt { return .unconfirmed }
        if meeting.canRetryLocalExport { return .other }
        let code = meeting.issue?.code ?? ""
        if code.hasPrefix("notes_") || code.hasPrefix("ai_") || code.contains("completion") { return .aiNotes }
        if meeting.guidance.action == .retryAI || meeting.guidance.action == .transcriptOnly { return .aiNotes }
        if meeting.guidance.action == .checkConnection { return .gateway }
        return .other
    }
}
struct AttentionGroup: Identifiable {
    let cause: AttentionCause
    let meetings: [RecentMeeting]
    var id: String { cause.rawValue + (cause == .other ? (meetings.first?.issue?.code ?? meetings.first?.guidance.title ?? "") : "") }
    var title: String { cause == .other ? (meetings.first?.guidance.title ?? cause.title) : cause.title }
    var action: String {
        switch cause {
        case .signIn: "Sign in"
        case .gateway: "Check connection"
        case .aiNotes: "Review notes"
        case .unconfirmed: "Find notes"
        case .interrupted: "Review transcript"
        case .other: "Review meeting"
        }
    }
    static func group(_ meetings: [RecentMeeting]) -> [Self] {
        var groups: [Self] = []
        for cause in AttentionCause.allCases {
            let values = meetings.filter { AttentionCause.forMeeting($0) == cause }
            if cause == .other {
                let keyed = Dictionary(grouping: values) { $0.issue?.code ?? $0.guidance.title }
                groups += keyed.keys.sorted().map { Self(cause: cause, meetings: keyed[$0]!) }
            } else if !values.isEmpty { groups.append(Self(cause: cause, meetings: values)) }
        }
        return groups
    }
}
