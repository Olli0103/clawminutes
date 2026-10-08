import SwiftUI

/// Opening setup only reads current state. Every permission request, download,
/// sign-in and audio check requires its own visible action.
@MainActor struct SetupChecklistView: View {
    @ObservedObject var controller: MenuBarController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Before your first meeting").font(.title2.weight(.semibold))
                Text("ClawMinutes records only after you choose Start. Work through these checks now, or return from Settings later.")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        row("Microphone", ready: controller.microphoneGranted, action: "Allow microphone…", run: controller.allowMicrophone)
                        row("Teams audio", ready: controller.systemAudioGranted, action: "Allow Teams audio…", run: controller.allowSystemAudio)
                        row("Detect Teams calls", ready: controller.accessibilityGranted, action: "Allow detection…", run: controller.allowDetection)
                        Text("Detection is optional. Without it, start and stop manually. macOS names Teams audio access Screen & System Audio Recording. No screen video is saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                } label: { Label("1. Allow access", systemImage: "lock.shield") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        if controller.selectedEngine == "parakeet" {
                            row("Local speech recognition", ready: controller.localModelReady, action: "Download local model…", run: controller.setupLocal)
                            Text("Speech recognition stays on this Mac. Model download needs an internet connection.")
                        } else {
                            row("ElevenLabs speech recognition", ready: controller.hasAPIKey, action: "Add API key…", run: controller.editAPIKey)
                            Text("Meeting audio goes directly from this Mac to ElevenLabs.")
                        }
                    }.padding(8)
                } label: { Label("2. Prepare speech recognition", systemImage: "waveform") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        row("Save text and create notes", ready: controller.gatewayReady, action: "Connect Gateway…", run: controller.connectGateway)
                        Text(controller.gatewayStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("You can record before connecting. Finished text waits on this Mac. AI notes use your Gateway’s model; audio never goes to the Gateway.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                } label: { Label("3. Connect your Gateway", systemImage: "cloud") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Open Teams. Speak and play a sound in Teams during the check. It records your microphone and Teams audio for 10 seconds, then discards the test audio. It does not transcribe or send anything.")
                        if let phase = controller.captureCheckPhase {
                            switch phase {
                            case .starting: Label("Starting the audio check…", systemImage: "clock")
                            case .recording(let remaining): Label("Recording check · \(remaining)s left", systemImage: "record.circle").foregroundStyle(.red)
                            case .stopping: Label("Stopping and discarding test audio…", systemImage: "clock")
                            }
                            Button("Cancel check", action: controller.cancelCaptureCheck)
                                .disabled(phase == .stopping).keyboardShortcut(.cancelAction)
                        } else {
                            Button("Start 10-second audio check", action: controller.startCaptureCheck)
                                .disabled(!controller.captureCheckAllowed || controller.recording || controller.startingRecording
                                          || !controller.microphoneGranted || !controller.systemAudioGranted)
                            if controller.recording || controller.startingRecording { Text("Finish your meeting recording before checking audio.").font(.caption) }
                            else if !controller.captureCheckAllowed { Text("Finishing startup recovery. The audio check will be available when it finishes.").font(.caption).foregroundStyle(.secondary) }
                            if let report = controller.captureCheckReport {
                                if report.cancelled { Text("Check cancelled. No meeting was created.") }
                                else if report.startFailed { Text("The check could not capture audio. Make sure Teams is open and both permissions are allowed, then try again.") }
                                ForEach(report.tracks, id: \.source) { track in
                                    Label(track.title + ": " + track.detail, systemImage: track.state == .sound ? "checkmark.circle" : "exclamationmark.circle")
                                }
                                if report.audioRemoved { Text("Test audio discarded.").font(.caption).foregroundStyle(.secondary) }
                                else {
                                    Text("Test audio could not be removed. Review the check folder; meeting recordings are untouched.").foregroundStyle(.orange)
                                    Button("Show test files") { controller.openDocument(report.directory) }
                                }
                            }
                            if let error = controller.captureCheckError { Text(error).foregroundStyle(.orange) }
                        }
                        Text("Sound received proves a short audio path works. It does not verify a whole meeting, speaker names or transcription accuracy.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                } label: { Label("4. Check your audio", systemImage: "mic") }
                HStack {
                    Button("Refresh checks", action: controller.refreshSetupChecks)
                    Spacer()
                    Button("Open recording controls", action: controller.openMenu).disabled(controller.captureCheckBusy)
                }
            }.padding(24)
        }.frame(width: 610, height: 700).background(Color(nsColor: .windowBackgroundColor))
    }
    private func row(_ title: String, ready: Bool, action: String, run: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? .green : .primary)
            Spacer()
            if !ready { Button(action, action: run).disabled(controller.captureCheckBusy) }
        }
    }
}
