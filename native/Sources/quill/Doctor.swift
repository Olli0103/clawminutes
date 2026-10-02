import AVFoundation
import CoreGraphics
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL, checkKeychain: Bool = true) -> [Check] {
        [
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(checkKeychain: checkKeychain),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for ocmh (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// The shipping ScreenCaptureKit path requires this permission even though
    /// the helper registers only audio output and saves no screen content.
    static func checkSystemAudio() -> Check {
        if CGPreflightScreenCaptureAccess() { return Check(name: "system audio", status: .ok, remediation: nil) }
        return Check(
            name: "system audio",
            status: .warn("Screen & System Audio Recording access required"),
            remediation: "enable ocmh in the upper Screen & System Audio Recording list in System Settings, then reopen ocmh"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the selected engine and model are available.
    static func checkTranscription(checkKeychain: Bool = true) -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        guard let kind = TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) else {
            return Check(name: "transcription", status: .fail("unknown engine: \(Config.transcriptionEngine())"),
                         remediation: "choose an engine from ocmh's Transcription engine menu")
        }
        if kind == .elevenLabs {
            guard checkKeychain else {
                return Check(name: "transcription", status: .warn("ElevenLabs key will be checked before transcription"), remediation: nil)
            }
            let saved = ElevenLabsKeychain.shared.containsKey()
            // Keep recording and the menu available while the user supplies a key.
            return Check(name: "transcription", status: saved ? .ok : .warn("ElevenLabs API key not saved"),
                         remediation: saved ? nil : "ocmh menu > ElevenLabs API key...; recordings are retained until transcription is available")
        }
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetEngine.modelVersion)
        if AsrModels.modelsExist(at: cache, version: ParakeetEngine.modelVersion) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("multilingual parakeet v3 models not downloaded"),
            remediation: "downloads automatically on first transcription; record a short test session while online"
        )
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
