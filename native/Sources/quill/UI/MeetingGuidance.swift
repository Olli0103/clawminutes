import Foundation

/// User instructions are separate from the stored diagnostic and retry policy.
/// Choosing an instruction never performs work or changes a failure/budget.
struct MeetingGuidance: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case findNotes, saveLocalNotes, downloadModel, addSpeechKey, signIn
        case checkConnection, retryAI, transcriptOnly, openTranscript, supportReport
    }
    let title: String
    let message: String
    let button: String
    let footnote: String
    let symbol: String
    let action: Action

    init(_ meeting: RecentMeeting) {
        if meeting.canRetryLocalExport {
            self.init(title: "Save your notes on this Mac", message: "Your notes are saved on the Gateway. Their local copy could not be saved. Try saving it again.",
                      button: "Save notes on this Mac", footnote: "Uses the saved notes. No new AI generation.", symbol: "square.and.arrow.down", action: .saveLocalNotes)
        } else if meeting.hasCaptureWarnings && meeting.transcript != nil {
            self.init(title: "Review gaps in the transcript", message: "Your notes are saved, but parts of the recording may be missing or uncertain. Open the transcript and review the marked passages.",
                      button: "Review transcript", footnote: "The audio is kept for recovery. Another upload will not repair missing speech.", symbol: "text.badge.exclamationmark", action: .openTranscript)
        } else if meeting.issue?.code == "local_model_missing" || meeting.stage == .waitingForModel {
            self.init(title: "Download the speech model", message: "The local speech model is missing. Download it to transcribe the audio already saved on this Mac.",
                      button: "Download model", footnote: "Your recording stays on this Mac.", symbol: "arrow.down.circle", action: .downloadModel)
        } else if meeting.issue?.code == "speech_credentials_missing" {
            self.init(title: "Add your ElevenLabs key", message: "ElevenLabs needs your API key before it can transcribe this recording.",
                      button: "Add API key", footnote: "ElevenLabs receives audio when cloud transcription runs.", symbol: "key", action: .addSpeechKey)
        } else if meeting.issue?.code == "sign_in_required" {
            self.init(title: "Sign in to save this meeting", message: "Your Gateway session has expired or access was denied. Sign in again to send waiting transcripts.",
                      button: "Sign in to Gateway", footnote: "Your transcript is kept here while you sign in.", symbol: "person.crop.circle.badge.exclamationmark", action: .signIn)
        } else if meeting.canVerifyLegacyReceipt {
            self.init(title: "Check saved notes", message: "This Mac has not confirmed where this meeting's notes were saved. Look for a matching saved meeting on your Gateway.",
                      button: "Find my notes", footnote: "Checks saved text only. No AI generation or audio upload.", symbol: "doc.text.magnifyingglass", action: .findNotes)
        } else if meeting.issue?.retryable == true && meeting.transcript != nil {
            self.init(title: "Reconnect to save your notes", message: "Your transcript is ready on this Mac. Check the Gateway connection so waiting meetings can be saved.",
                      button: "Check connection", footnote: "Your audio and transcript stay available for recovery.", symbol: "network", action: .checkConnection)
        } else if meeting.canRetryAINotes {
            self.init(title: "Try creating notes again", message: "The Gateway did not finish the AI notes. Review and request one more attempt, or save the transcript without AI notes.",
                      button: "Try AI notes again…", footnote: "Another attempt may incur model charges.", symbol: "sparkles", action: .retryAI)
        } else if meeting.canSaveTranscriptOnly {
            self.init(title: "Save your transcript", message: "AI notes could not be completed. You can still save the transcript and meeting details without another AI generation.",
                      button: "Save transcript…", footnote: "Earlier saved AI notes are reused if they already exist.", symbol: "doc.text", action: .transcriptOnly)
        } else if meeting.transcript != nil && meeting.issue?.code == "revision_conflict" {
            self.init(title: "Review the changed transcript", message: "This transcript differs from the meeting already saved on your Gateway. Review the changes before creating a separate version.",
                      button: "Open transcript", footnote: "Your saved meeting has been preserved.", symbol: "doc.on.doc", action: .openTranscript)
        } else {
            self.init(title: meeting.transcript == nil ? "Transcription needs help" : "Saving this meeting needs help",
                      message: "ClawMinutes could not finish this meeting automatically. Save a diagnostic report to investigate the failed step.",
                      button: "Save diagnostic report…", footnote: "The report excludes audio, speech, notes, names and credentials.", symbol: "lifepreserver", action: .supportReport)
        }
    }

    private init(title: String, message: String, button: String, footnote: String, symbol: String, action: Action) {
        self.title = title; self.message = message; self.button = button
        self.footnote = footnote; self.symbol = symbol; self.action = action
    }
}
