import SwiftUI

@MainActor
struct HelperPopover: View {
    @ObservedObject var controller: MenuBarController
    @Environment(\.cmReviewRendering) private var reviewRendering
    @Bindable var state: AppState
    init(controller: MenuBarController) { self.controller = controller; state = controller.appState }
    private var active: Bool { state.recording || state.callDetected || state.headline == .processing || state.headline == .sending }
    private var recentLimit: Int { state.recording ? 2 : CMLayout.recentLimit }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeadline(state: state)
            if state.headline == .processing || state.headline == .sending,
               let meeting = state.recentMeetings.first(where: { [.recorded, .transcribing, .transcribed, .delivering, .delivered].contains($0.stage) }) {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(meeting.pipelineCompletion), total: 4).cmProgress()
                    Text(state.headline == .processing ? "Transcribing on this Mac" : "Saving notes and transcript")
                        .font(.caption).foregroundStyle(CMTheme.secondary)
                }
            }
            RecordingBar(state: state, toggle: controller.toggleRecording,
                         levels: { controller.audioLevels?() ?? (0, 0) }, enableMeters: { controller.enableAudioMeters?($0) })
            if state.micLost && state.recording {
                HStack {
                    Text("Microphone not receiving audio").font(.caption)
                    Spacer(minLength: 4)
                    Button("Check", action: controller.showSetup).cmLinkButton().font(.caption)
                }
            }
            if !state.attentionGroups.isEmpty { attentionSummary }
            Divider()
            HStack {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(CMTheme.secondary)
                Spacer()
                Button("See all", action: controller.showLibrary).cmLinkButton().font(.caption)
            }
            if state.recentMeetings.isEmpty {
                Text("Recordings appear here.").font(.callout).foregroundStyle(CMTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            } else if reviewRendering {
                VStack(spacing: 0) {
                    ForEach(Array(state.recentMeetings.prefix(recentLimit))) { meeting in
                        MeetingRow(meeting: meeting)
                    }
                }
            } else {
                List(selection: $state.selectedMeetingID) {
                    ForEach(Array(state.recentMeetings.prefix(recentLimit))) { meeting in
                        MeetingRow(meeting: meeting, rename: { await controller.renameMeeting(meeting, title: $0) }).tag(meeting.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, CMLayout.recentRowHeight)
                    .contentMargins(.vertical, 0, for: .scrollContent)
                    .frame(height: CGFloat(min(recentLimit, state.recentMeetings.count)) * CMLayout.recentRowHeight)
                    .onKeyPress(.return) {
                        guard let meeting = state.recentMeetings.first(where: { $0.id == state.selectedMeetingID }) else { return .ignored }
                        controller.openMeeting(meeting); return .handled
                    }
                    .onTapGesture(count: 2) {
                        if let meeting = state.recentMeetings.first(where: { $0.id == state.selectedMeetingID }) { controller.openMeeting(meeting) }
                    }
            }
            HStack(spacing: 12) {
                Button { controller.showSettings(page: .privacy) } label: {
                    Label(state.selectedEngine == "parakeet" ? "On this Mac" : "Cloud speech", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(CMTheme.secondary)
                }.help("Open Privacy & storage settings").accessibilityLabel("Audio privacy settings")
                Spacer(minLength: 0)
                Button(action: controller.openNotesFolder) { Image(systemName: "folder") }
                    .help("Open notes folder").accessibilityLabel("Open notes folder")
                Button { controller.showSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
                Menu {
                    Button(action: controller.togglePrompts) { Label(state.promptsEnabled ? "Pause meeting prompts" : "Resume meeting prompts", systemImage: state.promptsEnabled ? "pause" : "play") }
                    Button(action: controller.quit) { Label("Quit ClawMinutes", systemImage: "power") }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).help("More actions").accessibilityLabel("More actions")
            }.cmBorderlessButton().controlSize(.small).foregroundStyle(CMTheme.secondary).padding(.top, 3)
        }.padding(.horizontal, CMLayout.popoverInset).padding(.vertical, 12)
            .frame(width: CMLayout.popoverWidth).tint(CMTheme.accent)
            .onAppear { state.popoverVisible = true }
            .onDisappear { state.popoverVisible = false }
    }
    @ViewBuilder private var attentionSummary: some View {
        if active {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                Text(state.attentionSummaryText)
                    .foregroundStyle(CMTheme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if state.attentionGroups.count == 1, let group = state.attentionGroups.first {
                    Button(group.action) { review(group) }.cmButton().controlSize(.small).fixedSize()
                } else { Button("Review", action: controller.showAllAttention).cmButton().controlSize(.small).fixedSize() }
            }.font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(state.attentionGroups.prefix(2))) { group in
                    HStack(spacing: 6) {
                        if state.attentionMeetings.count > 1 {
                            Text("\(group.title) · \(group.meetings.count)").foregroundStyle(CMTheme.secondary).lineLimit(1).help(group.title)
                        }
                        Spacer(minLength: 2)
                        Button(group.action) { review(group) }.cmButton().controlSize(.small).fixedSize()
                    }.font(.caption)
                }
                if state.attentionGroups.count > 2 {
                    Button("+\(state.attentionGroups.count - 2) more", action: controller.showAllAttention).cmLinkButton().font(.caption)
                }
            }
        }
    }
    private func review(_ group: AttentionGroup) {
        switch group.cause {
        case .signIn: controller.connectGateway()
        case .gateway: controller.recheckGateway()
        default:
            if group.meetings.count == 1, let meeting = group.meetings.first { controller.showMeetingDetails(meeting) }
            else { controller.showAttentionGroup(group) }
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

                        }
                        if let renameError { Text(renameError).font(.callout) }
                        HStack {
                            if let date = meeting.started { Text(MeetingDate.string(date)).font(.callout).foregroundStyle(CMTheme.secondary) }
                            if meeting.revision > 1 { Text("Version \(meeting.revision)").font(.caption).foregroundStyle(CMTheme.secondary) }
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
                            Text(guidance.footnote).font(.caption).foregroundStyle(CMTheme.secondary).fixedSize(horizontal: false, vertical: true)
                            if let localSaveError { Text(localSaveError).font(.callout).foregroundStyle(.primary) }
                        }.helperCard(tint: .accentColor)
                    } else {
                        Label(meeting.statusTitle, systemImage: meeting.symbol).font(.headline).foregroundStyle(.primary)
                        Text(meeting.ready ? "Your notes and transcript are saved." : "Your meeting is being prepared.").font(.callout)
                    }
                    if let unidentifiedTurns, unidentifiedTurns > 0 {
                        Label("\(unidentifiedTurns) passages have an unknown speaker. Names are shown only when speaker evidence supports them.", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption).foregroundStyle(CMTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .sheet(item: $revisionMode) { mode in MeetingRevisionEditor(controller: controller, meeting: meeting, mode: mode) }
                    .sheet(isPresented: $verifyingLegacyReceipt) { LegacyReceiptView(controller: controller, meeting: meeting, automaticallyCheck: true) }
                    .sheet(item: $recoveryKind) { kind in NotesRecoveryEditor(controller: controller, meeting: meeting, kind: kind) }
            } else { Text("This meeting is no longer in the current list.").padding(24) }
        }.frame(minWidth: 440, minHeight: 400)
            .toolbar {
                if let meeting = controller.recentMeetings.first(where: { $0.id == meetingID }) {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let notes = meeting.notes {
                            Button { controller.openDocument(notes) } label: { Label("Open notes", systemImage: "doc.text") }.help("Open notes")
                        }
                        if let transcript = meeting.transcript {
                            Button { controller.openDocument(transcript) } label: { Label("Open transcript", systemImage: "text.alignleft") }.help("Open transcript")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if meeting.notes != nil {
                                Button { controller.copyNotes(meeting) } label: { Label("Copy notes", systemImage: "doc.on.doc") }
                                Button { controller.copyExistingNotes([meeting]) } label: { Label("Copy notes to another folder…", systemImage: "folder.badge.plus") }
                            }
                            if meeting.ready && meeting.transcript != nil {
                                Button { revisionMode = .speakers } label: { Label("Identify speakers…", systemImage: "person.crop.circle.badge.questionmark") }
                                Button { revisionMode = .template } label: { Label("Regenerate notes…", systemImage: "arrow.clockwise") }
                            }
                            if meeting.canVerifyLegacyReceipt { Button("Find saved notes") { verifyingLegacyReceipt = true } }
                            if meeting.canSaveTranscriptOnly { Button("Save transcript without AI…") { recoveryKind = .transcriptOnly } }
                            if meeting.canRetryAINotes { Button("Try AI notes again…") { recoveryKind = .retryAI } }
                            Button { controller.reviewRecordedAudio([meeting]) } label: { Label("Delete this meeting's audio…", systemImage: "trash") }
                            Button { controller.openDocument(meeting.directory) } label: { Label("Show files in Finder", systemImage: "folder") }
                        } label: { Label("More actions", systemImage: "ellipsis") }.help("Meeting actions")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInspector.toggle() } label: { Label("Technical details", systemImage: "sidebar.trailing") }
                            .help("Show technical details").accessibilityLabel("Show technical details")
                    }
                }
            }
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
            }.navigationTitle("Settings").navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 210)
        } detail: {
            Form {
                switch page {
                case .general:
                    Section {
                        HStack {
                            Text("Menu bar")
                            Spacer()
                            Picker("Menu bar", selection: Binding(get: { controller.style }, set: controller.chooseStyle)) {
                                Text("Icon only").tag(MenuBarStyle.iconOnly)
                                Text("Icon and description").tag(MenuBarStyle.descriptive)
                            }.labelsHidden().pickerStyle(.menu).fixedSize()
                        }
                        Toggle(isOn: Binding(get: { controller.promptsEnabled }, set: { _ in controller.togglePrompts() })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Detect Teams calls")
                                Text("Ask once. Dismissing keeps recording off.").font(.caption).foregroundStyle(CMTheme.secondary)
                            }
                        }.accessibilityLabel("Detect Teams calls").accessibilityHint("Ask once. Dismissing keeps recording off.")
                        Toggle(isOn: Binding(get: { controller.loginStatus.enabled == true }, set: controller.setLaunchAtLogin)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Launch at login")
                                Text(controller.loginStatus.detail).font(.caption).foregroundStyle(CMTheme.secondary)
                            }
                        }.accessibilityLabel("Launch at login").accessibilityHint(controller.loginStatus.detail)
                            .disabled(controller.loginStatus.enabled == nil)
                        if let issue = controller.loginSettingError {
                            Text(issue).font(.caption).foregroundStyle(CMTheme.secondary)
                        }
                        if controller.loginStatus.enabled == nil || controller.loginSettingError != nil {
                            Button("Check login setting again", action: controller.refreshLoginSetting)
                        }
                        Button("Setup checklist…", action: controller.showSetup)
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
                        LabeledContent("Folder") {
                            Text((controller.notesFolder as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(CMTheme.secondary).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).help(controller.notesFolder)
                            Button("Change…", action: controller.chooseNotesFolder)
                        }
                        HStack {
                            Button("Open folder", action: controller.openNotesFolder)
                            Button("Copy existing notes…") { controller.copyExistingNotes() }
                                .disabled(controller.recentMeetings.allSatisfy { !$0.ready })
                        }.controlSize(.small)
                    } header: { Text("Notes folder") } footer: {
                        Text("New meetings use year / month / date and title. Existing notes stay where they are.")
                            .cmFormFootnote()
                    }
                case .connection:
                    Section {
                        LabeledContent("Gateway") {
                            Label(connectionTitle, systemImage: controller.gatewayStatus.hasPrefix("Gateway connected") ? "checkmark.circle.fill" : "icloud")
                                .font(.callout).foregroundStyle(CMTheme.secondary)
                            if controller.gatewaySigningIn { Button("Cancel", action: controller.cancelSignIn) }
                            else {
                                Button(controller.gatewayStatus.hasPrefix("Gateway connected") ? "Check" : "Connect…") {
                                    if controller.gatewayStatus.hasPrefix("Gateway connected") { controller.recheckGateway() }
                                    else { controller.connectGateway() }
                                }.disabled(controller.gatewayOperation)
                            }
                        }
                    } footer: {
                        Text("Sign in with GitHub in your browser. Only finished text goes to the Gateway.")
                            .cmFormFootnote()
                    }
                    Section("Waiting meetings") {
                        ForEach(controller.recentMeetings.filter { !$0.ready || $0.needsAttention }) { meeting in
                            Button { controller.showMeetingDetails(meeting) } label: {
                                MeetingRow(meeting: meeting)
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
                        Text("Review verified audio before deleting. Notes and transcripts stay.")
                            .cmFormFootnote()
                    }
                    Section {
                        Toggle(isOn: Binding(get: { controller.deletesVerifiedAudio }, set: controller.setAudioRetention)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Delete audio after notes are saved")
                                Text("New recordings only. Audio with gaps is kept.").font(.caption).foregroundStyle(CMTheme.secondary)
                            }
                        }.accessibilityLabel("Delete audio after notes are saved").accessibilityHint("New recordings only. Audio with gaps is kept.")
                    } header: { Text("Future recordings") }
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
                        Button("Recording controls", action: controller.openMenu)
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
        }.navigationSplitViewStyle(.balanced)
            .frame(minWidth: CMLayout.settingsWidth, minHeight: 440).tint(CMTheme.accent)

            .onChange(of: page, initial: true) { _, value in controller.updateSettingsTitle(value) }
    }
    private var connectionTitle: String {
        if controller.gatewaySigningIn { return "Signing in…" }
        if controller.gatewayOperation { return "Checking…" }
        if controller.gatewayStatus.hasPrefix("Gateway connected") { return "Connected" }
        return "Not connected"
    }
    private func permission(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title); Spacer()
            if granted { Label { Text("Allowed").foregroundStyle(CMTheme.secondary) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
            else { Button("Allow…", action: action) }
        }
    }
}
