import AppKit

@MainActor
enum MeetingConsentPrompt {
    static func make(fixture: Bool = false, title: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.icon = HelperAppIcon.image()
        alert.messageText = "Transcribe this meeting?"
        let privacy = Config.transcriptionEngine() == "parakeet"
            ? "Parakeet runs on this Mac. Audio stays here; finished text is saved to your Gateway."
            : "ElevenLabs Scribe v2 transcribes in the cloud. Recording audio is uploaded to ElevenLabs."
        alert.informativeText = (fixture ? "Synthetic prompt test. " : (title.map { "\($0). " } ?? "Your Teams call is ready. ")) + "Start records your microphone and Teams audio. " + privacy + (Config.notesMode() == "ai" ? " AI notes send finished text to the Gateway’s configured model provider." : "")
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Dismiss")
        return alert
    }
}
