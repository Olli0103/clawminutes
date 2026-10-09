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
                    Text(controller.activity.isWorking ? controller.activity.title : "ClawMinutes").font(.title2.weight(.semibold))
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
            }.helperButton(prominent: true).controlSize(.large)
                .tint(controller.recording || controller.captureCheckBusy ? .red : .accentColor)
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
                        Image(systemName: meeting.symbol)
                            .font(.body).frame(width: 32, height: 32)
                            .foregroundStyle(meeting.canVerifyLegacyReceipt ? Color.accentColor : meeting.needsAttention ? .orange : (meeting.ready ? .green : .secondary))
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meeting.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            HStack(spacing: 5) {
                                if let date = meeting.started { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(meeting.statusTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 3)
                        Text(meeting.ready && !meeting.needsAttention ? "Open" : "Review").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityLabel("\(meeting.title), \(meeting.statusTitle)")
            }
            if controller.pendingArchiveCount > 0 && !controller.gatewayOperation {
                Button("\(controller.pendingArchiveCount) waiting to send · Check connection", action: controller.recheckGateway)
                    .buttonStyle(.link).font(.caption)
            }
            Divider()
            HStack {
                Button(action: controller.showSettings) { Label("Settings", systemImage: "gearshape") }.helperButton()
                Spacer()
                Button(controller.promptsEnabled ? "Pause prompts" : "Resume prompts", action: controller.togglePrompts).buttonStyle(.plain)
                Button("Quit", action: controller.quit).buttonStyle(.plain).keyboardShortcut("q")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 400).helperPanel()
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(meeting.title).font(.system(size: 25, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if let date = meeting.started { Text(date, format: .dateTime).font(.callout).foregroundStyle(.secondary) }
                            if meeting.revision > 1 { Text("Version \(meeting.revision)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.bottom, 4)
                    if meeting.needsAttention || meeting.canVerifyLegacyReceipt || meeting.canRetryLocalExport {
                        let guidance = meeting.guidance
                        VStack(alignment: .leading, spacing: 12) {
                            Label(guidance.title, systemImage: guidance.symbol).font(.headline)
                            Text(guidance.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(savingLocalNotes ? "Saving notes…" : guidance.button) { perform(guidance.action, meeting: meeting) }
                                .helperButton(prominent: true).controlSize(.large)
                                .disabled(savingLocalNotes
                                    || ((guidance.action == .signIn || guidance.action == .checkConnection) && controller.gatewayOperation)
                                    || (guidance.action == .supportReport && controller.diagnosing))
                            Text(guidance.footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let localSaveError { Text(localSaveError).font(.callout).foregroundStyle(.orange) }
                        }.helperCard(tint: .accentColor)
                    } else {
                        Label(meeting.statusTitle, systemImage: meeting.symbol).font(.headline).foregroundStyle(meeting.ready ? Color.green : Color.secondary)
                        Text(meeting.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if let unidentifiedTurns, unidentifiedTurns > 0 {
                        Label("\(unidentifiedTurns) passages have an unknown speaker. Names are shown only when speaker evidence supports them.", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        if let notes = meeting.notes {
                            Button { controller.openDocument(notes) } label: { Label("Open notes", systemImage: "doc.text") }.helperButton(prominent: !meeting.needsAttention)
                        }
                        if let transcript = meeting.transcript {
                            Button { controller.openDocument(transcript) } label: { Label("Open transcript", systemImage: "text.alignleft") }.helperButton()
                        }
                    }
                    Divider().padding(.vertical, 4)
                    HStack {
                        Menu {
                            if meeting.notes != nil {
                                Button("Copy notes") { controller.copyNotes(meeting) }
                                Button("Copy notes to another folder…") { controller.copyExistingNotes([meeting]) }
                            }
                            if meeting.ready && meeting.transcript != nil {
                                Button("Identify speakers…") { revisionMode = .speakers }
                                Button("Regenerate notes…") { revisionMode = .template }
                            }
                            if meeting.canVerifyLegacyReceipt { Button("Find saved notes") { verifyingLegacyReceipt = true } }
                            if meeting.canSaveTranscriptOnly { Button("Save transcript without AI…") { recoveryKind = .transcriptOnly } }
                            if meeting.canRetryAINotes { Button("Try AI notes again…") { recoveryKind = .retryAI } }
                            Button("Delete this meeting's audio…") { controller.reviewRecordedAudio([meeting]) }
                            Button("Show files in Finder") { controller.openDocument(meeting.directory) }
                        } label: { Label("More options", systemImage: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        Spacer()
                    }
                    DisclosureGroup("Technical details") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meeting.detail).font(.caption).textSelection(.enabled)
                            Text(meeting.issue?.code ?? meeting.stage.rawValue).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(.top, 6)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .sheet(item: $revisionMode) { mode in MeetingRevisionEditor(controller: controller, meeting: meeting, mode: mode) }
                    .sheet(isPresented: $verifyingLegacyReceipt) { LegacyReceiptView(controller: controller, meeting: meeting, automaticallyCheck: true) }
                    .sheet(item: $recoveryKind) { kind in NotesRecoveryEditor(controller: controller, meeting: meeting, kind: kind) }
            } else { Text("This meeting is no longer in the current list.").padding(24) }
        }.frame(minWidth: 480, minHeight: 440).helperPanel()
            .task(id: meetingID) {
                unidentifiedTurns = nil
                guard let meeting = controller.recentMeetings.first(where: { $0.id == meetingID }) else { return }
                unidentifiedTurns = try? await Task.detached {
                    let transcript = try JSONDecoder().decode(Transcript.self, from: ArchiveBacklog.read(meeting.directory.appendingPathComponent("transcript.json")))
                    return transcript.segments.filter { $0.speaker_name == nil }.count
                }.value
            }
    }
    private func perform(_ action: MeetingGuidance.Action, meeting: RecentMeeting) {
        switch action {
        case .findNotes: verifyingLegacyReceipt = true
        case .downloadModel: controller.setupLocal()
        case .addSpeechKey: controller.editAPIKey()
        case .signIn: controller.connectGateway()
        case .checkConnection: controller.recheckGateway()
        case .retryAI: recoveryKind = .retryAI
        case .transcriptOnly: recoveryKind = .transcriptOnly
        case .openTranscript: if let transcript = meeting.transcript { controller.openDocument(transcript) }
        case .supportReport: controller.saveDiagnostics()
        case .saveLocalNotes:
            guard !savingLocalNotes else { return }
            savingLocalNotes = true; localSaveError = nil
            Task {
                do { _ = try await Task.detached { try VerifiedLocalExport.perform(meeting.directory, explicit: true) }.value }
                catch { localSaveError = DeliveryFailure.classify(error).detail }
                savingLocalNotes = false
                await controller.refreshLocalMeetings()
            }
        }
    }
}

enum HelperSettingsPage: String, CaseIterable, Identifiable {
    case general = "General", recording = "Recording", notes = "Notes", connection = "Connection"
    case privacy = "Privacy & storage", permissions = "Permissions", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .recording: return "mic"
        case .notes: return "doc.text"
        case .connection: return "network"
        case .privacy: return "lock.shield"
        case .permissions: return "checkmark.shield"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
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
                Text("ClawMinutes").font(.title3.weight(.semibold)).padding(.bottom, 3)
                Text("Settings").font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                ForEach(HelperSettingsPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.symbol).font(.callout.weight(page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 9)
                            .background(page == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
            }.padding(14).frame(width: 190).background(.ultraThinMaterial)
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
                                    Text(meeting.title); Text(meeting.statusTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                    Section("Recording storage") {
                        Text(controller.storageSummary).font(.callout.weight(.medium)).monospacedDigit()
                        Button(role: .destructive) { controller.reviewRecordedAudio() } label: {
                            Label("Delete old audio…", systemImage: "trash")
                        }.helperButton(prominent: true).tint(.red).controlSize(.large)
                            .disabled(controller.recentMeetings.isEmpty)
                        Text("Selects audio from verified saved meetings. Review the space to free, then confirm once. Notes and transcripts stay.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(action: controller.checkStorage) { Label("Refresh", systemImage: "arrow.clockwise") }
                            Button("Open recordings", action: controller.openRecordings)
                        }.controlSize(.small)
                    }
                    Section("Future recordings") {
                        Toggle("Automatically delete audio after saving notes", isOn: Binding(get: { controller.deletesVerifiedAudio }, set: controller.setAudioRetention))
                        Text("Applies to new recordings only. Audio with gaps or missing Teams speech is kept for recovery.")
                            .font(.caption).foregroundStyle(.secondary)
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
            }.formStyle(.grouped).helperButton().controlSize(.large)
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
