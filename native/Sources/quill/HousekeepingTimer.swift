import AppKit

/// Recording checkpoints, health checks and detection share the same scheduling policy.
@MainActor
enum HousekeepingTimer {
    static func schedule(every interval: TimeInterval, _ handler: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true, block: handler)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }
}
