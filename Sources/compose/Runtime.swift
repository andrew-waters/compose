import ComposeModel
import ComposePlanner
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

/// The only part of the plugin that talks to the runtime.
///
/// Everything above this decides; this carries out. The split is why the planner can be
/// tested without any of this existing.
enum Runtime {
    // MARK: - Reading the world

    /// Every container, network, image and volume the runtime knows about.
    ///
    /// Deliberately everything, not just this project's: the planner checks published ports
    /// against the whole machine, and a host port taken by something unrelated is exactly the
    /// conflict worth catching before anything is created.
    static func snapshot() async throws -> CurrentState {
        do {
            async let containers = ContainerClient().list()
            async let networks = NetworkClient().list()
            async let images = ClientImage.list()
            async let volumes = ClientVolume.list()
            return CurrentState(
                containers: try await containers.map(state(of:)),
                networks: try await networks.map {
                    NetworkState(name: $0.id, labels: $0.labels.dictionary)
                },
                images: try await images.map(\.reference),
                volumes: try await volumes.map { VolumeState(name: $0.name, labels: $0.labels) }
            )
        } catch {
            throw ComposeError(
                "the container runtime is not reachable: \(friendly(error)). "
                    + "Check that `container system start` has been run."
            )
        }
    }

    // `ContainerState` is a name ContainerizationOCI also uses, hence the qualification.
    private static func state(of snapshot: ContainerSnapshot) -> ComposePlanner.ContainerState {
        ComposePlanner.ContainerState(
            name: snapshot.configuration.id,
            labels: snapshot.configuration.labels,
            isRunning: snapshot.status == .running,
            // A published range is one entry with a count, and the planner thinks in single
            // ports, so it is spread out here.
            publishedHostPorts: snapshot.configuration.publishedPorts.flatMap { port in
                (0..<port.count).map { port.hostPort + $0 }
            },
            networkName: snapshot.configuration.networks.first?.network,
            volumes: snapshot.configuration.mounts.compactMap(\.volumeName)
        )
    }

    // MARK: - Carrying a plan out

    static func execute(_ plan: Plan) async throws {
        let total = plan.operations.count
        for (index, operation) in plan.operations.enumerated() {
            Output.step(index + 1, of: total, operation.summary)
            do {
                try await perform(operation)
            } catch {
                guard case .runHook(let hook) = operation else {
                    throw failed(operation, error, later: total - index - 1)
                }
                switch outcome(of: hook, failingWith: error, later: total - index - 1) {
                case .carryOn(let warning):
                    Output.warning(warning)
                    continue
                case .stop(let message):
                    throw ComposeError(message)
                }
            }
        }
    }

    /// What a hook that went wrong means for the rest of the plan.
    enum HookOutcome: Equatable {
        /// Say so and go on to the next step.
        case carryOn(warning: String)
        /// Stop the plan with this message.
        case stop(message: String)
    }

    /// Whatever went wrong, whether the hook exited non-zero or never got going, the plan
    /// decided up front whether it matters.
    static func outcome(of hook: HookOperation, failingWith error: any Error, later: Int) -> HookOutcome {
        let text = (error as? HookFailure)?.description
            ?? "\(hook.phase.rawValue)[\(hook.index)] in service `\(hook.service)` could not run: \(friendly(error))"
        guard hook.failureIsFatal else {
            // The container is being stopped either way, so a failed `pre_stop` is worth
            // saying and not worth leaving the container up for.
            return .carryOn(warning: text + "\n  carrying on with the stop")
        }
        // The container is kept and its hash has not changed, so another `up` would leave it
        // alone and the hook would not run again.
        return .stop(
            message: text
                + "\n  `\(hook.containerName)` was left in place"
                + (later > 0 ? "; \(later) later step(s) were not attempted" : "")
                + "\n  `up` keeps a running container, so it will not run this hook again; "
                + "run `down` and then `up` once it is fixed"
        )
    }

    private static func failed(_ operation: ComposePlanner.Operation, _ error: any Error, later: Int) -> any Error {
        if error is ComposeError { return error }
        // A plan stops at the first failure. Some of it has happened and the rest has not,
        // which is worth saying plainly: the next `up` will work out the difference from the
        // containers themselves.
        return ComposeError(
            "\(operation.summary) failed: \(friendly(error))\n"
                + "  \(later) later step(s) were not attempted; run `up` again once it is fixed"
        )
    }

    // `Operation` is a name Foundation also uses, hence the qualification.
    private static func perform(_ operation: ComposePlanner.Operation) async throws {
        switch operation {
        case .createNetwork(let operation):
            try await createNetwork(operation)
        case .removeNetwork(let operation):
            try await NetworkClient().delete(id: operation.name)
        case .createVolume(let operation):
            // `local` is the only driver the runtime has; a file naming another was told so.
            _ = try await ClientVolume.create(name: operation.name, labels: operation.labels)
        case .removeVolume(let operation):
            try await ClientVolume.delete(name: operation.name)
        case .pullImage(let operation):
            try await pull(operation)
        case .buildImage(let operation):
            try build(operation)
        case .createContainer(let operation):
            try await create(operation)
        case .startContainer(let reference):
            let process = try await ContainerClient().bootstrap(id: reference.containerName, stdio: [nil, nil, nil])
            try await process.start()
        case .stopContainer(let reference):
            try await ContainerClient().stop(id: reference.containerName)
        case .removeContainer(let reference):
            try await ContainerClient().delete(id: reference.containerName, force: true)
        case .runHook(let operation):
            try await runHook(operation)
        }
    }

    /// A hook runs the way `container exec` runs anything: a new process in the running
    /// container, starting from the container's own process configuration so that whatever
    /// the hook does not set (environment, directory, user) is what the service runs with.
    ///
    /// Output is shown as it arrives, under the step, as build output is.
    private static func runHook(_ operation: HookOperation) async throws {
        let client = ContainerClient()
        let container = try await client.get(id: operation.containerName)
        guard container.status == .running else {
            throw ComposeError("`\(operation.containerName)` is not running")
        }
        guard let executable = operation.command.first else {
            throw ComposeError("\(operation.phase.rawValue)[\(operation.index)] in service `\(operation.service)` has no command")
        }

        var configuration = container.configuration.initProcess
        configuration.executable = executable
        configuration.arguments = Array(operation.command.dropFirst())
        configuration.terminal = false
        configuration.environment.append(contentsOf: operation.environment)
        if let workingDirectory = operation.workingDirectory {
            configuration.workingDirectory = workingDirectory
        }
        if let user = operation.user {
            configuration.user = .raw(userString: user)
        }

        let output = Pipe()
        let errors = Pipe()
        let process = try await client.createProcess(
            containerId: container.id,
            processId: UUID().uuidString.lowercased(),
            configuration: configuration,
            stdio: [nil, output.fileHandleForWriting, errors.fileHandleForWriting]
        )
        // The runtime holds its own copies now. Ours have to go, or the reads below never
        // see the end of the stream.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try await process.start()

        let transcript = HookTranscript()
        for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
            Task { await transcript.relay(handle) }
        }
        let status = try await process.wait()
        // A hook that leaves something running in the background (`daemon &`) leaves it
        // holding the hook's output, so the end of the stream may never come. Give it a
        // moment to drain, as `container exec` does, then stop showing it and move on.
        await transcript.drain(streams: 2, within: .seconds(3))

        guard status == 0 else {
            throw HookFailure(hook: operation, status: status, lastLines: transcript.lastLines)
        }
    }

    private static func createNetwork(_ operation: NetworkOperation) async throws {
        let configuration = try NetworkConfiguration(
            name: operation.name,
            mode: .nat,
            labels: try ResourceLabels(operation.labels),
            plugin: "container-network-vmnet"
        )
        _ = try await NetworkClient().create(configuration: configuration)
    }

    private static func pull(_ operation: PullOperation) async throws {
        let printer = PullPhasePrinter()
        _ = try await ClientImage.pull(
            reference: operation.imageReference,
            platform: try operation.platform.map(ContainerizationOCI.Platform.init(from:)),
            containerSystemConfig: try await ConfigurationLoader.load(),
            progressUpdate: { events in printer.handle(events) }
        )
    }

    /// The one operation that is not carried out in process.
    ///
    /// Building needs the BuildKit builder started, dialled and its result unpacked, and the
    /// CLI is the only thing that does all three. Doing anything else here would be a second
    /// implementation of the hard part.
    private static func build(_ operation: BuildOperation) throws {
        var arguments = [
            "build",
            "--tag", operation.imageReference,
            // The service's platform when it names one, so a `platform: linux/amd64` service
            // gets an image it can run. Otherwise arm64, the host's, as before.
            operation.platform.map { "--platform=\($0)" } ?? "--arch=arm64",
            "--progress", "plain",
        ]
        if let dockerfile = operation.dockerfile {
            let path = dockerfile.hasPrefix("/")
                ? dockerfile
                : (operation.context as NSString).appendingPathComponent(dockerfile)
            arguments += ["--file", path]
        }
        for key in operation.arguments.keys.sorted() {
            arguments += ["--build-arg", "\(key)=\(operation.arguments[key] ?? "")"]
        }
        if let target = operation.target, !target.isEmpty {
            arguments += ["--target", target]
        }
        arguments.append(operation.context)

        let process = Process()
        let binary = containerBinary()
        if binary.contains("/") {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [binary] + arguments
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ComposeError("`container build` exited \(process.terminationStatus)")
        }
    }

    /// Create the host directories a service binds that are not there yet, which is what
    /// compose does and what a file writing `./data/public:/data` expects.
    ///
    /// Without this the runtime is handed a mount whose source does not exist and the failure
    /// arrives much later, as a container that will not bootstrap with `errno 2`.
    ///
    /// - Returns: the paths that had to be created, for reporting.
    @discardableResult
    static func ensureBindSources(of operation: CreateOperation) throws -> [String] {
        var created: [String] = []
        for mount in operation.mounts {
            guard case .bind(let hostPath) = mount.source, !FileManager.default.fileExists(atPath: hostPath) else {
                continue
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: hostPath,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ComposeError(
                    "`\(hostPath)` is mounted at `\(mount.containerPath)` and does not "
                        + "exist: \(error.localizedDescription)"
                )
            }
            created.append(hostPath)
        }
        return created
    }

    /// Whether a container of this platform runs under Rosetta, which is the rule
    /// `container run` applies: an amd64 container on an arm64 host.
    static func needsRosetta(
        _ platform: ContainerizationOCI.Platform,
        host: ContainerizationOCI.Platform = .current
    ) -> Bool {
        host.architecture == "arm64" && platform.architecture == "amd64"
    }

    /// The `container` CLI that ran this plugin.
    ///
    /// A plugin lives at `<root>/libexec/container-plugins/<name>/bin/<name>`, so the CLI is
    /// five levels up and back down into `bin`. The fallbacks are for a plugin being run
    /// straight out of a build directory.
    private static func containerBinary() -> String {
        var root = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let sibling = root.appendingPathComponent("bin").appendingPathComponent("container").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/container") {
            return "/usr/local/bin/container"
        }
        return "container"
    }

    private static func create(_ operation: CreateOperation) async throws {
        for path in try ensureBindSources(of: operation) {
            Output.note("        created \(path)")
        }
        let systemConfig = try await ConfigurationLoader.load()
        let platform = try operation.platform.map(ContainerizationOCI.Platform.init(from:)) ?? .current
        // Fetching with the platform pulls that variant when the stored image lacks it.
        let image = try await ClientImage.fetch(
            reference: operation.imageReference,
            platform: platform,
            containerSystemConfig: systemConfig
        )
        _ = try await image.getCreateSnapshot(platform: platform)
        // The kernel is always the host's: only the container's userspace is another
        // architecture, and Rosetta runs that. `container run --platform` does the same.
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        let imageConfig = try await image.config(for: platform).config

        var mounts: [Filesystem] = []
        for mount in operation.mounts {
            let options: MountOptions = mount.readOnly ? ["ro"] : []
            switch mount.source {
            case .bind(let hostPath):
                mounts.append(.virtiofs(source: hostPath, destination: mount.containerPath, options: options))
            case .namedVolume(let name), .anonymousVolume(let name):
                // The plan created any volume that was missing, so this only reads where the
                // runtime keeps it, as `container run` does before mounting one.
                let volume = try await ClientVolume.inspect(name)
                mounts.append(
                    .volume(
                        name: name,
                        format: volume.format,
                        source: volume.source,
                        destination: mount.containerPath,
                        options: options
                    )
                )
            }
        }
        let ports: [PublishPort] = try operation.ports.map { port in
            try PublishPort(
                hostAddress: try IPAddress(port.hostAddress),
                hostPort: port.hostPort,
                containerPort: port.containerPort,
                proto: PublishProtocol(port.networkProtocol) ?? .tcp,
                count: 1
            )
        }

        let arguments = Planner.processArguments(
            imageEntrypoint: imageConfig?.entrypoint,
            imageCmd: imageConfig?.cmd,
            command: operation.command
        )
        guard let executable = arguments.first else {
            throw ComposeError(
                "`\(operation.imageReference)` declares no entrypoint or command, so service "
                    + "`\(operation.service)` has nothing to run; give it a `command`"
            )
        }
        let user: ProcessConfiguration.User = {
            if let raw = imageConfig?.user, !raw.isEmpty { return .raw(userString: raw) }
            return .id(uid: 0, gid: 0)
        }()
        let process = ProcessConfiguration(
            executable: executable,
            arguments: Array(arguments.dropFirst()),
            environment: (imageConfig?.env ?? []) + operation.environment,
            workingDirectory: operation.workingDirectory ?? imageConfig?.workingDir ?? "/",
            terminal: false,
            user: user
        )

        var configuration = ContainerResource.ContainerConfiguration(
            id: operation.containerName,
            image: image.description,
            process: process
        )
        configuration.mounts = mounts
        configuration.publishedPorts = ports
        configuration.labels = operation.labels
        configuration.platform = platform
        configuration.rosetta = Runtime.needsRosetta(platform)
        configuration.runtimeHandler = "container-runtime-\(platform.os)"
        // A compose file can ask for half a core; a VM cannot have one. Round up, because the
        // number is a limit and rounding down would be a quieter kind of wrong.
        if let cpus = operation.cpus {
            configuration.resources.cpus = max(1, Int(cpus.rounded(.up)))
        }
        if let memory = operation.memoryBytes {
            configuration.resources.memoryInBytes = memory
        }
        // Always send a resolver configuration, even an empty one. A container created with
        // none comes up with no /etc/resolv.conf at all: the runtime fills in the network's
        // own nameserver only when a configuration is present and its nameserver list is
        // empty, so leaving this nil skips that and every lookup inside the container falls
        // back to [::1]:53 and is refused. `container run` sends one even with no --dns flag,
        // because its flags default to empty rather than absent.
        //
        // Naming nameservers explicitly matters on a project network, where the gateway does
        // not answer: a service that has to resolve anything needs `dns:` in the file until
        // the runtime serves DNS on networks it did not create itself.
        //
        // The default domain from container's config.toml goes in too, as `container run`
        // sends it, so a container can reach another on the same domain by its short name.
        let dnsDomain = systemConfig.dns.domain
        configuration.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: operation.dns,
            domain: dnsDomain,
            searchDomains: operation.dnsSearch,
            options: operation.dnsOptions
        )
        configuration.networks = [
            AttachmentConfiguration(
                network: operation.networkName,
                // The hostname is the container name, not the service name. A compose file
                // expects one service to reach another by service name, but the runtime
                // requires hostnames to be unique across every container on the machine, so
                // two projects with a `db` service could not both exist. Until
                // apple/container#1809 gives networks their own namespace, `<project>-<service>`
                // is the name a service answers to.
                options: AttachmentOptions(
                    hostname: hostname(containerName: operation.containerName, dnsDomain: dnsDomain),
                    macAddress: nil,
                    mtu: 1280
                )
            )
        ]

        try await ContainerClient().create(
            configuration: configuration,
            options: ContainerCreateOptions(autoRemove: false),
            kernel: kernel
        )
    }

    // MARK: - Helpers

    /// The hostname a container is attached with, built as `container run` builds it.
    ///
    /// The runtime's DNS looks a name up by exact match against the attachment's hostname,
    /// and the name it looks up is fully qualified with a trailing dot. A bare name is never
    /// found, so a container created with one is unreachable by name. A name with a dot in it
    /// is taken as already qualified; one without gets the default domain, when there is one.
    /// With neither there is nothing to qualify it with, and the bare name is what the CLI
    /// uses too.
    static func hostname(containerName: String, dnsDomain: String?) -> String {
        if containerName.contains(".") { return "\(containerName)." }
        if let dnsDomain { return "\(containerName).\(dnsDomain)." }
        return containerName
    }

    /// Runtime errors arrive wrapped and verbose. Take the message if there is one.
    static func friendly(_ error: any Error) -> String {
        let described = String(describing: error)
        if let range = described.range(of: "message: \"") {
            let rest = described[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[rest.startIndex..<end])
            }
        }
        return innermostCause(of: error.localizedDescription)
    }

    /// An error raised inside the guest reaches here with every layer's message wrapped round
    /// the one below, quotes and all:
    ///
    ///     failed to start process (cause: "internalError: "startProcess: vmexec error:
    ///     internalError: "failed to find target executable /no/such/script"""")
    ///
    /// The innermost message is the one that says what went wrong.
    static func innermostCause(of text: String) -> String {
        guard text.contains("(cause: \""), let opening = text.range(of: ": \"", options: .backwards) else {
            return text
        }
        let cause = text[opening.upperBound...].prefix { $0 != "\"" }
        return cause.isEmpty ? text : String(cause)
    }
}

/// A hook that ran and exited non-zero. Whether that stops the plan is the plan's decision,
/// carried on the operation, so this only says what happened.
struct HookFailure: Error, CustomStringConvertible {
    let hook: HookOperation
    let status: Int32
    let lastLines: [String]

    var description: String {
        var text = "\(hook.phase.rawValue)[\(hook.index)] in service `\(hook.service)` exited \(status)"
        if !lastLines.isEmpty {
            text += "\n  its last output was:"
            for line in lastLines { text += "\n    \(line)" }
        }
        return text
    }
}

/// Shows a hook's output line by line as it arrives, and keeps the end of it for the error
/// if the hook fails. stdout and stderr both land on stdout here, interleaved as they come,
/// because the order things happened in is the useful part.
final class HookTranscript: @unchecked Sendable {
    private static let kept = 20
    private let lock = NSLock()
    private var lines: [String] = []

    var lastLines: [String] {
        lock.withLock { lines }
    }

    private var finished = 0
    private var stopped = false

    /// Shows and keeps a line, unless the hook has been moved on from.
    private func show(_ line: String) {
        let shown = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            lines.append(line)
            if lines.count > Self.kept { lines.removeFirst(lines.count - Self.kept) }
            return true
        }
        if shown { Output.line("        \(line)") }
    }

    private func finish() {
        lock.withLock { finished += 1 }
    }

    func relay(_ handle: FileHandle) async {
        do {
            for try await line in handle.bytes.lines {
                show(line)
            }
        } catch {
            // A stream that breaks part way loses the rest of the output, not the hook's
            // exit status, which is what decides the outcome.
        }
        finish()
    }

    /// Waits for every stream to end, or for the deadline, whichever is first. Polled rather
    /// than awaited: a read on a pipe something else still holds does not end when asked to,
    /// so nothing that waits for the relays themselves could be given a deadline.
    func drain(streams: Int, within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if lock.withLock({ finished >= streams }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        lock.withLock { stopped = true }
    }
}

/// Pulls are slow and silent otherwise. Only phase changes are printed: a progress bar in a
/// plugin that may be writing to a pipe is worse than nothing.
private final class PullPhasePrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func handle(_ events: [ProgressUpdateEvent]) {
        var phase: String?
        for event in events {
            if case .setDescription(let text) = event { phase = text }
        }
        guard let phase, !phase.isEmpty else { return }
        lock.lock()
        let changed = phase != last
        last = phase
        lock.unlock()
        if changed { Output.note("        \(phase)") }
    }
}
