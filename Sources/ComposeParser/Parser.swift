import ComposeModel
import Foundation
import Yams

/// Everything a parse needs to know about the world outside the file.
public struct ParseOptions: Sendable {
    /// The directory the compose file lives in. Every relative path in the file resolves
    /// against this, not against the working directory of whoever ran the command.
    public var projectDirectory: String
    /// The shell environment, which wins over `.env` for interpolation.
    public var environment: [String: String]
    /// The dotenv file read for interpolation values, relative to the project directory.
    /// `nil` skips it. A missing file is not an error, as compose treats it.
    public var dotEnvPath: String?
    public var fileSystem: any ComposeFileSystem

    public init(
        projectDirectory: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        dotEnvPath: String? = ".env",
        fileSystem: any ComposeFileSystem = DiskFileSystem()
    ) {
        self.projectDirectory = projectDirectory
        self.environment = environment
        self.dotEnvPath = dotEnvPath
        self.fileSystem = fileSystem
    }
}

/// YAML in, model out.
///
/// The parser answers one question, "what does this file say", and refuses to answer the other
/// one, "should we run it". Keys it will not act on come back as findings for a front end to
/// judge; only a file that cannot be understood at all is an error.
public enum ComposeFileParser {
    public static func parse(yaml: String, options: ParseOptions = ParseOptions()) throws -> ParseResult {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch let error as YamlError {
            throw ParseError.yaml(error)
        }
        guard let root else {
            throw ParseError(reason: .missingKey, problem: "the compose file is empty")
        }
        var parser = FileParser(options: options, interpolator: try Self.interpolator(for: options))
        let file = try parser.run(root: root)
        return ParseResult(
            file: file,
            findings: parser.findings,
            interpolationWarnings: parser.warnings
        )
    }

    public static func parse(contentsOfFile path: String, options: ParseOptions? = nil) throws -> ParseResult {
        let directory = (path as NSString).deletingLastPathComponent
        var resolved = options ?? ParseOptions(projectDirectory: directory.isEmpty ? "." : directory)
        if options == nil { resolved.projectDirectory = directory.isEmpty ? "." : directory }
        let text = try resolved.fileSystem.contentsOfFile(atPath: path)
        return try parse(yaml: text, options: resolved)
    }

    /// Shell environment over `.env` file, which is the order compose documents and the order
    /// people rely on when they override a value for one run.
    private static func interpolator(for options: ParseOptions) throws -> Interpolator {
        var variables: [String: String] = [:]
        if let dotEnvPath = options.dotEnvPath {
            let path = resolvePath(dotEnvPath, relativeTo: options.projectDirectory)
            if options.fileSystem.fileExists(atPath: path) {
                for pair in DotEnv.parse(try options.fileSystem.contentsOfFile(atPath: path)) {
                    variables[pair.key] = pair.value
                }
            }
        }
        for (key, value) in options.environment { variables[key] = value }
        return Interpolator(variables: variables)
    }
}

/// One parse in progress. A struct rather than a free function because findings and warnings
/// accumulate across the whole file and every helper needs to add to them.
struct FileParser {
    let options: ParseOptions
    let interpolator: Interpolator
    var findings: [Finding] = []
    var warnings: [InterpolationWarning] = []

    mutating func run(root: Node) throws -> ComposeFile {
        let top = try mapping(root, path: "")
        var file = ComposeFile()
        var serviceNodes: [(name: String, node: Node)] = []

        if let versionNode = top["version"] {
            try checkSpecVersion(versionNode)
        }

        for (keyNode, valueNode) in top {
            guard let key = keyNode.scalar?.string else {
                throw ParseError(
                    reason: .wrongShape,
                    problem: "top-level keys must be plain strings",
                    mark: mark(keyNode)
                )
            }
            if KeySupportTable.isExtensionKey(key) {
                file.extensions[key] = extensionValue(valueNode)
                continue
            }
            switch key {
            case "name":
                file.name = try string(valueNode, path: "name")
            case "services":
                for (serviceKeyNode, serviceNode) in try mapping(valueNode, path: "services") {
                    guard let name = serviceKeyNode.scalar?.string, !name.isEmpty else {
                        throw ParseError(
                            reason: .wrongShape,
                            problem: "service names must be plain strings",
                            mark: mark(serviceKeyNode)
                        )
                    }
                    try validateName(name, kind: "service", node: serviceKeyNode)
                    serviceNodes.append((name, serviceNode))
                }
            case "networks":
                file.networks = try parseTopLevelNetworks(valueNode)
            case "volumes":
                file.volumes = try parseTopLevelVolumes(valueNode)
            case "version":
                note(key: "version", node: valueNode, support: KeySupportTable.topLevel["version"]!)
            default:
                if let support = KeySupportTable.topLevel[key] {
                    note(key: key, node: valueNode, support: support)
                } else {
                    noteUnknown(key: key, node: keyNode)
                }
            }
        }

        guard !serviceNodes.isEmpty else {
            throw ParseError(
                reason: top["services"] == nil ? .missingKey : .wrongShape,
                problem: top["services"] == nil
                    ? "the file declares no `services`"
                    : "`services` declares nothing",
                mark: mark(root)
            )
        }

        for (name, node) in serviceNodes {
            file.services[name] = try parseService(name: name, node: node)
        }

        try validateReferences(in: file, serviceNodes: serviceNodes)
        return file
    }

    /// Version 2 files are understood well enough to be refused clearly, which is the whole
    /// point of refusing them: half reading one would be worse than not reading it.
    private mutating func checkSpecVersion(_ node: Node) throws {
        guard let raw = node.scalar?.string else { return }
        let major = raw.split(separator: ".").first.map(String.init) ?? raw
        if major == "2" {
            throw ParseError(
                reason: .unsupportedSpecVersion,
                problem: "this is a version \(raw) compose file; only the current Compose "
                    + "Specification is supported, so remove the `version` key and check the "
                    + "file against the current spec",
                mark: mark(node),
                path: "version"
            )
        }
        if major == "1" {
            throw ParseError(
                reason: .unsupportedSpecVersion,
                problem: "this is a version \(raw) compose file, which predates `services:`",
                mark: mark(node),
                path: "version"
            )
        }
    }

    /// Networks and services can only be referred to once the whole file is read, because a
    /// service may name a network the file declares further down.
    private func validateReferences(in file: ComposeFile, serviceNodes: [(name: String, node: Node)]) throws {
        let nodesByName = Dictionary(uniqueKeysWithValues: serviceNodes.map { ($0.name, $0.node) })
        for service in file.orderedServices {
            for network in service.networks where network != "default" && file.networks[network] == nil {
                throw ParseError(
                    reason: .undefinedReference,
                    problem: "service `\(service.name)` attaches to network `\(network)`, "
                        + "which the file does not declare",
                    mark: nodesByName[service.name].flatMap(mark),
                    path: "services.\(service.name).networks"
                )
            }
            for dependency in service.dependsOn where file.services[dependency] == nil {
                throw ParseError(
                    reason: .undefinedReference,
                    problem: "service `\(service.name)` depends on `\(dependency)`, "
                        + "which the file does not declare",
                    mark: nodesByName[service.name].flatMap(mark),
                    path: "services.\(service.name).depends_on"
                )
            }
            for mount in service.mounts {
                guard case .named(let name) = mount.source, file.volumes[name] == nil else { continue }
                throw ParseError(
                    reason: .undefinedReference,
                    problem: "service `\(service.name)` mounts volume `\(name)`, "
                        + "which the file does not declare",
                    mark: nodesByName[service.name].flatMap(mark),
                    path: "services.\(service.name).volumes"
                )
            }
        }
    }

    // MARK: - Top-level networks and volumes

    private mutating func parseTopLevelNetworks(_ node: Node) throws -> [String: NetworkSpec] {
        var networks: [String: NetworkSpec] = [:]
        for (keyNode, valueNode) in try mapping(node, path: "networks") {
            guard let key = keyNode.scalar?.string, !key.isEmpty else {
                throw ParseError(reason: .wrongShape, problem: "network names must be plain strings", mark: mark(keyNode))
            }
            try validateName(key, kind: "network", node: keyNode)
            var spec = NetworkSpec(key: key)
            if valueNode.null == nil {
                for (fieldNode, fieldValue) in try mapping(valueNode, path: "networks.\(key)") {
                    let field = fieldNode.scalar?.string ?? ""
                    switch field {
                    case "name":
                        spec.name = try string(fieldValue, path: "networks.\(key).name")
                    case "driver":
                        spec.driver = try string(fieldValue, path: "networks.\(key).driver")
                        note(
                            key: "networks.\(key).driver",
                            node: fieldValue,
                            support: .unsupported(
                                severity: .cosmetic,
                                reason: "container chooses the driver for a user-defined network"
                            )
                        )
                    case "external":
                        spec.isExternal = fieldValue.bool ?? false
                    case "labels":
                        spec.labels = try parseLabels(fieldValue, service: nil, path: "networks.\(key).labels")
                    case "ipam":
                        note(
                            key: "networks.\(key).ipam",
                            node: fieldValue,
                            support: .deferred(severity: .behavioural, reason: "address ranges are not settable here yet")
                        )
                    default:
                        if KeySupportTable.isExtensionKey(field) { continue }
                        note(
                            key: "networks.\(key).\(field)",
                            node: fieldValue,
                            support: .unsupported(severity: .cosmetic, reason: "not part of a network this creates")
                        )
                    }
                }
            }
            networks[key] = spec
        }
        return networks
    }

    private mutating func parseTopLevelVolumes(_ node: Node) throws -> [String: VolumeSpec] {
        var volumes: [String: VolumeSpec] = [:]
        for (keyNode, valueNode) in try mapping(node, path: "volumes") {
            guard let key = keyNode.scalar?.string, !key.isEmpty else {
                throw ParseError(reason: .wrongShape, problem: "volume names must be plain strings", mark: mark(keyNode))
            }
            try validateName(key, kind: "volume", node: keyNode)
            var spec = VolumeSpec(key: key)
            if valueNode.null == nil {
                for (fieldNode, fieldValue) in try mapping(valueNode, path: "volumes.\(key)") {
                    let field = fieldNode.scalar?.string ?? ""
                    switch field {
                    case "name":
                        spec.name = try string(fieldValue, path: "volumes.\(key).name")
                    case "driver":
                        spec.driver = try string(fieldValue, path: "volumes.\(key).driver")
                    case "external":
                        spec.isExternal = fieldValue.bool ?? false
                    case "labels":
                        spec.labels = try parseLabels(fieldValue, service: nil, path: "volumes.\(key).labels")
                    default:
                        if KeySupportTable.isExtensionKey(field) { continue }
                        note(
                            key: "volumes.\(key).\(field)",
                            node: fieldValue,
                            support: .unsupported(severity: .cosmetic, reason: "not part of a volume this creates")
                        )
                    }
                }
            }
            note(
                key: "volumes.\(key)",
                node: node,
                support: .deferred(
                    severity: .behavioural,
                    reason: "named volumes are declared but never created; nothing manages their lifecycle yet"
                )
            )
            volumes[key] = spec
        }
        return volumes
    }
}
