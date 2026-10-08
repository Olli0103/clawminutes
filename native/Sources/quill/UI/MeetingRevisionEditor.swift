import SwiftUI

@MainActor struct MeetingRevisionEditor: View {
    enum Mode: String, Identifiable {
        case speakers, template
        var id: String { rawValue }
    }
    @ObservedObject var controller: MenuBarController
    let meeting: RecentMeeting
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = MeetingClipPlayer()
    @State private var transcript: Transcript?
    @State private var selected = Set<Int>()
    @State private var name = ""
    @State private var templateID = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var created: URL?
    init(controller: MenuBarController, meeting: RecentMeeting, mode: Mode, loadedTranscript: Transcript? = nil) {
        self.controller = controller; self.meeting = meeting; self.mode = mode
        _transcript = State(initialValue: loadedTranscript); _loading = State(initialValue: loadedTranscript == nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .speakers ? "Identify speakers" : "Regenerate notes").font(.title2.weight(.semibold))
            Text(meeting.title).font(.headline).lineLimit(2)
            Text("A new version keeps the original transcript and notes. Sending it uses your Gateway's notes settings. AI notes may incur model charges.")
                .font(.callout).foregroundStyle(.secondary)
            if let created {
                Label("New version prepared", systemImage: "checkmark.circle").foregroundStyle(.green)
                Text("It will send through the normal queue. If your connection is unavailable, it stays on this Mac.")
                Button("Show new version") { controller.openDocument(created) }
            } else if loading {
                ProgressView("Loading transcript…").frame(maxWidth: .infinity, minHeight: 160)
            } else if mode == .speakers, let transcript {
                Text("Select only the turns you can identify. A voice cluster can contain more than one person. Other turns keep their existing labels.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Confirmed speaker name", text: $name).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                            HStack(alignment: .top, spacing: 10) {
                                Toggle(isOn: Binding(get: { selected.contains(index) }, set: { value in
                                    if value { selected.insert(index) } else { selected.remove(index) }
                                })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(clock(segment.start_ms)) · \(segment.displayName)").font(.caption.weight(.semibold))
                                        Text(segment.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    }
                                }.toggleStyle(.checkbox)
                                Spacer(minLength: 0)
                                Button {
                                    player.play(directory: meeting.directory, segment: segment, index: index)
                                } label: { Image(systemName: player.playingIndex == index ? "stop.fill" : "play.fill") }
                                    .accessibilityLabel(player.playingIndex == index ? "Stop excerpt" : "Play up to eight seconds from this turn")
                            }.padding(8).background(selected.contains(index) ? Color.accentColor.opacity(0.1) : .clear,
                                                       in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.frame(minHeight: 200)
                if let message = player.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("\(selected.count) selected turns · \(transcript.segments.filter { $0.speaker_name == nil }.count) unidentified turns")
                    .font(.caption)
            } else if mode == .template {
                Picker("Note template", selection: $templateID) {
                    ForEach(controller.templates) { template in Text(template.name).tag(template.id) }
                }
                if let template = controller.templates.first(where: { $0.id == templateID }) {
                    ScrollView { VStack(alignment: .leading, spacing: 10) {
                        Text(template.context).foregroundStyle(.secondary)
                        ForEach(Array(template.sections.enumerated()), id: \.offset) { _, section in
                            Text(section.title).font(.headline); Text(section.instructions).font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 200)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(created == nil ? "Cancel" : "Done") { player.stop(); dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if created == nil {
                    Button(saving ? "Preparing…" : "Save as new version", action: save).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(loading || saving || !valid)
                }
            }
        }.padding(24).frame(width: 620, height: 580)
            .foregroundStyle(.primary).background(Color(nsColor: .windowBackgroundColor))
            .task {
                templateID = controller.selectedTemplateID
                if transcript != nil { loading = false; return }
                do { transcript = try await Task.detached {
                    try JSONDecoder().decode(Transcript.self, from: ArchiveBacklog.read(meeting.directory.appendingPathComponent("transcript.json")))
                }.value } catch { self.error = "The transcript could not be read. Existing files are preserved." }
                loading = false
            }.onDisappear { player.stop() }.interactiveDismissDisabled(saving)
    }
    private var valid: Bool {
        mode == .speakers ? transcript != nil && !selected.isEmpty && SpeakerAttribution.cleanName(name) != nil :
            transcript != nil && controller.templates.contains(where: { $0.id == templateID })
    }
    private func clock(_ ms: Int) -> String { String(format: "%d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60) }
    private func save() {
        guard valid, !saving else { return }
        player.stop(); saving = true; error = nil
        let change: MeetingRevisions.Change
        if mode == .speakers { change = .speaker(indices: selected, name: name) }
        else if let template = controller.templates.first(where: { $0.id == templateID }) { change = .template(template) }
        else { saving = false; return }
        Task {
            defer { saving = false }
            do {
                created = try await Task.detached { try MeetingRevisions.create(from: meeting.directory, change: change) }.value
                await controller.queueNewVersion()
            } catch { self.error = String(describing: error) }
        }
    }
}
