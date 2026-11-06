import Foundation

// The rules for a `post_start` or `pre_stop` hook that went wrong, shared by every front end
// that carries a plan out: the plugin and Orchard. What the rules decide lives here; how a
// failure reads is each front end's own, since a terminal and a window word things differently.

/// What a hook that went wrong means for the rest of the plan.
public enum HookOutcome: Sendable, Equatable {
    /// Report the failure and go on to the next step.
    case carryOn
    /// Stop the plan here. `laterSteps` steps after the hook are not attempted, and the
    /// container the hook ran in, named by `containerLeftInPlace`, is kept as it is: nothing is
    /// rolled back.
    case stop(laterSteps: Int, containerLeftInPlace: String)
}

extension HookOperation {
    /// What this hook failing means for the plan, whether it exited non-zero or never got
    /// going: the plan decided up front, through `failureIsFatal`.
    ///
    /// A failed `pre_stop` carries on, since the container is being stopped either way. A
    /// failed `post_start` stops the plan and leaves its container, whose hash has not
    /// changed, so another `up` keeps it and does not run the hook again.
    ///
    /// - Parameter laterSteps: how many steps in the plan come after this one.
    public func outcome(laterSteps: Int) -> HookOutcome {
        guard failureIsFatal else { return .carryOn }
        return .stop(laterSteps: max(laterSteps, 0), containerLeftInPlace: containerName)
    }
}

/// A hook that failed: what happened, with none of the wording. Whether it stops the plan is
/// `hook.outcome(laterSteps:)`; the hook's phase, index, service and container are on `hook`.
public struct HookFailure: Error, Sendable {
    public enum Reason: Sendable {
        /// The hook ran and exited with this non-zero status.
        case exited(Int32)
        /// The hook never ran: the container was not running, it had no command, or the
        /// runtime would not start it.
        case couldNotStart(any Error)
    }

    public let hook: HookOperation
    public let reason: Reason
    /// The end of the hook's output, oldest first. Empty when it printed nothing or never ran.
    public let lastLines: [String]

    public init(hook: HookOperation, reason: Reason, lastLines: [String] = []) {
        self.hook = hook
        self.reason = reason
        self.lastLines = lastLines
    }

    /// The exit status, when the hook ran.
    public var status: Int32? {
        if case .exited(let status) = reason { return status }
        return nil
    }
}

/// Keeps the end of a hook's output for a failure message, and the latest line worth showing
/// while it runs. Safe to append to from the threads that read the hook's output streams.
///
/// How many lines are kept is the caller's: a terminal has room for more than a progress row.
public final class HookTranscript: @unchecked Sendable {
    private let kept: Int
    private let lock = NSLock()
    private var lines: [String] = []
    private var mostRecent: String?

    /// - Parameter keeping: how many of the most recent lines to keep. At least one is kept.
    public init(keeping: Int) {
        kept = max(keeping, 1)
    }

    /// Adds a line, dropping the oldest once more than `keeping` are held.
    public func append(_ line: String) {
        lock.withLock {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { mostRecent = line }
            lines.append(line)
            if lines.count > kept { lines.removeFirst(lines.count - kept) }
        }
    }

    /// The most recent lines, oldest first.
    public var lastLines: [String] {
        lock.withLock { lines }
    }

    /// The most recent line with something on it, or `nil` before there is one.
    public var latest: String? {
        lock.withLock { mostRecent }
    }
}
