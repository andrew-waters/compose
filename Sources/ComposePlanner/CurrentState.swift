import ComposeModel

/// What exists right now, as far as the planner is concerned.
///
/// The planner is a pure function of a compose file and one of these, which is what lets the
/// interesting decisions be tested without a daemon: a snapshot is a value, and a test can
/// write one by hand.
public struct CurrentState: Sendable, Equatable {
    /// Every container the runtime knows about, not only this project's.
    ///
    /// The port conflict check needs the rest of them: a host port taken by something entirely
    /// unrelated is exactly the conflict worth catching before anything is created.
    public let containers: [ContainerState]
    public let networks: [NetworkState]
    /// Image references already present locally, so the plan knows what still has to be pulled.
    public let images: [String]

    public init(containers: [ContainerState] = [], networks: [NetworkState] = [], images: [String] = []) {
        self.containers = containers
        self.networks = networks
        self.images = images
    }
}

public struct ContainerState: Sendable, Equatable {
    public let name: String
    public let labels: [String: String]
    public let isRunning: Bool
    /// Host ports this container currently publishes, whoever created it.
    public let publishedHostPorts: [UInt16]
    public let networkName: String?

    public init(
        name: String,
        labels: [String: String] = [:],
        isRunning: Bool = false,
        publishedHostPorts: [UInt16] = [],
        networkName: String? = nil
    ) {
        self.name = name
        self.labels = labels
        self.isRunning = isRunning
        self.publishedHostPorts = publishedHostPorts
        self.networkName = networkName
    }

    public var projectName: String? { labels[ProjectIdentity.projectLabel] }
    public var serviceName: String? { labels[ProjectIdentity.serviceLabel] }
    public var serviceHash: String? { labels[ProjectIdentity.hashLabel] }
}

public struct NetworkState: Sendable, Equatable {
    public let name: String
    public let labels: [String: String]

    public init(name: String, labels: [String: String] = [:]) {
        self.name = name
        self.labels = labels
    }

    public var projectName: String? { labels[ProjectIdentity.projectLabel] }
}
