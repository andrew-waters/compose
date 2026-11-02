/// One entry under the top-level `volumes:`.
///
/// A service mounting a volume names the key, not the volume. `up` creates the volume when it
/// is missing, labelled with the project, unless it is external; only `down -v` removes it, and
/// only when it carries the project label.
public struct VolumeSpec: Sendable, Hashable, Identifiable {
    public var id: String { key }

    /// The key under `volumes:`, as services refer to it.
    public var key: String
    /// An explicit `name:`, which turns off project-name prefixing.
    public var name: String?
    /// Carried for the record. The runtime has one driver, `local`, and the parser notes any
    /// other.
    public var driver: String?
    /// `external: true`, meaning the volume must already exist and is never created or removed
    /// here.
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

    /// The name the volume would have on the host.
    public func resolvedName(projectName: String) -> String {
        name ?? (isExternal ? key : "\(projectName)_\(key)")
    }
}
