import ComposeModel
import ComposeParser
import ComposePlanner
import Testing

extension Plan {
    /// The containers a plan creates, in order.
    var createOperations: [CreateOperation] {
        operations.compactMap { operation in
            guard case .createContainer(let create) = operation else { return nil }
            return create
        }
    }
}

enum Sample {
    /// Parse without touching the disk: no `.env`, and nothing in these files names an
    /// `env_file`.
    static func file(_ yaml: String) throws -> ComposeFile {
        try ComposeFileParser.parse(
            yaml: yaml,
            options: ParseOptions(projectDirectory: "/project", environment: [:], dotEnvPath: nil)
        ).file
    }

    static let project = ProjectIdentity(name: "shop")

    /// A three-service file where `web` waits for `api`, which waits for `db`.
    static let chain = """
        services:
          web:
            image: nginx
            depends_on: [api]
          api:
            image: api:1
            depends_on: [db]
          db:
            image: postgres:16
        """

    /// A container as the runtime would report it after this project created it.
    static func container(
        service: String,
        in file: ComposeFile,
        project: ProjectIdentity = Sample.project,
        running: Bool = true,
        hash: String? = nil,
        publishedHostPorts: [UInt16] = [],
        networkName: String? = nil
    ) throws -> ContainerState {
        let resolved = try #require(file.services[service])
        var labels = project.labels(for: resolved)
        if let hash { labels[ProjectIdentity.hashLabel] = hash }
        return ContainerState(
            name: project.containerName(for: resolved),
            labels: labels,
            isRunning: running,
            publishedHostPorts: publishedHostPorts,
            networkName: networkName ?? project.defaultNetworkName
        )
    }
}
