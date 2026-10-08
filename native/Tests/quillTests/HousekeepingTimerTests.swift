import AppKit
import XCTest
@testable import quill

private final class TimerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func tick() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
final class HousekeepingTimerTests: XCTestCase {
    @MainActor func testCheckpointPolicyRunsDuringModalPanels() {
        let counter = TimerCounter()
        let timer = HousekeepingTimer.schedule(every: 0.01) { _ in counter.tick() }
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { _ = RunLoop.main.run(mode: .modalPanel, before: deadline) }
        XCTAssertGreaterThan(counter.value, 0, "Modal dialogs must not suspend recording health checks")
    }
}
