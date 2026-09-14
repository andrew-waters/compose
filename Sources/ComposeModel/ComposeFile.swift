/// A YAML value kept exactly as written, used for `x-` extension keys.
///
/// Extension keys belong to whichever tool defined them, so they are carried through rather
/// than interpreted. They still take part in the service hash: changing one is a change to
/// the service, even though nothing here knows what it means.
public enum ExtensionValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case list([ExtensionValue])
    case map([String: ExtensionValue])

    public var canonicalDescription: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "null"
        case .list(let values):
            return "[" + values.map(\.canonicalDescription).joined(separator: ",") + "]"
        case .map(let values):
            let pairs = values.keys.sorted().map { "\($0)=\(values[$0]?.canonicalDescription ?? "")" }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }
}

/// A whole compose file, parsed and resolved.
///
/// This is the parser's output and the planner's input, and it holds no source text: by the
/// time a file becomes one of these, every question about what the file says has been
/// answered. What the file asked for and will not get comes back separately, as findings.
public struct ComposeFile: Sendable, Hashable {
    /// The top-level `name:`, if the file set one. The project name is settled elsewhere,
    /// because the command line and the directory name both outrank this.
    public var name: String?
    public var services: [String: Service]
    public var networks: [String: NetworkSpec]
    public var volumes: [String: VolumeSpec]
    public var extensions: [String: ExtensionValue]

    public init(
        name: String? = nil,
        services: [String: Service] = [:],
        networks: [String: NetworkSpec] = [:],
        volumes: [String: VolumeSpec] = [:],
        extensions: [String: ExtensionValue] = [:]
    ) {
        self.name = name
        self.services = services
        self.networks = networks
        self.volumes = volumes
        self.extensions = extensions
    }

    /// Services in name order. Anything that has to be stable run to run starts here and is
    /// then reordered by the dependency graph, so a mapping's file order never leaks into a
    /// plan.
    public var orderedServices: [Service] {
        services.values.sorted { $0.name < $1.name }
    }

    public subscript(service name: String) -> Service? {
        services[name]
    }
}
