import Foundation
import XCTest
@testable import quill

final class TeamsScannerIsolationTests: XCTestCase, @unchecked Sendable {
    private final class PermissionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func denied() -> Bool { lock.withLock { calls += 1 }; return false }
        var count: Int { lock.withLock { calls } }
    }
    private func app(_ bundle: String?, service: String? = "Microsoft Teams") -> MeetingApp {
        MeetingApp(pid: 42, name: "Synthetic Teams meeting", service: service, processStartedAt: 100, bundleIdentifier: bundle)
    }
    func testOnlyDesktopTeamsBundleAndServiceAreAdmitted() {
        for bundle in ["com.microsoft.teams", "com.microsoft.teams2", "COM.MICROSOFT.TEAMS2"] { XCTAssertTrue(app(bundle).isSupported) }
        for bundle in [nil, "com.microsoft.teams2.helper", "com.example.teams", "us.zoom.xos", "com.tinyspeck.slackmacgap", "com.google.Chrome"] {
            XCTAssertFalse(app(bundle).isSupported)
        }
        XCTAssertFalse(app("com.microsoft.teams2", service: "Zoom").isSupported)
        XCTAssertFalse(app("com.microsoft.teams2", service: nil).isSupported)
    }
    func testRejectedInputsNeverReachPermissionOrAccessibility() async {
        let probe = PermissionProbe(), scanner = MeetingScanner(permissionGranted: { probe.denied() })
        let result = await scanner.scan(apps: [app("us.zoom.xos"), app("com.google.Chrome", service: nil), app(nil)], captureSpeakers: true, inspectBoxes: true)
        XCTAssertEqual(probe.count, 0); XCTAssertFalse(result.needsPermission)
        XCTAssertTrue(result.observations.isEmpty); XCTAssertTrue(result.rosters.isEmpty); XCTAssertTrue(result.speakers.isEmpty)
        let unknownSpeaker = await scanner.speakerActivity(for: "unregistered")
        XCTAssertNil(unknownSpeaker); XCTAssertEqual(probe.count, 0)
        let teams = await scanner.scan(apps: [app("com.microsoft.teams2")])
        XCTAssertTrue(teams.needsPermission); XCTAssertEqual(probe.count, 1)
        XCTAssertTrue(teams.observations.isEmpty, "Denied permission cannot establish a call or capture")
    }
    func testTeamsRosterHasNoForeignTileOrVoiceNameFallback() {
        let nodes = [SpeakerUINode(parent: nil, role: "AXGroup", text: "", classes: ["vdi-occlusion"]),
            SpeakerUINode(parent: 0, role: "AXStaticText", text: "Fixture Alice", classes: []),
            SpeakerUINode(parent: nil, role: "AXGroup", text: "", classes: ["OFfHfd"]),
            SpeakerUINode(parent: 2, role: "AXStaticText", text: "Foreign tile", classes: [])]
        let members = TeamsTileEvidence.members(nodes, localName: "Fixture Alice")
        XCTAssertEqual(members.map(\.name), ["Fixture Alice"]); XCTAssertEqual(members.map(\.is_local), [true])
        XCTAssertTrue(TeamsTileEvidence.tiles(nodes).isEmpty, "Roster membership alone cannot establish a speaking frame")
    }
}
