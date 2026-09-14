import ComposeModel
import ComposePlanner
import Foundation

/// How a plan is shown before, or instead of, being carried out.
enum Report {
    static func header(_ project: LoadedProject) {
        let services = project.file.services.count
        Output.line(
            "\(Output.bold(project.identity.name))  "
                + Output.dim("\(project.path), \(services) service\(services == 1 ? "" : "s")")
        )
    }

    /// One line per service, saying what will happen to it and why. This is the part worth
    /// reading: the operations below it are only the consequence.
    static func decisions(_ plan: Plan) {
        guard !plan.decisions.isEmpty else { return }
        let width = plan.decisions.map(\.service.count).max() ?? 0
        let actionWidth = plan.decisions.map(\.action.rawValue.count).max() ?? 0
        for decision in plan.decisions {
            Output.line(
                "  \(decision.service.rightPadded(to: width))  "
                    + "\(decision.action.rawValue.rightPadded(to: actionWidth))  "
                    + Output.dim(decision.reason)
            )
        }
    }

    static func dryRun(_ plan: Plan) {
        Output.line()
        Output.line(Output.bold("plan"))
        for operation in plan.operations {
            Output.line("  \(operation.summary)")
        }
        Output.line()
        Output.note("nothing was changed: this was a dry run")
    }
}
