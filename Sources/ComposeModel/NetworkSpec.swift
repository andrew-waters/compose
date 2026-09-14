/// One entry under the top-level `networks:`.
///
/// A service attaching to a network names the key, not the network. The key is scoped to the
/// project and the real network is `<project>_<key>`, unless the entry sets `name:` or is
/// external, both of which mean the name is already someone else's.
public struct NetworkSpec: Sendable, Hashable, Identifiable {
    public var id: String { key }

    /// The key under `networks:`, as services refer to it.
    public var key: String
    /// An explicit `name:`, which turns off project-name prefixing.
    public var name: String?
    public var driver: String?
    /// `external: true`, meaning the network must already exist and is never created or
    /// removed here.
    public var isExternal: Bool
    public var labels: [String: String]

    public init(
        key: String,
        name: String? = nil,
        driver: String? = nil,
        isExternal: Bool = false,
        labels: [String: String] = [:]
    ) {
        self.key = key
        self.name = name
        self.driver = driver
        self.isExternal = isExternal
        self.labels = labels
    }

    /// The name the network has on the host.
    public func resolvedName(projectName: String) -> String {
        name ?? (isExternal ? key : "\(projectName)_\(key)")
    }
}
