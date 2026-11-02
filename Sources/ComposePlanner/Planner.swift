import ComposeModel

/// Something about the file, or about what already exists, that stops a plan being made.
///
/// Every one of these is raised before a single operation is emitted. A plan is all or nothing:
/// half a project is worse than none of it, and a port conflict found on the fourth service is
/// still a reason not to have created the first three.
public enum PlanError: Error, Sendable, Equatable, CustomStringConvertible {
    case dependencyCycle([String])
    /// Two services in the same file want the same host port.
    case duplicatePort(port: UInt16, services: [String])
    /// A service wants a host port something already running is using.
    case portConflict(port: UInt16, service: String, heldBy: String)
    case duplicateContainerName(name: String, services: [String])
    case missingExternalNetwork(name: String, service: String)
    case missingExternalVolume(name: String, service: String)
    /// Two mounts in the file want the same volume. A volume is an ext4 disk, and two
    /// machines writing one corrupt it.
    case sharedVolume(name: String, services: [String])
    /// A service mounts a volume a running container outside it already has.
    case volumeInUse(name: String, service: String, heldBy: String)

    public var description: String {
        switch self {
        case .dependencyCycle(let path):
            return "`depends_on` is circular: \(path.joined(separator: " -> "))"
        case .duplicatePort(let port, let services):
            return "services \(services.map { "`\($0)`" }.joined(separator: " and ")) "
                + "both publish host port \(port)"
        case .portConflict(let port, let service, let heldBy):
            return "service `\(service)` publishes host port \(port), which \(heldBy) is already using"
        case .duplicateContainerName(let name, let services):
            return "services \(services.map { "`\($0)`" }.joined(separator: " and ")) both want the container name `\(name)`"
        case .missingExternalNetwork(let name, let service):
            return "service `\(service)` attaches to external network `\(name)`, which does not exist"
        case .missingExternalVolume(let name, let service):
            return "service `\(service)` mounts external volume `\(name)`, which does not exist"
        case .sharedVolume(let name, let services):
            let users = services.count == 1
                ? "service `\(services[0])` mounts it more than once"
                : "services \(services.map { "`\($0)`" }.joined(separator: " and ")) both mount it"
            return "volume `\(name)` can only be mounted once, and \(users); "
                + "a volume here is a disk that one container uses at a time"
        case .volumeInUse(let name, let service, let heldBy):
            return "service `\(service)` mounts volume `\(name)`, which \(heldBy) is already using"
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
    /// Remove volumes this project created, named and anonymous. Off unless asked for, since a
    /// volume is where the data is.
    public var removeVolumes: Bool

    public init(removeNetworks: Bool = true, removeVolumes: Bool = false) {
        self.removeNetworks = removeNetworks
        self.removeVolumes = removeVolumes
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
        try checkExternalVolumes(in: file, project: project, order: order, state: state)

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
        try checkVolumeUse(
            file: file,
            project: project,
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

        // Volumes come before any container that mounts them. Every declared volume is made,
        // whether or not a service in this run is being created, which is what compose does; an
        // anonymous one only for a container about to be created, since nothing else will
        // mount it. Neither is made twice, so a recreated container finds its data.
        let existingVolumes = Set(state.volumes.map(\.name))
        var createdVolumes: Set<String> = []
        let declared = file.volumes.values
            .filter { !$0.isExternal }
            .map { (name: $0.resolvedName(projectName: project.name), spec: $0) }
            .sorted { $0.name < $1.name }
        for volume in declared where !existingVolumes.contains(volume.name) {
            guard createdVolumes.insert(volume.name).inserted else { continue }
            operations.append(
                .createVolume(VolumeOperation(name: volume.name, labels: project.volumeLabels(for: volume.spec)))
            )
        }
        for name in order {
            guard let service = file.services[name], actions[name] == .create || actions[name] == .recreate else {
                continue
            }
            for mount in service.mounts where mount.source == .anonymous {
                let volume = project.anonymousVolumeName(service: name, target: mount.target)
                guard !existingVolumes.contains(volume), createdVolumes.insert(volume).inserted else { continue }
                operations.append(
                    .createVolume(
                        VolumeOperation(
                            name: volume,
                            labels: project.anonymousVolumeLabels(service: name, target: mount.target)
                        )
                    )
                )
            }
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
                operations.append(contentsOf: hookOperations(.postStart, of: service, containerName: containerName))
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
                                target: build.target,
                                platform: service.platform
                            )
                        )
                    )
                } else if shouldPull(image, state: state, policy: options.pullPolicy) {
                    operations.append(
                        .pullImage(PullOperation(service: name, imageReference: image, platform: service.platform))
                    )
                }
                if action == .recreate, let existing = existingByService[name] {
                    let old = ContainerReference(containerName: existing.name, service: name)
                    if existing.isRunning {
                        operations.append(contentsOf: hookOperations(.preStop, of: service, containerName: existing.name))
                        operations.append(.stopContainer(old))
                    }
                    operations.append(.removeContainer(old))
                }
                operations.append(
                    .createContainer(
                        createOperation(
                            service: service,
                            file: file,
                            containerName: containerName,
                            imageReference: image,
                            networkName: assignment.name,
                            project: project
                        )
                    )
                )
                operations.append(.startContainer(reference))
                operations.append(contentsOf: hookOperations(.postStart, of: service, containerName: containerName))
            }
        }

        return Plan(project: project, operations: operations, decisions: decisions)
    }

    /// Stop and remove everything carrying the project label, then the networks the project
    /// created, in the reverse of the order `up` started things in.
    ///
    /// Volumes are left alone unless `removeVolumes` asks for them, which is the one piece of
    /// compose behaviour worth copying exactly: a volume is where the data is. When asked, only
    /// volumes carrying the project label go, so an external volume, or a `name:` volume that
    /// was there before the project, survives.
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
            if container.isRunning {
                // Hooks come from the file as it is now. A container whose service the file
                // no longer declares has none to run.
                if let service = container.serviceName.flatMap({ file.services[$0] }) {
                    operations.append(contentsOf: hookOperations(.preStop, of: service, containerName: container.name))
                }
                operations.append(.stopContainer(reference))
            }
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

        if options.removeVolumes {
            // The runtime refuses to delete a volume any container mounts, running or not, and
            // by then the containers and networks are gone. A volume still mounted outside what
            // this plan removes is left, as a network still in use is.
            let removed = Set(ordered.map(\.name))
            for volume in state.volumes.sorted(by: { $0.name < $1.name }) where volume.projectName == project.name {
                let stillUsed = state.containers.contains {
                    $0.volumes.contains(volume.name) && !removed.contains($0.name)
                }
                guard !stillUsed else { continue }
                operations.append(.removeVolume(VolumeOperation(name: volume.name, labels: volume.labels)))
            }
        }

        return Plan(project: project, operations: operations, decisions: decisions)
    }

    /// A service's hooks for one phase, as operations against one container, in the order the
    /// file declared them.
    private static func hookOperations(
        _ phase: HookOperation.Phase,
        of service: Service,
        containerName: String
    ) -> [Operation] {
        let hooks = phase == .postStart ? service.postStart : service.preStop
        return hooks.enumerated().map { index, hook in
            .runHook(
                HookOperation(
                    service: service.name,
                    containerName: containerName,
                    phase: phase,
                    index: index,
                    command: hook.command,
                    environment: hook.environment.keys.sorted().map { "\($0)=\(hook.environment[$0] ?? "")" },
                    workingDirectory: hook.workingDirectory,
                    user: hook.user,
                    failureIsFatal: phase == .postStart
                )
            )
        }
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
            guard let assignment = networkAssignment(for: name, in: file, project: project) else { continue }
            if assignment.isExternal, !state.networks.contains(where: { $0.name == assignment.name }) {
                throw PlanError.missingExternalNetwork(name: assignment.name, service: name)
            }
            assignments[name] = assignment
        }
        return assignments
    }

    private static func networkAssignment(
        for service: String,
        in file: ComposeFile,
        project: ProjectIdentity
    ) -> NetworkAssignment? {
        guard let service = file.services[service] else { return nil }
        guard let key = service.networks.first, let spec = file.networks[key] else {
            return NetworkAssignment(name: project.defaultNetworkName, isExternal: false)
        }
        return NetworkAssignment(
            name: spec.resolvedName(projectName: project.name),
            isExternal: spec.isExternal
        )
    }

    /// The network each service joins, by service name.
    ///
    /// One network per service, because a container joins one. Exposed because a front end
    /// showing a project has to name the same networks the plan will create, and working them
    /// out a second time is how the two come to disagree.
    public static func networkNames(in file: ComposeFile, project: ProjectIdentity) -> [String: String] {
        var names: [String: String] = [:]
        for name in file.services.keys {
            names[name] = networkAssignment(for: name, in: file, project: project)?.name
        }
        return names
    }

    /// An external volume is somebody else's to create, so one a service mounts has to be there
    /// already. Checked before any operation exists, as an external network is.
    private static func checkExternalVolumes(
        in file: ComposeFile,
        project: ProjectIdentity,
        order: [String],
        state: CurrentState
    ) throws {
        let existing = Set(state.volumes.map(\.name))
        for name in order {
            guard let service = file.services[name] else { continue }
            for mount in service.mounts {
                guard case .named(let key) = mount.source, let spec = file.volumes[key], spec.isExternal else {
                    continue
                }
                let volume = spec.resolvedName(projectName: project.name)
                if !existing.contains(volume) {
                    throw PlanError.missingExternalVolume(name: volume, service: name)
                }
            }
        }
    }

    /// Every volume mounted once, and by nothing else that is running.
    ///
    /// A volume is an ext4 disk attached to one container's machine, and the runtime does not
    /// stop a second one attaching it, so this has to. Read-only mounts are no exception: a
    /// read-only ext4 mount can still replay the journal, and nothing promises the attachment
    /// itself is read-only. Stopped containers do not count, as for ports; the clash surfaces
    /// when someone starts one again.
    private static func checkVolumeUse(
        file: ComposeFile,
        project: ProjectIdentity,
        order: [String],
        containerNames: [String: String],
        state: CurrentState,
        releasedContainers: Set<String>
    ) throws {
        var mountedBy: [String: String] = [:]
        for name in order {
            guard let service = file.services[name] else { continue }
            for mount in service.mounts {
                let volume: String
                switch mount.source {
                case .bind:
                    continue
                case .named(let key):
                    volume = file.volumes[key]?.resolvedName(projectName: project.name) ?? key
                case .anonymous:
                    volume = project.anonymousVolumeName(service: name, target: mount.target)
                }
                if let other = mountedBy[volume] {
                    throw PlanError.sharedVolume(name: volume, services: Array(Set([other, name])).sorted())
                }
                mountedBy[volume] = name
            }
        }
        for container in state.containers where container.isRunning && !releasedContainers.contains(container.name) {
            for volume in container.volumes.sorted() {
                guard let wanting = mountedBy[volume], containerNames[wanting] != container.name else { continue }
                throw PlanError.volumeInUse(name: volume, service: wanting, heldBy: "container `\(container.name)`")
            }
        }
    }

    /// Every published port, checked against every other service and against everything already
    /// running, before an operation exists to conflict with.
    ///
    /// Only running containers count. A stopped container's configuration still names a host
    /// port, but nothing is listening on it, and refusing to start a project because of a
    /// container somebody stopped weeks ago would be wrong. The conflict surfaces when they
    /// start it again, which is the same way every other tool behaves.
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
                    throw PlanError.duplicatePort(port: hostPort, services: [other, name].sorted())
                }
                wantedBy[hostPort] = name
            }
        }
        for container in state.containers where container.isRunning && !releasedContainers.contains(container.name) {
            for port in container.publishedHostPorts.sorted() {
                guard let wanting = wantedBy[port] else { continue }
                guard containerNames[wanting] != container.name else { continue }
                throw PlanError.portConflict(
                    port: port,
                    service: wanting,
                    heldBy: "container `\(container.name)`"
                )
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

    /// The long form of an image reference: registry, namespace, name and tag, all present.
    ///
    /// A compose file writes `nginx`; the runtime stores `docker.io/library/nginx:latest`. They
    /// are the same image, and deciding whether one is already here means saying so. The rules
    /// are the ones every registry client uses: a bare name is Docker Hub's library namespace,
    /// a first component with a dot, a colon or the name `localhost` is a registry host rather
    /// than a namespace, and a reference with no tag and no digest means `latest`.
    public static func normalisedImageReference(_ reference: String) -> String {
        var components = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return reference }
        if components.count == 1 {
            components = ["docker.io", "library", components[0]]
        } else if !components[0].contains("."), !components[0].contains(":"), components[0] != "localhost" {
            components.insert("docker.io", at: 0)
        }
        let last = components[components.count - 1]
        if !last.contains(":"), !last.contains("@") {
            components[components.count - 1] = "\(last):latest"
        }
        return components.joined(separator: "/")
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

    /// Image entrypoint, image cmd and the file's `command`, folded into the argument vector a
    /// container is created with.
    ///
    /// `command:` replaces the image's cmd and leaves its entrypoint alone, which is what the
    /// key means in compose and what the image's own config says. It lives here rather than in
    /// whatever executes the plan because it is a decision, and because the alternative is two
    /// front ends folding arguments slightly differently.
    public static func processArguments(
        imageEntrypoint: [String]?,
        imageCmd: [String]?,
        command: [String]
    ) -> [String] {
        var arguments: [String] = []
        if let imageEntrypoint, !imageEntrypoint.isEmpty {
            arguments = imageEntrypoint
        }
        if !command.isEmpty {
            arguments.append(contentsOf: command)
        } else if let imageCmd, !imageCmd.isEmpty {
            arguments.append(contentsOf: imageCmd)
        }
        return arguments
    }

    // MARK: - Create

    private static func createOperation(
        service: Service,
        file: ComposeFile,
        containerName: String,
        imageReference: String,
        networkName: String,
        project: ProjectIdentity
    ) -> CreateOperation {
        let mounts = service.mounts.map { mount -> CreateOperation.Mount in
            let source: CreateOperation.Mount.Source
            switch mount.source {
            case .bind(let hostPath):
                source = .bind(hostPath)
            case .named(let key):
                // The parser refuses a mount of a volume the file does not declare, so the key
                // is always there; falling back to it keeps this total without a crash.
                source = .namedVolume(file.volumes[key]?.resolvedName(projectName: project.name) ?? key)
            case .anonymous:
                source = .anonymousVolume(project.anonymousVolumeName(service: service.name, target: mount.target))
            }
            return CreateOperation.Mount(source: source, containerPath: mount.target, readOnly: mount.readOnly)
        }
        let ports = service.ports.compactMap { port -> CreateOperation.Port? in
            guard let hostPort = port.hostPort else { return nil }
            return CreateOperation.Port(
                hostAddress: port.hostIP ?? "0.0.0.0",
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
            dns: service.dns,
            dnsSearch: service.dnsSearch,
            dnsOptions: service.dnsOptions,
            cpus: service.resources?.cpus,
            memoryBytes: service.resources?.memoryBytes,
            platform: service.platform
        )
    }
}
