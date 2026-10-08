import SwiftUI

@MainActor
struct HelperPopover: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: MenuBarController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: HelperAppIcon.image(appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!))
                    .resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.activity.title).font(.title2.weight(.semibold))
                    Text(controller.meetingTitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            if controller.activity.isWorking, let detail = controller.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if !controller.captureCheckBusy, let warning = controller.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: controller.toggleRecording) {
                HStack {
                    Image(systemName: controller.recording || controller.captureCheckBusy ? "stop.fill" : "mic.fill")
                    Text(controller.captureCheckBusy ? "Cancel audio check" : controller.recording ? "Stop recording" : (controller.startingRecording ? "Starting…" : "Start recording")).fontWeight(.semibold)
                    Spacer()
                    Text("⌘R").foregroundStyle(.secondary)
                }.padding(.vertical, 7).frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(controller.recording || controller.captureCheckBusy ? .red : .accentColor)
                .keyboardShortcut("r").disabled(controller.startingRecording)
            if controller.recording {
                Label(controller.captureWarning == nil ? controller.captureHealth : "Recording with an audio warning",
                      systemImage: controller.captureWarning == nil ? "waveform" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.detection.hasPrefix("Meeting ended") {
                    Button("Keep recording", action: controller.keepRecording).buttonStyle(.bordered)
                }
            }
            HStack {
                Menu {
                    Button("Local only") { controller.selectEngine("parakeet") }
                    Button("ElevenLabs cloud") { controller.selectEngine("elevenlabs") }
                } label: { Label(controller.backendTitle, systemImage: "waveform") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(controller.activity.isWorking)
                Spacer()
                Text(controller.captureCheckBusy ? "No transcription or upload" : controller.displayedBackend == "parakeet" ? "Audio stays on this Mac" : "Audio goes to ElevenLabs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.accessibilityGranted && controller.promptsEnabled {
                Button("Enable Teams call detection…", action: controller.allowDetection).buttonStyle(.link)
            }
            Divider()
            HStack {
                Text("Recent meetings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("See all", action: controller.showLibrary).buttonStyle(.link).font(.caption)
                Button("Notes folder", action: controller.openNotesFolder).buttonStyle(.link).font(.caption)
            }
            if controller.recentMeetings.isEmpty {
                Text("Your finished meetings will appear here.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(controller.recentMeetings.prefix(3))) { meeting in
                Button { controller.openMeeting(meeting) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: meeting.symbol).foregroundStyle(meeting.needsAttention ? .orange : (meeting.ready ? .green : .secondary))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meeting.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            HStack(spacing: 5) {
                                if let date = meeting.started { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                                Text("· " + meeting.statusTitle)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 3)
                        Text(meeting.ready && !meeting.needsAttention ? "Open" : "Details").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(meeting.title), \(meeting.statusTitle)")
            }
            if controller.pendingArchiveCount > 0 && !controller.gatewayOperation {
                Button("\(controller.pendingArchiveCount) waiting to send · Check connection", action: controller.recheckGateway)
                    .buttonStyle(.link).font(.caption)
            }
            Divider()
            HStack {
                Button("Settings", action: controller.showSettings).buttonStyle(.plain)
                Spacer()
                Button(controller.promptsEnabled ? "Pause prompts" : "Resume prompts", action: controller.togglePrompts).buttonStyle(.plain)
                Button("Quit", action: controller.quit).buttonStyle(.plain).keyboardShortcut("q")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 380)
    }
}

@MainActor
struct MeetingDetailView: View {
    @ObservedObject var controller: MenuBarController
    let meetingID: String
    @State private var revisionMode: MeetingRevisionEditor.Mode?
    @State private var unidentifiedTurns: Int?
    @State private var recoveryKind: NotesRecovery.Kind?
    @State private var verifyingLegacyReceipt = false
    @State private var savingLocalNotes = false
    @State private var localSaveError: String?
    var body: some View {
        ScrollView {
            if let meeting = controller.recentMeetings.first(where: { $0.id == meetingID }) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(meeting.title).font(.title2.weight(.semibold))
                    if meeting.revision > 1 { Text("Version \(meeting.revision)").font(.caption).foregroundStyle(.secondary) }
                    Label(meeting.statusTitle, systemImage: meeting.symbol).foregroundStyle(meeting.needsAttention ? .orange : .primary)
                    if let date = meeting.started { Text(date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                    Text(meeting.detail).font(.callout).textSelection(.enabled)
                    if let unidentifiedTurns, unidentifiedTurns > 0 {
                        Text("\(unidentifiedTurns) turns have no identified speaker.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if let notes = meeting.notes {
                            Button("Open notes") { controller.openDocument(notes) }
                            Button("Copy notes") { controller.copyNotes(meeting) }
                        }
                        if let transcript = meeting.transcript { Button("Open transcript") { controller.openDocument(transcript) } }
                    }
                    if meeting.notes != nil {
                        Button("Copy notes to another folder…") { controller.copyExistingNotes([meeting]) }
                    }
                    if meeting.ready && meeting.transcript != nil {
                        HStack {
                            Button("Identify speakers…") { revisionMode = .speakers }
                            Button("Regenerate notes…") { revisionMode = .template }
                        }
                    }
                    if meeting.canRetryLocalExport {
                        Button(savingLocalNotes ? "Saving notes…" : "Retry saving notes on this Mac") {
                            savingLocalNotes = true; localSaveError = nil
                            Task {
                                do {
                                    _ = try await Task.detached {
                                        try VerifiedLocalExport.perform(meeting.directory, explicit: true)
                                    }.value
                                } catch { localSaveError = DeliveryFailure.classify(error).detail }
                                savingLocalNotes = false
                                await controller.refreshLocalMeetings()
                            }
                        }.disabled(savingLocalNotes)
                        if let localSaveError { Text(localSaveError).font(.caption).foregroundStyle(.orange) }
                    }
                    else if meeting.issue?.code == "local_model_missing" { Button("Download local model…", action: controller.setupLocal) }
                    else if meeting.issue?.code == "speech_credentials_missing" { Button("Add API key…", action: controller.editAPIKey) }
                    else if meeting.issue?.code == "sign_in_required" { Button("Sign in", action: controller.connectGateway) }
                    else if meeting.issue?.retryable == true && meeting.transcript != nil { Button("Retry sending", action: controller.retrySaving) }
                    if meeting.canSaveTranscriptOnly {
                        Button("Save transcript-only notes…") { recoveryKind = .transcriptOnly }
                    }
                    if meeting.canRetryAINotes {
                        Button("Try AI notes again…") { recoveryKind = .retryAI }
                    }
                    if meeting.canVerifyLegacyReceipt {
                        Button("Check for saved meeting…") { verifyingLegacyReceipt = true }
                    }
                    Button("Review this meeting’s audio…") { controller.reviewRecordedAudio([meeting]) }
                    Button("Show files in Finder") { controller.openDocument(meeting.directory) }.buttonStyle(.link)
                    DisclosureGroup("Technical details") {
                        Text(meeting.issue?.code ?? meeting.stage.rawValue).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .sheet(item: $revisionMode) { mode in MeetingRevisionEditor(controller: controller, meeting: meeting, mode: mode) }
                    .sheet(isPresented: $verifyingLegacyReceipt) { LegacyReceiptView(controller: controller, meeting: meeting) }
                    .sheet(item: $recoveryKind) { kind in NotesRecoveryEditor(controller: controller, meeting: meeting, kind: kind) }
            } else { Text("This meeting is no longer in the current list.").padding(24) }
        }.frame(minWidth: 430, minHeight: 320)
            .background(Color(nsColor: .windowBackgroundColor))
            .task(id: meetingID) {
                unidentifiedTurns = nil
                guard let meeting = controller.recentMeetings.first(where: { $0.id == meetingID }) else { return }
                unidentifiedTurns = try? await Task.detached {
                    let transcript = try JSONDecoder().decode(Transcript.self, from: ArchiveBacklog.read(meeting.directory.appendingPathComponent("transcript.json")))
                    return transcript.segments.filter { $0.speaker_name == nil }.count
                }.value
            }
    }
}

enum HelperSettingsPage: String, CaseIterable, Identifiable {
    case general = "General", recording = "Recording", notes = "Notes", connection = "Connection"
    case privacy = "Privacy & storage", permissions = "Permissions", advanced = "Advanced"
    var id: String { rawValue }
}

@MainActor
struct HelperSettings: View {
    @ObservedObject var controller: MenuBarController
    @State private var page: HelperSettingsPage
    init(controller: MenuBarController, initialPage: HelperSettingsPage = .general) {
        self.controller = controller; _page = State(initialValue: initialPage)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ClawMinutes").font(.headline).padding(.bottom, 16)
                ForEach(HelperSettingsPage.allCases) { item in
                    Button { page = item } label: {
                        Text(item.rawValue).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            .background(page == item ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
            }.padding(14).frame(width: 165)
            Divider()
            Form {
                Text(page.rawValue).font(.title2.weight(.semibold))
                switch page {
                case .general:
                    Section {
                        Picker("Menu bar", selection: Binding(get: { controller.style }, set: controller.chooseStyle)) {
                            Text("Icon only").tag(MenuBarStyle.iconOnly)
                            Text("Icon and description").tag(MenuBarStyle.descriptive)
                        }.pickerStyle(.segmented)
                        Toggle("Ask when a Teams call starts", isOn: Binding(get: { controller.promptsEnabled }, set: { _ in controller.togglePrompts() }))
                        Text("One prompt per call. Dismiss keeps audio off. You can always start from the menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Launch at login", isOn: Binding(get: { controller.loginStatus.enabled == true }, set: controller.setLaunchAtLogin))
                            .disabled(controller.loginStatus.enabled == nil)
                        Text(controller.loginStatus.detail).font(.caption).foregroundStyle(.secondary)
                        if let issue = controller.loginSettingError {
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                        if controller.loginStatus.enabled == nil || controller.loginSettingError != nil {
                            Button("Check login setting again", action: controller.refreshLoginSetting)
                        }
                        Button("Setup checklist…", action: controller.showSetup)
                        Button("Open recording controls", action: controller.openMenu)
                    }
                case .recording:
                    Section {
                        HStack {
                            Text(controller.localSpeakerName.isEmpty ? "Your name is not set" : controller.localSpeakerName)
                            Spacer(); Button("Your name…", action: controller.editLocalSpeakerName)
                        }
                        Toggle("Shared microphone", isOn: Binding(get: { controller.sharedMicrophone }, set: controller.setSharedMicrophone))
                        Text("Your name labels your personal microphone. A shared microphone keeps speakers unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(controller.activity.isWorking)
                    Section {
                        Picker("Speech recognition", selection: Binding(get: { controller.selectedEngine }, set: controller.selectEngine)) {
                            Text("Local only").tag("parakeet"); Text("ElevenLabs cloud").tag("elevenlabs")
                        }.disabled(controller.activity.isWorking)
                        if controller.selectedEngine == "parakeet" {
                            Text(controller.localModelReady ? "The local speech model is ready." : "Download the speech model before your first recording.")
                            if !controller.localModelReady { Button("Download local model…", action: controller.setupLocal) }
                        } else {
                            Button(controller.hasAPIKey ? "Change API key…" : "Add API key…", action: controller.editAPIKey)
                            if controller.hasAPIKey { Button("Remove key", action: controller.removeAPIKey) }
                        }
                        if controller.recording { Button("Keep recording after the call ends", action: controller.keepRecording) }
                    }
                case .notes:
                    Section {
                        Picker("Create notes", selection: Binding(get: { controller.notesMode }, set: controller.chooseNotes)) {
                            Text("AI notes on your Gateway").tag("ai")
                            Text("Simple highlights").tag("simple"); Text("Transcript only").tag("transcript")
                        }.disabled(controller.activity.isWorking)
                        Picker("Default template", selection: Binding(get: { controller.selectedTemplateID }, set: controller.selectTemplate)) {
                            ForEach(controller.templates) { Text($0.name).tag($0.id) }
                        }.disabled(controller.activity.isWorking)
                        Button("Edit templates…", action: controller.manageTemplates)
                        Text("AI notes use the model selected in your Gateway plugin settings. Speech recognition has a separate model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Notes folder") {
                        Text(controller.notesFolder).font(.caption).textSelection(.enabled)
                        Button("Choose folder for future meetings…", action: controller.chooseNotesFolder)
                        Button("Copy existing notes…") { controller.copyExistingNotes() }
                            .disabled(controller.recentMeetings.allSatisfy { !$0.ready })
                        Button("Open notes folder", action: controller.openNotesFolder)
                        Text("Year / month / timestamp and meeting title. Existing notes stay in their original folder, including your edits.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .connection:
                    Section {
                        Text(controller.gatewayStatus).textSelection(.enabled)
                        HStack {
                            Button("Sign in / Connect…", action: controller.connectGateway).disabled(controller.gatewayOperation)
                            if controller.gatewaySigningIn { Button("Cancel", action: controller.cancelSignIn) }
                            else { Button("Check", action: controller.recheckGateway).disabled(controller.gatewayOperation) }
                        }
                        Text("GitHub sign-in opens in your browser. Finished text and meeting details go to your Gateway.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Waiting meetings") {
                        ForEach(controller.recentMeetings.filter { !$0.ready || $0.needsAttention }) { meeting in
                            Button { controller.showMeetingDetails(meeting) } label: {
                                VStack(alignment: .leading) {
                                    Text(meeting.title); Text(meeting.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.buttonStyle(.plain)
                        }
                        Button("Retry sending", action: controller.retrySaving).disabled(controller.gatewayOperation)
                    }
                case .privacy:
                    Section("Where your audio goes") {
                        Text(controller.selectedEngine == "parakeet" ? "Speech recognition runs on this Mac. Audio never falls back to a cloud service." : "Speech recognition runs at ElevenLabs. Audio is uploaded directly from this Mac to ElevenLabs.")
                        Text("Your Gateway receives the finished transcript and meeting details. AI notes send that text to its selected model provider.")
                    }
                    Section("Audio retention") {
                        Toggle("Delete future audio after verified notes", isOn: Binding(get: { controller.deletesVerifiedAudio }, set: controller.setAudioRetention))
                        Text("Applies to recordings started after enabling this setting. Older recordings stay untouched. Audio with capture gaps or missing Teams speech is kept for review.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(controller.storageSummary).font(.callout)
                        Button("Review recorded audio…") { controller.reviewRecordedAudio() }
                            .disabled(controller.recentMeetings.isEmpty)
                        Button("Check storage usage", action: controller.checkStorage)
                        Button("Open recording files", action: controller.openRecordings)
                    }
                case .permissions:
                    Section {
                        permission("Teams call detection", granted: controller.accessibilityGranted, action: controller.allowDetection)
                        permission("Microphone", granted: controller.microphoneGranted, action: controller.allowMicrophone)
                        permission("Teams audio", granted: controller.systemAudioGranted, action: controller.allowSystemAudio)
                        Text("macOS calls the Teams audio permission Screen & System Audio Recording. ClawMinutes saves only audio.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Check again", action: controller.checkPermissions)
                    }
                case .advanced:
                    Section {
                        Text("Speech model: " + controller.modelTitle).textSelection(.enabled)
                        Text("Recognition: " + (controller.displayedBackend == "parakeet" ? "this Mac" : "ElevenLabs cloud"))
                        Button("Open recording files and logs", action: controller.openRecordings)
                        Button(controller.diagnosing ? "Creating report…" : "Save diagnostic report…", action: controller.saveDiagnostics)
                            .disabled(controller.diagnosing)
                        Text("Excludes speech, notes, names and credentials. No Gateway connection or recording changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 690, height: 620).foregroundStyle(.primary)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func permission(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title); Spacer()
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button("Allow…", action: action) }
        }
    }
}
