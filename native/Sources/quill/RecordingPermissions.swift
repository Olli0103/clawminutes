import AVFoundation
import Foundation

enum RecordingPermissionError: Error { case microphoneDenied }

enum RecordingPermissions {
    static func authorizeMicrophone(
        status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio),
        request: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    ) async throws {
        switch status {
        case .authorized: return
        case .notDetermined:
            guard await request() else { throw RecordingPermissionError.microphoneDenied }
        default: throw RecordingPermissionError.microphoneDenied
        }
    }
}
