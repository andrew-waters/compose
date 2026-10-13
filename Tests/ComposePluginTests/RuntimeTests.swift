import ComposePlanner
import Foundation
import Testing

@testable import compose

@Suite("What a failed hook means for the plan")
struct HookOutcomeTests {
    static func hook(_ phase: HookOperation.Phase) -> HookOperation {
        HookOperation(
            service: "web",
            containerName: "shop-web",
            phase: phase,
            index: 0,
            command: ["./hook.sh"],
            failureIsFatal: phase == .postStart
        )
    }

    @Test("A pre_stop that exits non-zero is a warning, with its exit code and output")
    func preStopExitCarriesOn() {
        let hook = Self.hook(.preStop)
        let failure = HookFailure(hook: hook, status: 3, lastLines: ["checking", "config missing"])
        #expect(Runtime.outcome(of: hook, failingWith: failure, later: 2) == .carryOn(
            warning: """
                pre_stop[0] in service `web` exited 3
                  its last output was:
                    checking
                    config missing
                  carrying on with the stop
                """
        ))
    }

    @Test("A pre_stop that cannot start at all is a warning too, not the end of down")
    func preStopLaunchFailureCarriesOn() {
        let outcome = Runtime.outcome(
            of: Self.hook(.preStop),
            failingWith: ComposeError("`shop-web` is not running"),
            later: 2
        )
        #expect(outcome == .carryOn(
            warning: "pre_stop[0] in service `web` could not run: `shop-web` is not running\n"
                + "  carrying on with the stop"
        ))
    }

    @Test("A post_start that exits non-zero stops the plan and says how to run it again")
    func postStartExitStops() {
        let hook = Self.hook(.postStart)
        let failure = HookFailure(hook: hook, status: 1, lastLines: [])
        #expect(Runtime.outcome(of: hook, failingWith: failure, later: 2) == .stop(
            message: """
                post_start[0] in service `web` exited 1
                  `shop-web` was left in place; 2 later step(s) were not attempted
                  `up` keeps a running container, so it will not run this hook again; run `down` and then `up` once it is fixed
                """
        ))
    }

    @Test("A post_start that cannot start stops the plan, and a last step has no later steps to mention")
    func postStartLaunchFailureStops() {
        let outcome = Runtime.outcome(
            of: Self.hook(.postStart),
            failingWith: ComposeError("`shop-web` is not running"),
            later: 0
        )
        #expect(outcome == .stop(
            message: "post_start[0] in service `web` could not run: `shop-web` is not running\n"
                + "  `shop-web` was left in place\n"
                + "  `up` keeps a running container, so it will not run this hook again; "
                + "run `down` and then `up` once it is fixed"
        ))
    }
}

@Suite("Reading runtime errors")
struct FriendlyErrorTests {
    @Test("An error from inside the guest is cut down to the message that says what went wrong")
    func nestedCause() {
        // As `container` 1.5.0 reported a hook whose executable does not exist.
        let text = #"failed to start process 049d5007 in container hookfail-web (cause: "internalError: "failed to start process (cause: "internalError: "startProcess: failed to start process: internalError: "vmexec error: internalError: "failed to find target executable /no/such/script"""")"")"#
        #expect(Runtime.innermostCause(of: text) == "failed to find target executable /no/such/script")
    }

    @Test("A message with nothing wrapped round it is left alone")
    func plainMessage() {
        #expect(Runtime.innermostCause(of: "`shop-web` is not running") == "`shop-web` is not running")
        #expect(Runtime.innermostCause(of: #"bad value: "x""#) == #"bad value: "x""#)
    }
}

@Suite("Relaying hook output")
struct HookTranscriptTests {
    @Test("Every line is relayed, and only the last twenty are kept for an error")
    func keepsTheEnd() async throws {
        let pipe = Pipe()
        let transcript = HookTranscript()
        let text = (1...25).map { "line \($0)\n" }.joined()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        await transcript.relay(pipe.fileHandleForReading)
        await transcript.drain(streams: 1, within: .seconds(1))
        #expect(transcript.lastLines == (6...25).map { "line \($0)" })
    }

    @Test("A stream something else holds open does not hold up the hook past the deadline")
    func drainHasADeadline() async throws {
        let pipe = Pipe()
        let transcript = HookTranscript()
        Task { await transcript.relay(pipe.fileHandleForReading) }
        try pipe.fileHandleForWriting.write(contentsOf: Data("before\n".utf8))

        let clock = ContinuousClock()
        let started = clock.now
        await transcript.drain(streams: 1, within: .milliseconds(300))
        #expect(clock.now - started < .seconds(2))

        // Output after the deadline belongs to whatever the hook left running, not the hook.
        try pipe.fileHandleForWriting.write(contentsOf: Data("after\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(transcript.lastLines == ["before"])
        try pipe.fileHandleForWriting.close()
    }
}
