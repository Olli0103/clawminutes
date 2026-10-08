import SwiftUI

@MainActor
struct HelperPopover: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: MenuBarController
    private var accent: Color { controller.recording ? .red : (controller.isFailure ? .orange : .accentColor) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: MenuBarController.clawMicImage(active: controller.activity.isWorking,
                    appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!,
                    activeColor: controller.recording ? .systemRed : .controlAccentColor))
                    .resizable().scaledToFit().frame(width: 30, height: 30)
                    .padding(11).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("ocmh").font(.caption).foregroundStyle(.secondary)
                    Text(controller.activity.title).font(.title2.weight(.semibold))
                    Text(controller.meetingTitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let detail = controller.detail {
                Text(detail).font(.caption).foregroundStyle(controller.isFailure ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = controller.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: controller.toggleRecording) {
                HStack {
                    Image(systemName: controller.recording ? "stop.fill" : "mic.fill")
                    Text(controller.recording ? "Stop recording" : (controller.startingRecording ? "Starting…" : "Start recording")).fontWeight(.semibold)
                    Spacer()
                    Text("⌘R").foregroundStyle(.white.opacity(0.7))
                }.padding(.vertical, 7).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(controller.recording ? .red : .accentColor)
            .keyboardShortcut("r")
            .disabled(controller.startingRecording)
            Text(controller.recording ? "Stop finishes both tracks, then transcribes." : "Records your microphone and Teams audio on this Mac.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, -10)
            Divider()
            HStack {
                Label("Note template", systemImage: "doc.text")
                Spacer()
                Picker("Note template", selection: Binding(get: { controller.selectedTemplateID }, set: controller.selectTemplate)) {
                    ForEach(controller.templates) { Text($0.name).tag($0.id) }
                }.labelsHidden().disabled(controller.activity.isWorking)
            }
            Text(controller.notesMode == "ai" ? "AI notes use your Gateway’s model and this template." : "Custom template sections need AI notes. Choose notes mode in Settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label("Transcription", systemImage: "waveform")
                Spacer()
                Picker("Transcription", selection: Binding(get: { controller.selectedEngine }, set: controller.selectEngine)) {
                    Text("Local only").tag("parakeet")
                    Text("ElevenLabs").tag("elevenlabs")
                }.labelsHidden().fixedSize().disabled(controller.activity.isWorking)
            }
            Text(controller.displayedBackend == "parakeet"
                ? "\(controller.modelTitle) · this Mac\nAudio stays here. Finished text goes to your Gateway."
                : "\(controller.modelTitle) · ElevenLabs cloud\nAudio is sent to ElevenLabs for recognition.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, -9)
            if controller.selectedEngine == "parakeet" && !controller.localModelReady {
                Button("Download local model…", action: controller.setupLocal).buttonStyle(.bordered)
            }
            if !controller.accessibilityGranted && controller.promptsEnabled {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enable call detection").font(.callout.weight(.medium))
                        Text("Allow ocmh in Accessibility. You can still start manually.").font(.caption).foregroundStyle(.secondary)
                        Button("Open permissions…", action: controller.allowDetection).buttonStyle(.link)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 7) {
                Image(systemName: controller.gatewayStatus.hasPrefix("Gateway connected") ? "checkmark.icloud" : "icloud")
                Text(controller.gatewayStatus.hasPrefix("Gateway connected") ? "Meetings archive connected" : (controller.gatewayOperation ? "Checking archive…" : "Archive needs connection"))
                    .font(.caption)
                Spacer()
                if !controller.gatewayStatus.hasPrefix("Gateway connected") && !controller.gatewayOperation {
                    Button("Connect", action: controller.connectGateway).buttonStyle(.link)
                }
            }.foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(action: controller.openRecordings) { Label("Recordings", systemImage: "folder") }
                    .buttonStyle(.plain).keyboardShortcut("o")
                Spacer()
                Button(action: controller.showSettings) { Image(systemName: "gearshape").padding(4) }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                Button(action: controller.quit) { Image(systemName: "power").padding(4) }
                    .buttonStyle(.plain).help("Quit ocmh").accessibilityLabel("Quit ocmh").keyboardShortcut("q")
            }.foregroundStyle(.secondary)
        }.padding(20).frame(width: 350)
    }
}

@MainActor
struct HelperSettings: View {
    @ObservedObject var controller: MenuBarController
    var body: some View {
        Form {
            Section {
                Button("Open recording controls", action: controller.openMenu)
                Picker("Menu bar", selection: Binding(get: { controller.style }, set: controller.chooseStyle)) {
                    Text("Icon only").tag(MenuBarStyle.iconOnly)
                    Text("Icon and description").tag(MenuBarStyle.descriptive)
                }.pickerStyle(.segmented)
                Text("Red means recording. Orange means an audio gap needs review. Hover for status, model, and execution machine.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Appearance") }
            Section {
                Toggle("Ask when a Teams call starts", isOn: Binding(get: { controller.promptsEnabled }, set: { _ in controller.togglePrompts() }))
                Text("One prompt per call. Dismiss keeps recording off. Manual Start is always available.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.recording { Button("Keep recording after the call ends", action: controller.keepRecording) }
            } header: { Text("Recording") }
            Section {
                HStack {
                    Text(controller.localSpeakerName.isEmpty ? "Your microphone name is not set" : controller.localSpeakerName)
                    Spacer()
                    Button("Your name…", action: controller.editLocalSpeakerName)
                }
                Toggle("Shared microphone · keep speaker unknown", isOn: Binding(get: { controller.sharedMicrophone }, set: controller.setSharedMicrophone))
                Text("The name labels your personal mic track. It does not identify remote voices or prove attendance.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Your voice") }.disabled(controller.activity.isWorking)
            Section {
                Picker("Speech recognition", selection: Binding(get: { controller.selectedEngine }, set: controller.selectEngine)) {
                    Text("Local only · Parakeet v3").tag("parakeet")
                    Text("ElevenLabs · Scribe v2").tag("elevenlabs")
                }.disabled(controller.activity.isWorking)
                Text(controller.displayedBackend == "parakeet" ? "Runs on \(controller.machine). No cloud fallback." : "Runs at ElevenLabs. Recording audio is uploaded to this provider.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if controller.selectedEngine == "parakeet" {
                        Label(controller.localModelReady ? "Local model ready" : "Local model missing", systemImage: controller.localModelReady ? "checkmark.circle" : "exclamationmark.circle")
                        Spacer()
                        if !controller.localModelReady { Button("Download…", action: controller.setupLocal) }
                    } else {
                        Button(controller.hasAPIKey ? "Change API key…" : "Add API key…", action: controller.editAPIKey)
                        if controller.hasAPIKey { Button("Remove key", action: controller.removeAPIKey) }
                    }
                }
                Picker("Meeting notes", selection: Binding(get: { controller.notesMode }, set: controller.chooseNotes)) {
                    Text("AI notes · Gateway model").tag("ai")
                    Text("Simple highlights · no AI model").tag("simple")
                    Text("Transcript only").tag("transcript")
                }.disabled(controller.activity.isWorking)
                Text(controller.notesMode == "ai" ? "Finished text and meeting metadata go to the Gateway’s configured model provider for notes. Audio stays separate. No tools or file access are given to the model." : "Simple mode extracts highlights. Custom section instructions require AI notes. Speech recognition and notes use separate models.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Transcription & notes") }
            Section {
                Picker("Default template", selection: Binding(get: { controller.selectedTemplateID }, set: controller.selectTemplate)) {
                    ForEach(controller.templates) { Text($0.name).tag($0.id) }
                }.disabled(controller.activity.isWorking)
                Button("Edit note templates…", action: controller.manageTemplates)
                Text(controller.notesFolder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Choose notes folder…", action: controller.chooseNotesFolder)
                    Button("Open notes folder", action: controller.openNotesFolder)
                }
                Text("Year / month / timestamp and meeting title. Each meeting contains notes.md, transcript.md and metadata.json.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Delete audio after verified notes", isOn: Binding(get: { controller.deletesVerifiedAudio }, set: controller.setAudioRetention))
                Text("Checks transcript timestamps, saved notes and audio coverage first. Failed or incomplete recordings keep their audio. Transcripts and notes remain.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Note templates & files") }
            Section {
                Text(controller.gatewayStatus).font(.callout).textSelection(.enabled)
                Text("\(controller.pendingArchiveCount) finished meeting(s) waiting to save. Checked automatically every minute.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Connect…", action: controller.connectGateway).disabled(controller.gatewayOperation)
                    if controller.gatewaySigningIn { Button("Cancel sign-in", action: controller.cancelSignIn) }
                    else if controller.gatewayOperation { ProgressView().controlSize(.small) }
                    else { Button("Check connection", action: controller.recheckGateway) }
                    Button("Retry pending saves", action: controller.retrySaving).disabled(controller.gatewayOperation)
                }
                Text("GitHub sign-in uses your browser. Only finished text and metadata go to the Gateway.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Meetings archive") }
            Section {
                permission("Call detection & speaker names", granted: controller.accessibilityGranted, action: controller.allowDetection)
                permission("Microphone", granted: controller.microphoneGranted, action: controller.allowMicrophone)
                permission("Teams audio", granted: controller.systemAudioGranted, action: controller.allowSystemAudio)
                Text("macOS requires Screen & System Audio Recording; ocmh saves only audio. After allowing access, use Check again. If macOS requests a restart, quit and reopen ocmh.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check again", action: controller.checkPermissions)
            } header: { Text("Mac permissions") }
        }.formStyle(.grouped).frame(width: 490, height: 650)
    }
    private func permission(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button("Allow…", action: action) }
        }
    }
}
