import ComposePlanner
import Testing

@Suite("What a failed hook means for the plan")
struct HookOutcomeTests {
    static func hook(_ phase: HookOperation.Phase) -> HookOperation {
        HookOperation(
            service: "web",
            containerName: "shop-web",
            phase: phase,
            index: 1,
            command: ["./hook.sh"],
            failureIsFatal: phase == .postStart
        )
    }

    @Test("A pre_stop that fails carries on, however many steps follow it")
    func preStopCarriesOn() {
        #expect(Self.hook(.preStop).outcome(laterSteps: 2) == .carryOn)
        #expect(Self.hook(.preStop).outcome(laterSteps: 0) == .carryOn)
    }

    @Test("A post_start that fails stops the plan, counting the later steps and naming the container it leaves")
    func postStartStops() {
        #expect(Self.hook(.postStart).outcome(laterSteps: 3) == .stop(laterSteps: 3, containerLeftInPlace: "shop-web"))
        #expect(Self.hook(.postStart).outcome(laterSteps: 0) == .stop(laterSteps: 0, containerLeftInPlace: "shop-web"))
    }

    @Test("A failure keeps what happened and the hook it happened to")
    func failureFacts() {
        struct NotRunning: Error {}
        let hook = Self.hook(.postStart)
        let exited = HookFailure(hook: hook, reason: .exited(3), lastLines: ["config missing"])
        #expect(exited.hook == hook)
        #expect(exited.status == 3)
        #expect(exited.lastLines == ["config missing"])

        let unstarted = HookFailure(hook: hook, reason: .couldNotStart(NotRunning()))
        #expect(unstarted.status == nil)
        #expect(unstarted.lastLines.isEmpty)
        guard case .couldNotStart(let error) = unstarted.reason else {
            Issue.record("expected couldNotStart")
            return
        }
        #expect(error is NotRunning)
    }
}

@Suite("Keeping the end of a hook's output")
struct HookTranscriptTests {
    @Test("Only the chosen number of most recent lines are kept, oldest first")
    func keepsTheEnd() {
        let transcript = HookTranscript(keeping: 5)
        for n in 1...12 { transcript.append("line \(n)") }
        #expect(transcript.lastLines == (8...12).map { "line \($0)" })
    }

    @Test("Fewer lines than the limit are all kept")
    func keepsShortOutput() {
        let transcript = HookTranscript(keeping: 20)
        transcript.append("one")
        transcript.append("two")
        #expect(transcript.lastLines == ["one", "two"])
    }

    @Test("The latest line is the most recent one with something on it")
    func latestSkipsBlankLines() {
        let transcript = HookTranscript(keeping: 2)
        #expect(transcript.latest == nil)
        transcript.append("seeding")
        transcript.append("   ")
        transcript.append("")
        #expect(transcript.latest == "seeding")
        // Blank lines still count towards what is kept: they are part of the output.
        #expect(transcript.lastLines == ["   ", ""])
    }

    @Test("A limit below one still keeps the last line")
    func keepsAtLeastOne() {
        let transcript = HookTranscript(keeping: 0)
        transcript.append("a")
        transcript.append("b")
        #expect(transcript.lastLines == ["b"])
    }

    @Test("Lines appended from many tasks at once are all counted")
    func concurrentAppends() async {
        let transcript = HookTranscript(keeping: 1000)
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<200 { group.addTask { transcript.append("line \(n)") } }
        }
        #expect(transcript.lastLines.count == 200)
    }
}
