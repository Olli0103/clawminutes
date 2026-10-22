import SwiftUI

struct StatusHeadline: View {
    let state: AppState
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.headline.symbol).font(.title3)
                .foregroundStyle(state.recording ? Color.red : state.headline == .attention ? .orange : CMTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.headline.rawValue).font(.headline)
                if state.recording { Text(state.callTitle).font(.callout).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }
}

struct RecordingBar: View {
    let state: AppState
    var toggle: () -> Void
    var levels: () -> (Float, Float) = { (0, 0) }
    var enableMeters: (Bool) -> Void = { _ in }
    @Namespace private var recordingControl
    @Environment(\.accessibilityReduceMotion) private var systemStill
    @Environment(\.cmPreviewReduceMotion) private var previewStill
    private var still: Bool { systemStill || previewStill }
    var body: some View {
        CMGlassContainer {
            Group {
                if state.recording {
                    HStack(spacing: 12) {
                        Button(action: toggle) { Label("Stop", systemImage: "stop.fill") }
                            .helperButton(prominent: true, recording: true).tint(.red).keyboardShortcut("r")
                            .help("Stop recording (⌘R)").accessibilityLabel("Stop recording")
                        Text(state.elapsed).monospacedDigit().font(.headline)
                        Spacer(minLength: 4)
                        meter("Mic", value: state.micLevel, lost: state.micLost)
                        meter("Teams", value: state.teamsLevel, lost: false)
                    }.padding(10).cmGlass("recording-control", in: recordingControl)
                } else {
                    Button(action: toggle) {
                        Label(state.primaryTitle, systemImage: state.captureCheckPhase == nil ? "mic.fill" : "stop.fill")
                            .fontWeight(.semibold).lineLimit(2).frame(maxWidth: .infinity, minHeight: 24)
                    }.cmButton(prominent: true).tint(CMTheme.accent).controlSize(.large)
                        .keyboardShortcut("r").help("Record this meeting (⌘R)")
                        .disabled(state.startingRecording)
                        .modifier(CMRecordingIdentity(namespace: recordingControl))
                }
            }.animation(still ? nil : .easeInOut(duration: 0.2), value: state.recording)
        }
        .task(id: state.popoverVisible && state.recording) {
            guard state.popoverVisible && state.recording else { enableMeters(false); return }
            enableMeters(true)
            defer { enableMeters(false) }
            while !Task.isCancelled {
                let values = levels()
                state.micLevel = values.0; state.teamsLevel = values.1
                do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
            }
        }
        .onDisappear { enableMeters(false) }
    }
    private func meter(_ title: String, value: Float, lost: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lost ? "Mic lost" : title).font(.caption2)
            ProgressView(value: Double(lost ? 0 : value), total: 1).cmProgress()
                .tint(lost ? .orange : CMTheme.accent).frame(width: 48)
                .accessibilityLabel("\(title) audio level")
                .accessibilityValue(lost ? "Unavailable" : "\(Int(value * 100)) percent")
        }
    }
}

struct PipelineSteps: View {
    let stage: MeetingPipelineState.Stage
    var verifiedCompletion: Int? = nil
    private var completed: Int {
        if let verifiedCompletion { return min(4, max(0, verifiedCompletion)) }
        return switch stage {
        case .capturing: 0
        case .recorded, .interrupted, .waitingForModel, .transcribing: 1
        case .transcribed, .delivering: 2
        case .needsAttention: 0
        case .delivered: 3
        case .exported, .audioRemoved: 4
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(["Recorded", "Transcribed", "Notes", "Saved"].enumerated()), id: \.offset) { index, title in
                Label { Text(title).foregroundStyle(.primary) } icon: {
                    Image(systemName: index < completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(index < completed ? .green : .primary)
                }.font(.caption)
                    .labelStyle(.titleAndIcon).accessibilityValue(index < completed ? "Complete" : "Pending")
            }
        }.accessibilityElement(children: .combine)
    }
}

struct MeetingRow: View {
    let meeting: RecentMeeting
    var rename: ((String) async -> Bool)? = nil
    @State private var renaming = false
    @State private var draft = ""
    @State private var renameFailed = false
    private var cause: String {
        meeting.presentationNeedsAttention
            ? (AttentionCause.forMeeting(meeting) == .other ? meeting.guidance.title : AttentionCause.forMeeting(meeting).title)
            : meeting.statusTitle
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: meeting.presentationNeedsAttention ? "exclamationmark.circle" : meeting.symbol)
                .foregroundStyle(meeting.presentationNeedsAttention ? Color.orange : meeting.ready ? .green : CMTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if renaming {
                    TextField("Meeting title", text: $draft).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Meeting title").help("Press Return to save the title")
                        .onSubmit {
                            Task {
                                if await rename?(draft) == true { renaming = false; renameFailed = false }
                                else { renameFailed = true }
                            }
                        }
                    if renameFailed { Text("Could not save title. Try again after this meeting finishes.").font(.caption) }
                } else { Text(meeting.title).font(.body.weight(.medium)).lineLimit(1) }
                Text(MeetingDate.string(meeting.started) + " · " + cause)
                    .font(.caption).lineLimit(1).help(cause)
            }.foregroundStyle(.primary)
            Spacer(minLength: 4)
        }.padding(.vertical, 5).accessibilityElement(children: renaming ? .contain : .combine)
            .contextMenu {
                if rename != nil {
                    Button("Rename") { draft = meeting.title; renaming = true }
                        .disabled(meeting.stage == .capturing || meeting.stage == .delivering)
                }
            }
    }
}

struct StoragePill: View {
    let bytes: Int64?
    let free: Int64?
    var capacity: Int64? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " of audio" } ?? "Storage not checked", systemImage: "externaldrive")
                .font(.callout)
            if let free, let capacity, capacity > 0 {
                ProgressView(value: Double(capacity - free), total: Double(capacity)).tint(CMTheme.accent)
                Text(ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free").font(.caption)
            }
        }
    }
}
