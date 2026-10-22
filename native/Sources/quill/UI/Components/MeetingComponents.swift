import SwiftUI

struct StatusHeadline: View {
    let state: AppState
    private var title: String {
        if state.headline == .attention {
            let count = state.attentionMeetings.count
            return count > 0 ? "\(count) \(count == 1 ? "meeting needs" : "meetings need") attention" : "Meeting needs attention"
        }
        return state.headline == .callDetected ? "Teams call" : state.headline.rawValue
    }
    private var subtitle: String? {
        if state.recording { return state.callTitle }
        if state.headline == .callDetected { return state.callDetectedAt.map { "Detected at " + MeetingDate.time($0) } }
        if state.headline == .processing || state.headline == .sending {
            return state.recentMeetings.first(where: { [.recorded, .transcribing, .transcribed, .delivering, .delivered].contains($0.stage) })?.title
        }
        return nil
    }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: state.headline.symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(state.recording ? Color.red : state.headline == .attention ? .orange : CMTheme.accent)
                .frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(CMTheme.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if state.recording {
                Text(state.elapsed).monospacedDigit().font(.title3.weight(.semibold))
                    .contentTransition(.numericText()).accessibilityLabel("Recording time " + state.elapsed)
            }
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
    private var prominent: Bool { state.recording || (state.headline != .processing && state.headline != .sending) || state.captureCheckPhase != nil }
    var body: some View {
        CMGlassContainer {
          VStack(spacing: 10) {
            if state.recording {
                HStack(spacing: 18) {
                    meter("Mic", value: state.micLevel, lost: state.micLost)
                    meter("Teams", value: state.teamsLevel, lost: false)
                }
            }
            Button(role: state.recording ? .destructive : nil, action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: state.recording || state.captureCheckPhase != nil ? "stop.fill" : "mic.fill")
                    Text(state.primaryTitle).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("⌘R").font(.caption).opacity(0.75)
                }.frame(maxWidth: .infinity)
            }.cmButton(prominent: prominent).tint(state.recording ? .red : CMTheme.accent).controlSize(.large)
                .modifier(CMRecordingIdentity(namespace: recordingControl))
                .keyboardShortcut("r").help(state.primaryTitle + " (⌘R)")
                .disabled(state.startingRecording)
          }
        }
        .animation(still ? nil : .easeInOut(duration: 0.2), value: state.recording)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(lost ? "Mic unavailable" : title).font(.caption).foregroundStyle(CMTheme.secondary)
            ProgressView(value: Double(lost ? 0 : value), total: 1).cmProgress()
                .tint(lost ? .orange : CMTheme.accent)
                .accessibilityLabel("\(title) audio level")
                .accessibilityValue(lost ? "Unavailable" : "\(Int(value * 100)) percent")
        }.frame(maxWidth: .infinity)
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
    @Environment(\.cmReferenceDate) private var referenceDate
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
                Text(MeetingDate.string(meeting.started, now: referenceDate ?? Date()) + " · " + cause)
                    .font(.caption).foregroundStyle(CMTheme.secondary).lineLimit(1).help(cause)
            }.foregroundStyle(.primary)
            Spacer(minLength: 4)
            if meeting.presentationNeedsAttention {
                Circle().fill(.orange).frame(width: 6, height: 6).accessibilityHidden(true)
            } else {
                Image(systemName: meeting.symbol).font(.caption)
                    .foregroundStyle(meeting.ready ? .green : CMTheme.accent).accessibilityHidden(true)
            }
        }.padding(.vertical, 3).accessibilityElement(children: renaming ? .contain : .combine)
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
