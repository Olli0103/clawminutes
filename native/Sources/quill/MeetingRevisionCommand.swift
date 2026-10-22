import ArgumentParser
import Foundation

struct ReviseMeeting: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revise-meeting", abstract: "Create a separate text-only version of a verified saved meeting. Originals are preserved.")
    @Argument(help: "Saved meeting folder.") var recording: String
    @Option(parsing: .upToNextOption, help: "Exact zero-based transcript segment indices to identify. Requires --name.") var turns: [Int] = []
    @Option(help: "Confirmed name for the selected turns only.") var name: String?
    @Option(help: "Configured template ID for new AI notes.") var template: String?
    @Option(help: "Replacement transcript.json from a separate transcription preview.") var transcript: String?
    func run() throws {
        let modes = [!turns.isEmpty || name != nil, template != nil, transcript != nil].filter { $0 }.count
        guard modes == 1 else { throw ValidationError("Choose selected turns with a name, a template, or a replacement transcript.") }
        let change: MeetingRevisions.Change
        if let template {
            guard let value = MeetingNotesSettings.templates.first(where: { $0.id == template }) else { throw ValidationError("Unknown note template ID.") }
            change = .template(value)
        } else if let transcript {
            let file = URL(fileURLWithPath: (transcript as NSString).expandingTildeInPath)
            change = .retranscribed(try JSONDecoder().decode(Transcript.self, from: ArchiveBacklog.read(file)))
        } else {
            guard let name, !turns.isEmpty else { throw ValidationError("Provide --turns and --name together.") }
            change = .speaker(indices: Set(turns), name: name)
        }
        let directory = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath).standardizedFileURL
        let output = try MeetingRevisions.create(from: directory, change: change)
        print(output.path)
        print("New version prepared. The running helper's queue will send it. If the helper is stopped, use archive-session --directory with this new folder. No audio was copied.")
    }
}
