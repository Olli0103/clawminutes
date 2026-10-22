import Foundation
import XCTest
@testable import quill

final class DraftSourceOwnershipTests: XCTestCase {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"status":"stopped","started":"2026-10-08T10:00:00Z","ended":"2026-10-08T10:01:00Z"}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        try Data(#"{"segments":[]}"#.utf8).write(to: dir.appendingPathComponent("transcript.json"))
        return dir
    }
    func testDraftOwnershipBlocksAnotherWriterDeliveryAndInstaller() throws {
        let dir = try fixture(), leasePath = dir.appendingPathComponent("lease")
        let owner = try DraftSourceOwnership.acquire(dir, activityLockPath: leasePath)
        XCTAssertThrowsError(try DraftSourceOwnership.acquire(dir, activityLockPath: leasePath))
        XCTAssertThrowsError(try ArchiveBacklog.reserve(ArchiveBacklog.inspect(dir), now: 100))
        XCTAssertNil(try AppRunLock.acquire(at: leasePath), "Installer requires an exclusive lifecycle lease")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path))
        try owner.validateUnchanged()
        withExtendedLifetime(owner) {}
    }
    func testExistingSaveOrProcessingLockPreventsDraftMutation() throws {
        for filename in ["archive.lock", ".postprocess.lock"] {
            let dir = try fixture()
            let lock = try XCTUnwrap(AppRunLock.acquire(at: dir.appendingPathComponent(filename)))
            XCTAssertThrowsError(try DraftSourceOwnership.acquire(dir, activityLockPath: dir.appendingPathComponent("lease")))
            withExtendedLifetime(lock) {}
        }
    }
    func testActiveCaptureAndLinkedReceiptAreProtected() throws {
        let dir = try fixture(), meta = dir.appendingPathComponent("meta.json")
        let stopped = try ArchiveBacklog.read(meta)
        try Data(#"{"status":"recording","started":"2026-10-08T10:00:00Z"}"#.utf8).write(to: meta)
        XCTAssertThrowsError(try DraftSourceOwnership.acquire(dir, activityLockPath: dir.appendingPathComponent("lease")))
        try stopped.write(to: meta)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("archive-receipt.json").path, withDestinationPath: dir.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try DraftSourceOwnership.acquire(dir, activityLockPath: dir.appendingPathComponent("lease"))) {
            XCTAssertEqual(($0 as? DeliveryFailure)?.code, "revision_conflict")
        }
    }
    func testSourceChangeOrLateReceiptInvalidatesWrite() throws {
        for file in ["participants.json", "archive-receipt.json"] {
            let dir = try fixture()
            let owner = try DraftSourceOwnership.acquire(dir, activityLockPath: dir.appendingPathComponent("lease"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent(file))
            XCTAssertThrowsError(try owner.validateUnchanged())
        }
    }
    func testSavedSourceCanBeReadForPreviewButStillCannotChangeUnderIt() throws {
        let dir = try fixture()
        try Data("{}".utf8).write(to: dir.appendingPathComponent("archive-receipt.json"))
        let owner = try DraftSourceOwnership.acquire(dir, editing: false, activityLockPath: dir.appendingPathComponent("lease"))
        try owner.validateUnchanged()
        try Data("Changed".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        XCTAssertThrowsError(try owner.validateUnchanged())
    }
}
