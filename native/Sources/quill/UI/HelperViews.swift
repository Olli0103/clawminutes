import SwiftUI

@MainActor
struct HelperPopover: View {
    @ObservedObject var controller: MenuBarController
    @Environment(\.cmReviewRendering) private var reviewRendering
    @Bindable var state: AppState
    init(controller: MenuBarController) { self.controller = controller; state = controller.appState }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                StatusHeadline(state: state)
                Button { controller.showSettings(page: .privacy) } label: {
                    Label(state.selectedEngine == "parakeet" ? "On this Mac" : "Cloud speech", systemImage: "lock.shield")
                        .font(.caption).fixedSize().padding(.horizontal, 7).padding(.vertical, 4)
                }.buttonStyle(.plain).cmGlass().help("Open Privacy & storage settings")
            }
            RecordingBar(state: state, toggle: controller.toggleRecording,
                         levels: { controller.audioLevels?() ?? (0, 0) }, enableMeters: { controller.enableAudioMeters?($0) })
            if state.headline == .processing || state.headline == .sending,
               let meeting = state.recentMeetings.first(where: { [.recorded, .transcribing, .transcribed, .delivering, .delivered].contains($0.stage) }) {
                Text(meeting.title).font(.callout.weight(.medium)).lineLimit(2)
                PipelineSteps(stage: meeting.stage, verifiedCompletion: meeting.pipelineCompletion)
            }
            if state.micLost && state.recording {
                Label("The microphone is not delivering audio. Check its connection.", systemImage: "mic.slash")
                    .font(.callout).foregroundStyle(.primary)
                Button("Check microphone", action: controller.showSetup).helperButton()
            }
            if state.attentionGroups.count > 3 {
                ScrollView { attentionBanners }.frame(maxHeight: 144)
            } else {
                attentionBanners
            }
            Divider()
            HStack {
                Text("Recent meetings").font(.headline)
                Spacer()
                Button("See all", action: controller.showLibrary).cmLinkButton()
            }
            if state.recentMeetings.isEmpty {
                Text("Your next recording will appear here.").font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            } else if reviewRendering {
                VStack(spacing: 0) {
                    ForEach(Array(state.recentMeetings.prefix(CMLayout.recentLimit))) { meeting in
                        MeetingRow(meeting: meeting)
                        Divider()
                    }
                }
            } else {
                List(selection: $state.selectedMeetingID) {
                    ForEach(Array(state.recentMeetings.prefix(CMLayout.recentLimit))) { meeting in
                        MeetingRow(meeting: meeting, rename: { await controller.renameMeeting(meeting, title: $0) }).tag(meeting.id)
                            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .contentMargins(.vertical, 0, for: .scrollContent)
                    .frame(height: CGFloat(min(CMLayout.recentLimit, state.recentMeetings.count)) * CMLayout.recentRowHeight)
                    .onKeyPress(.return) {
                        guard let meeting = state.recentMeetings.first(where: { $0.id == state.selectedMeetingID }) else { return .ignored }
                        controller.openMeeting(meeting); return .handled
                    }
                    .onTapGesture(count: 2) {
                        if let meeting = state.recentMeetings.first(where: { $0.id == state.selectedMeetingID }) { controller.openMeeting(meeting) }
                    }
            }
            HStack {
                Button { controller.showSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
                Button(action: controller.openNotesFolder) { Image(systemName: "folder") }
                    .help("Open notes folder").accessibilityLabel("Open notes folder")
                Spacer()
                Menu {
                    Button(state.promptsEnabled ? "Pause meeting prompts" : "Resume meeting prompts", action: controller.togglePrompts)
                    Button("Quit ClawMinutes", action: controller.quit).keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis").foregroundStyle(.primary) }
                    .menuIndicator(.hidden).help("More actions").accessibilityLabel("More actions")
            }.cmBorderlessButton().controlSize(.regular).padding(.horizontal, 10).padding(.vertical, 7).cmGlass()
        }.padding(CMLayout.popoverInset).frame(width: CMLayout.popoverWidth).tint(CMTheme.accent).foregroundStyle(.primary)
            .modifier(CMPopoverSurface())
            .onAppear { state.popoverVisible = true }
            .onDisappear { state.popoverVisible = false }

    }
    private var attentionBanners: some View {
        VStack(spacing: 8) {
            ForEach(state.attentionGroups) { group in
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("\(group.meetings.count) \(group.meetings.count == 1 ? "meeting" : "meetings") · \(group.title)")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(group.action) {
                        switch group.cause {
                        case .signIn: controller.connectGateway()
                        case .gateway: controller.recheckGateway()
                        default:
                            if group.meetings.count == 1, let meeting = group.meetings.first { controller.showMeetingDetails(meeting) }
                            else { controller.showAttentionGroup(group) }
                        }
                    }.helperButton().fixedSize()
                }
            }
        }
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
    @State private var showInspector = false
    @State private var titleDraft = ""
    @State private var renameError: String?

    var body: some View {
        ScrollView {
            if let meeting = controller.recentMeetings.first(where: { $0.id == meetingID }) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                        TextField("Meeting title", text: $titleDraft).textFieldStyle(.plain).font(.title.bold())
                            .accessibilityLabel("Meeting title").help("Rename this meeting. Press Return to save.")
                            .onAppear { titleDraft = meeting.title }
                            .onSubmit {
                                Task {
                                    if await controller.renameMeeting(meeting, title: titleDraft) { renameError = nil }
                                    else { renameError = "The title could not be saved. Finish any active recording or save, then try again." }
                                }
                            }
                            Button { showInspector.toggle() } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.borderless).help("Show technical details").accessibilityLabel("Show technical details")
                        }
                        if let renameError { Text(renameError).font(.callout) }
                        HStack {
                            if let date = meeting.started { Text(MeetingDate.string(date)).font(.callout).foregroundStyle(.primary) }
                            if meeting.revision > 1 { Text("Version \(meeting.revision)").font(.caption).foregroundStyle(.primary) }
                        }
                    }.padding(.bottom, 4)
                    PipelineSteps(stage: meeting.stage, verifiedCompletion: meeting.pipelineCompletion)
                    if meeting.needsAttention || meeting.canVerifyLegacyReceipt || meeting.canRetryLocalExport {
                        let guidance = meeting.guidance
                        VStack(alignment: .leading, spacing: 12) {
                            Label(guidance.title, systemImage: guidance.symbol).font(.headline)
                            Text(guidance.message).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                            Button(savingLocalNotes ? "Saving notes…" : guidance.button) { perform(guidance.action, meeting: meeting) }
                                .helperButton(prominent: true).controlSize(.large)
                                .disabled(savingLocalNotes
                                    || ((guidance.action == .signIn || guidance.action == .checkConnection) && controller.gatewayOperation)
                                    || (guidance.action == .supportReport && controller.diagnosing))
                            Text(guidance.footnote).font(.caption).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                            if let localSaveError { Text(localSaveError).font(.callout).foregroundStyle(.primary) }
                        }.helperCard(tint: .accentColor)
                    } else {
                        Label(meeting.statusTitle, systemImage: meeting.symbol).font(.headline).foregroundStyle(.primary)
                        Text(meeting.ready ? "Your notes and transcript are saved." : "Your meeting is being prepared.").font(.callout)
                    }
                    if let unidentifiedTurns, unidentifiedTurns > 0 {
                        Label("\(unidentifiedTurns) passages have an unknown speaker. Names are shown only when speaker evidence supports them.", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
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
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .sheet(item: $revisionMode) { mode in MeetingRevisionEditor(controller: controller, meeting: meeting, mode: mode) }
                    .sheet(isPresented: $verifyingLegacyReceipt) { LegacyReceiptView(controller: controller, meeting: meeting, automaticallyCheck: true) }
                    .sheet(item: $recoveryKind) { kind in NotesRecoveryEditor(controller: controller, meeting: meeting, kind: kind) }
            } else { Text("This meeting is no longer in the current list.").padding(24) }
        }.frame(minWidth: 480, minHeight: 440).helperPanel()
            .inspector(isPresented: $showInspector) {
                if let meeting = controller.recentMeetings.first(where: { $0.id == meetingID }) {
                    Form {
                        Section("Technical details") {
                            Text(meeting.detail).textSelection(.enabled)
                            Text(meeting.issue?.code ?? meeting.stage.rawValue).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }.formStyle(.grouped).inspectorColumnWidth(260)
                }
            }
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
    var preferredHeight: CGFloat {
        switch self {
        case .general: 280
        case .recording: 350
        case .notes: 470
        case .connection: 470
        case .privacy: 470
        case .permissions: 300
        case .advanced: 280
        }
    }
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
    @Bindable private var state: AppState
    private var page: HelperSettingsPage { state.settingsPage }
    init(controller: MenuBarController) {
        self.controller = controller; state = controller.appState
    }
    var body: some View {
        NavigationSplitView {
            List(HelperSettingsPage.allCases, selection: $state.settingsPage) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }.navigationTitle("Settings").navigationSplitViewColumnWidth(180)
        } detail: {
            Form {
                switch page {
                case .general:
                    Section {
                        Picker("Menu bar", selection: Binding(get: { controller.style }, set: controller.chooseStyle)) {
                            Text("Icon only").tag(MenuBarStyle.iconOnly)
                            Text("Icon and description").tag(MenuBarStyle.descriptive)
                        }.pickerStyle(.segmented)
                        Toggle("Ask when a Teams call starts", isOn: Binding(get: { controller.promptsEnabled }, set: { _ in controller.togglePrompts() }))
                        Toggle("Launch at login", isOn: Binding(get: { controller.loginStatus.enabled == true }, set: controller.setLaunchAtLogin))
                            .disabled(controller.loginStatus.enabled == nil)
                        if let issue = controller.loginSettingError {
                            Text(issue).font(.caption).foregroundStyle(.primary)
                        }
                        if controller.loginStatus.enabled == nil || controller.loginSettingError != nil {
                            Button("Check login setting again", action: controller.refreshLoginSetting)
                        }
                        HStack {
                            Button("Setup checklist…", action: controller.showSetup)
                            Button("Recording controls", action: controller.openMenu)
                        }
                    } footer: {
                        Text("One prompt per call. Dismiss keeps audio off. You can always start from the menu bar.\n" + controller.loginStatus.detail)
                            .cmFormFootnote()
                    }
                case .recording:
                    Section {
                        HStack {
                            Text(controller.localSpeakerName.isEmpty ? "Your name is not set" : controller.localSpeakerName)
                            Spacer(); Button("Your name…", action: controller.editLocalSpeakerName)
                        }
                        Toggle("Shared microphone", isOn: Binding(get: { controller.sharedMicrophone }, set: controller.setSharedMicrophone))
                    } footer: {
                        Text("Your name labels your personal microphone. A shared microphone keeps speakers unknown.")
                            .cmFormFootnote()
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
                    } footer: {
                        Text("AI notes use the model selected in your Gateway plugin settings. Speech recognition has a separate model.")
                            .cmFormFootnote()
                    }
                    Section {
                        Text(controller.notesFolder).font(.caption).textSelection(.enabled)
                        Button("Choose folder for future meetings…", action: controller.chooseNotesFolder)
                        Button("Copy existing notes…") { controller.copyExistingNotes() }
                            .disabled(controller.recentMeetings.allSatisfy { !$0.ready })
                        Button("Open notes folder", action: controller.openNotesFolder)
                    } header: { Text("Notes folder") } footer: {
                        Text("Year / month / timestamp and meeting title. Existing notes stay in their original folder, including your edits.")
                            .cmFormFootnote()
                    }
                case .connection:
                    Section {
                        Text(controller.gatewayStatus).textSelection(.enabled)
                        HStack {
                            Button("Sign in / Connect…", action: controller.connectGateway).disabled(controller.gatewayOperation)
                            if controller.gatewaySigningIn { Button("Cancel", action: controller.cancelSignIn) }
                            else { Button("Check", action: controller.recheckGateway).disabled(controller.gatewayOperation) }
                        }
                    } footer: {
                        Text("GitHub sign-in opens in your browser. Finished text and meeting details go to your Gateway.")
                            .cmFormFootnote()
                    }
                    Section("Waiting meetings") {
                        ForEach(controller.recentMeetings.filter { !$0.ready || $0.needsAttention }) { meeting in
                            Button { controller.showMeetingDetails(meeting) } label: {
                                VStack(alignment: .leading) {
                                    Text(meeting.title); Text(meeting.statusTitle).font(.caption).foregroundStyle(.primary).lineLimit(2)
                                }
                            }.buttonStyle(.plain)
                        }
                        Button("Retry sending", action: controller.retrySaving).disabled(controller.gatewayOperation)
                    }
                case .privacy:
                    Section("Where your audio goes") {
                        Text(controller.selectedEngine == "parakeet" ? "Audio stays on this Mac. Your Gateway receives text and meeting details for AI notes." : "Audio goes directly to ElevenLabs for speech recognition. Your Gateway receives text and meeting details for AI notes.")
                    }
                    Section {
                        StoragePill(bytes: controller.appState.recordingBytes, free: controller.appState.freeBytes, capacity: controller.appState.capacityBytes)
                        HStack {
                            Button { controller.reviewRecordedAudio() } label: {
                                Label("Delete old audio…", systemImage: "trash")
                            }.buttonStyle(.bordered).disabled(controller.recentMeetings.isEmpty)
                            Spacer()
                            Button(action: controller.checkStorage) { Image(systemName: "arrow.clockwise") }
                                .help("Refresh storage usage").accessibilityLabel("Refresh storage usage")
                            Button(action: controller.openRecordings) { Image(systemName: "folder") }
                                .help("Open recording files").accessibilityLabel("Open recording files")
                        }
                    } header: { Text("Recording storage") } footer: {
                        Text("Selects audio from verified saved meetings. Review the space to free, then confirm once. Notes and transcripts stay.")
                            .cmFormFootnote()
                    }
                    Section {
                        Toggle("Automatically delete audio after saving notes", isOn: Binding(get: { controller.deletesVerifiedAudio }, set: controller.setAudioRetention))
                    } header: { Text("Future recordings") } footer: {
                        Text("Applies to new recordings only. Audio with gaps or missing Teams speech is kept for recovery.")
                            .cmFormFootnote()
                    }
                case .permissions:
                    Section {
                        permission("Teams call detection", granted: controller.accessibilityGranted, action: controller.allowDetection)
                        permission("Microphone", granted: controller.microphoneGranted, action: controller.allowMicrophone)
                        permission("Teams audio", granted: controller.systemAudioGranted, action: controller.allowSystemAudio)
                        Button("Check again", action: controller.checkPermissions)
                    } footer: {
                        Text("macOS calls the Teams audio permission Screen & System Audio Recording. ClawMinutes saves only audio.")
                            .cmFormFootnote()
                    }
                case .advanced:
                    Section {
                        Text("Speech model: " + controller.modelTitle).textSelection(.enabled)
                        Text("Recognition: " + (controller.displayedBackend == "parakeet" ? "this Mac" : "ElevenLabs cloud"))
                        Button("Open recording files and logs", action: controller.openRecordings)
                        Button(controller.diagnosing ? "Creating report…" : "Save diagnostic report…", action: controller.saveDiagnostics)
                            .disabled(controller.diagnosing)
                    } footer: {
                        Text("The diagnostic report excludes speech, notes, names and credentials. Creating it keeps your recording and connection running.")
                            .cmFormFootnote()
                    }
                }
            }.formStyle(.grouped).controlSize(.regular)
        }.frame(width: 690, height: page.preferredHeight).foregroundStyle(.primary).tint(CMTheme.accent)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: page, initial: true) { _, value in controller.fitSettingsWindow(value) }
    }
    private func permission(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title); Spacer()
            if granted { Label { Text("Allowed").foregroundStyle(.primary) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
            else { Button("Allow…", action: action) }
        }
    }
}
