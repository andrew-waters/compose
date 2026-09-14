import ComposeModel

/// Something about the file, or about what already exists, that stops a plan being made.
///
/// Every one of these is raised before a single operation is emitted. A plan is all or nothing:
/// half a project is worse than none of it, and a port conflict found on the fourth service is
/// still a reason not to have created the first three.
public enum PlanError: Error, Sendable, Equatable, CustomStringConvertible {
    case dependencyCycle([String])
    case portConflict(port: UInt16, service: String, heldBy: String)
    case duplicateContainerName(name: String, services: [String])
    case missingExternalNetwork(name: String, service: String)

    public var description: String {
        switch self {
        case .dependencyCycle(let path):
            return "`depends_on` is circular: \(path.joined(separator: " -> "))"
        case .portConflict(let port, let service, let heldBy):
            return "service `\(service)` publishes host port \(port), which \(heldBy) already uses"
        case .duplicateContainerName(let name, let services):
            return "services \(services.map { "`\($0)`" }.joined(separator: " and ")) both want the container name `\(name)`"
        case .missingExternalNetwork(let name, let service):
            return "service `\(service)` attaches to external network `\(name)`, which does not exist"
        }
    }
}

/// What a second `up` decided about one service.
public enum ServiceAction: String, Sendable, Equatable {
    /// Nothing exists yet.
    case create
    /// The container exists and matches; it is only stopped.
    case start
    /// The container exists, matches, and is running.
    case unchanged
    /// The container exists and no longer matches the file.
    case recreate
    /// The container carries the project label and the file no longer has the service.
    case remove
}

public struct ServiceDecision: Sendable, Equatable {
    public let service: String
    public let containerName: String
    public let action: ServiceAction
    /// Why, in a few words, because "recreate" on its own is the question rather than the
    /// answer.
    public let reason: String

    public init(service: String, containerName: String, action: ServiceAction, reason: String) {
        self.service = service
        self.containerName = containerName
        self.action = action
        self.reason = reason
    }
}

/// An ordered list of operations, and the reasoning that produced it.
public struct Plan: Sendable, Equatable {
    public let project: ProjectIdentity
    public let operations: [Operation]
    public let decisions: [ServiceDecision]

    public init(project: ProjectIdentity, operations: [Operation], decisions: [ServiceDecision]) {
        self.project = project
        self.operations = operations
        self.decisions = decisions
    }

    public var isEmpty: Bool { operations.isEmpty }

    /// One line per operation, in order, which is what `--dry-run` prints.
    public var summary: String {
        operations.map(\.summary).joined(separator: "\n")
    }
}

public struct UpOptions: Sendable {
    public enum PullPolicy: String, Sendable {
        /// Pull only what is not here already.
        case missing
        /// Pull every time, for a moving tag.
        case always
        /// Never pull; fail at execution if an image is absent.
        case never
    }

    public var pullPolicy: PullPolicy
    /// Recreate every container whether or not its hash changed.
    public var forceRecreate: Bool
    /// Remove containers carrying the project label whose service has left the file.
    public var removeOrphans: Bool

    public init(pullPolicy: PullPolicy = .missing, forceRecreate: Bool = false, removeOrphans: Bool = true) {
        self.pullPolicy = pullPolicy
        self.forceRecreate = forceRecreate
        self.removeOrphans = removeOrphans
    }
}

public struct DownOptions: Sendable {
    /// Remove networks this project created, once nothing outside the project is on them.
    public var removeNetworks: Bool

    public init(removeNetworks: Bool = true) {
        self.removeNetworks = removeNetworks
    }
}

/// A compose file plus a snapshot of what exists, in; an ordered list of operations, out.
///
/// Nothing here executes, reads the disk, or talks to a daemon, which is the entire point: the
/// two decisions compose implementations get wrong, what order to do things in and what to do
/// about what is already there, are both decided by a pure function.
public enum Planner {
    public static func up(
        file: ComposeFile,
        project: ProjectIdentity,
        state: CurrentState,
        options: UpOptions = UpOptions()
    ) throws -> Plan {
        let graph = try DependencyGraph(services: file.services)
        let order = graph.startOrder
        let containerNames = try containerNames(for: file, project: project, order: order)
        let networks = try networkAssignments(for: file, project: project, order: order, state: state)

        var existingByService: [String: ContainerState] = [:]
        var orphans: [ContainerState] = []
        for container in state.containers where container.projectName == project.name {
            guard let service = container.serviceName else { continue }
            if file.services[service] == nil {
                orphans.append(container)
            } else {
                existingByService[service] = container
            }
        }
        orphans.sort { $0.name < $1.name }

        // Decide first, emit second. Nothing below can change its mind once an operation has
        // been written down.
        var actions: [String: ServiceAction] = [:]
        var decisions: [ServiceDecision] = []
        for name in order {
            guard let service = file.services[name], let containerName = containerNames[name] else { continue }
            let decision = decide(
                service: service,
                containerName: containerName,
                existing: existingByService[name],
                forceRecreate: options.forceRecreate
            )
            actions[name] = decision.action
            decisions.append(decision)
        }
        if options.removeOrphans {
            for orphan in orphans {
                decisions.append(
                    ServiceDecision(
                        service: orphan.serviceName ?? orphan.name,
                        containerName: orphan.name,
                        action: .remove,
                        reason: "the file no longer declares this service"
                    )
                )
            }
        }

        var releasedContainers = Set(
            order.compactMap { actions[$0] == .recreate ? existingByService[$0]?.name : nil }
        )
        if options.removeOrphans {
            releasedContainers.formUnion(orphans.map(\.name))
        }
        try checkPorts(
            file: file,
            order: order,
            containerNames: containerNames,
            state: state,
            releasedContainers: releasedContainers
        )

        var operations: [Operation] = []

        // Orphans go first: they hold names and host ports that the rest of the plan may want
        // back.
        if options.removeOrphans {
            for orphan in orphans {
                let reference = ContainerReference(containerName: orphan.name, service: orphan.serviceName)
                if orphan.isRunning { operations.append(.stopContainer(reference)) }
                operations.append(.removeContainer(reference))
            }
        }

        let existingNetworks = Set(state.networks.map(\.name))
        var created: Set<String> = []
        for name in order {
            guard let assignment = networks[name], !assignment.isExternal else { continue }
            guard !existingNetworks.contains(assignment.name), !created.contains(assignment.name) else { continue }
            created.insert(assignment.name)
            operations.append(
                .createNetwork(NetworkOperation(name: assignment.name, labels: project.networkLabels()))
            )
        }

        for name in order {
            guard let service = file.services[name],
                  let containerName = containerNames[name],
                  let action = actions[name],
                  let assignment = networks[name]
            else { continue }
            let reference = ContainerReference(containerName: containerName, service: name)
            switch action {
            case .unchanged, .remove:
                continue
            case .start:
                operations.append(.startContainer(reference))
            case .create, .recreate:
                let image = imageReference(for: service, project: project)
                if let build = service.build {
                    operations.append(
                        .buildImage(
                            BuildOperation(
                                service: name,
                                imageReference: image,
                                context: build.context,
                                dockerfile: build.dockerfile,
                                arguments: build.args,
                                target: build.target
                            )
                        )
                    )
                } else if shouldPull(image, state: state, policy: options.pullPolicy) {
                    operations.append(.pullImage(PullOperation(service: name, imageReference: image)))
                }
                if action == .recreate, let existing = existingByService[name] {
                    let old = ContainerReference(containerName: existing.name, service: name)
                    if existing.isRunning { operations.append(.stopContainer(old)) }
                    operations.append(.removeContainer(old))
                }
                operations.append(
                    .createContainer(
                        createOperation(
                            service: service,
                            containerName: containerName,
                            imageReference: image,
                            networkName: assignment.name,
                            project: project
                        )
                    )
                )
                operations.append(.startContainer(reference))
            }
        }

        return Plan(project: project, operations: operations, decisions: decisions)
    }

    /// Stop and remove everything carrying the project label, then the networks the project
    /// created, in the reverse of the order `up` started things in.
    ///
    /// Volumes are left alone. Nothing here creates a named volume yet, so there is nothing to
    /// remove; when there is, removing one will need an explicit flag, which is the one piece
    /// of compose behaviour worth copying exactly.
    public static func down(
        file: ComposeFile,
        project: ProjectIdentity,
        state: CurrentState,
        options: DownOptions = DownOptions()
    ) throws -> Plan {
        let graph = try DependencyGraph(services: file.services)
        let projectContainers = state.containers.filter { $0.projectName == project.name }

        var ordered: [ContainerState] = []
        for name in graph.stopOrder {
            if let container = projectContainers.first(where: { $0.serviceName == name }) {
                ordered.append(container)
            }
        }
        // Containers that carry the label and no longer have a service go last, after the ones
        // that might still depend on them.
        let placed = Set(ordered.map(\.name))
        ordered.append(contentsOf: projectContainers.filter { !placed.contains($0.name) }.sorted { $0.name < $1.name })

        var operations: [Operation] = []
        var decisions: [ServiceDecision] = []
        for container in ordered {
            let reference = ContainerReference(containerName: container.name, service: container.serviceName)
            if container.isRunning { operations.append(.stopContainer(reference)) }
            operations.append(.removeContainer(reference))
            decisions.append(
                ServiceDecision(
                    service: container.serviceName ?? container.name,
                    containerName: container.name,
                    action: .remove,
                    reason: container.isRunning ? "running" : "stopped"
                )
            )
        }

        if options.removeNetworks {
            let removed = Set(ordered.map(\.name))
            for network in state.networks.sorted(by: { $0.name < $1.name }) where network.projectName == project.name {
                let stillUsed = state.containers.contains {
                    $0.networkName == network.name && !removed.contains($0.name)
                }
                guard !stillUsed else { continue }
                operations.append(.removeNetwork(NetworkOperation(name: network.name, labels: network.labels)))
            }
        }

        return Plan(project: project, operations: operations, decisions: decisions)
    }

    // MARK: - Decisions

    private static func decide(
        service: Service,
        containerName: String,
        existing: ContainerState?,
        forceRecreate: Bool
    ) -> ServiceDecision {
        let hash = ProjectIdentity.hash(of: service)
        guard let existing else {
            return ServiceDecision(
                service: service.name,
                containerName: containerName,
                action: .create,
                reason: "no container exists"
            )
        }
        if forceRecreate {
            return ServiceDecision(
                service: service.name,
                containerName: containerName,
                action: .recreate,
                reason: "recreation was asked for"
            )
        }
        guard existing.serviceHash == hash else {
            return ServiceDecision(
                service: service.name,
                containerName: containerName,
                action: .recreate,
                reason: "the service changed since the container was created"
            )
        }
        if existing.isRunning {
            return ServiceDecision(
                service: service.name,
                containerName: containerName,
                action: .unchanged,
                reason: "running and unchanged"
            )
        }
        return ServiceDecision(
            service: service.name,
            containerName: containerName,
            action: .start,
            reason: "unchanged and stopped"
        )
    }

    // MARK: - Names, networks, ports

    private static func containerNames(
        for file: ComposeFile,
        project: ProjectIdentity,
        order: [String]
    ) throws -> [String: String] {
        var names: [String: String] = [:]
        var owners: [String: String] = [:]
        for name in order {
            guard let service = file.services[name] else { continue }
            let containerName = project.containerName(for: service)
            if let owner = owners[containerName] {
                throw PlanError.duplicateContainerName(name: containerName, services: [owner, name].sorted())
            }
            owners[containerName] = name
            names[name] = containerName
        }
        return names
    }

    private struct NetworkAssignment {
        let name: String
        let isExternal: Bool
    }

    /// One network per service, because a container joins one. A service that names several was
    /// told at parse time that only the first is used.
    private static func networkAssignments(
        for file: ComposeFile,
        project: ProjectIdentity,
        order: [String],
        state: CurrentState
    ) throws -> [String: NetworkAssignment] {
        var assignments: [String: NetworkAssignment] = [:]
        for name in order {
            guard let service = file.services[name] else { continue }
            guard let key = service.networks.first, let spec = file.networks[key] else {
                assignments[name] = NetworkAssignment(name: project.defaultNetworkName, isExternal: false)
                continue
            }
            let resolved = spec.resolvedName(projectName: project.name)
            if spec.isExternal, !state.networks.contains(where: { $0.name == resolved }) {
                throw PlanError.missingExternalNetwork(name: resolved, service: name)
            }
            assignments[name] = NetworkAssignment(name: resolved, isExternal: spec.isExternal)
        }
        return assignments
    }

    /// Every published port, checked against every other service and against everything already
    /// running, before an operation exists to conflict with.
    private static func checkPorts(
        file: ComposeFile,
        order: [String],
        containerNames: [String: String],
        state: CurrentState,
        releasedContainers: Set<String>
    ) throws {
        var wantedBy: [UInt16: String] = [:]
        for name in order {
            guard let service = file.services[name] else { continue }
            for port in service.ports {
                guard let hostPort = port.hostPort else { continue }
                if let other = wantedBy[hostPort], other != name {
                    throw PlanError.portConflict(port: hostPort, service: name, heldBy: "service `\(other)`")
                }
                wantedBy[hostPort] = name
            }
        }
        for container in state.containers where !releasedContainers.contains(container.name) {
            for port in container.publishedHostPorts.sorted() {
                guard let wanting = wantedBy[port] else { continue }
                guard containerNames[wanting] != container.name else { continue }
                throw PlanError.portConflict(port: port, service: wanting, heldBy: "container `\(container.name)`")
            }
        }
    }

    // MARK: - Images

    /// The image a service runs. A service that only builds gets a tag named after the project,
    /// the way compose names images it builds.
    public static func imageReference(for service: Service, project: ProjectIdentity) -> String {
        if let image = service.image { return image }
        return "\(project.name)-\(service.name):latest"
    }

    /// `nginx` and `nginx:latest` are the same image, and a registry host with a port is not a
    /// tag.
    public static func normalisedImageReference(_ reference: String) -> String {
        guard let lastSlash = reference.lastIndex(of: "/") else {
            return reference.contains(":") || reference.contains("@") ? reference : "\(reference):latest"
        }
        let component = reference[reference.index(after: lastSlash)...]
        return component.contains(":") || component.contains("@") ? reference : "\(reference):latest"
    }

    private static func shouldPull(_ image: String, state: CurrentState, policy: UpOptions.PullPolicy) -> Bool {
        switch policy {
        case .never:
            return false
        case .always:
            return true
        case .missing:
            let wanted = normalisedImageReference(image)
            return !state.images.contains { normalisedImageReference($0) == wanted }
        }
    }

    // MARK: - Create

    private static func createOperation(
        service: Service,
        containerName: String,
        imageReference: String,
        networkName: String,
        project: ProjectIdentity
    ) -> CreateOperation {
        var mounts: [CreateOperation.Mount] = []
        for mount in service.mounts {
            guard case .bind(let hostPath) = mount.source else { continue }
            mounts.append(
                CreateOperation.Mount(
                    hostPath: hostPath,
                    containerPath: mount.target,
                    readOnly: mount.readOnly
                )
            )
        }
        let ports = service.ports.compactMap { port -> CreateOperation.Port? in
            guard let hostPort = port.hostPort else { return nil }
            return CreateOperation.Port(
                hostPort: hostPort,
                containerPort: port.containerPort,
                networkProtocol: port.networkProtocol.rawValue
            )
        }
        return CreateOperation(
            service: service.name,
            containerName: containerName,
            imageReference: imageReference,
            environment: service.environment.map { "\($0.key)=\($0.value)" }.sorted(),
            command: service.command,
            workingDirectory: service.workingDirectory,
            mounts: mounts,
            ports: ports,
            networkName: networkName,
            labels: project.labels(for: service),
            cpus: service.resources?.cpus,
            memoryBytes: service.resources?.memoryBytes
        )
    }
}
