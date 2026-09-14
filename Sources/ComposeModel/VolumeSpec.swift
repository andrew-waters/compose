/// One entry under the top-level `volumes:`.
///
/// Named volumes are deferred for v1: they are parsed, reported and carried in the model, and
/// nothing creates or removes them. The type exists now so that the shape of the file is not
/// lost, and so the deferral is visible rather than implied by a missing type.
public struct VolumeSpec: Sendable, Hashable, Identifiable {
    public var id: String { key }

    /// The key under `volumes:`, as services refer to it.
    public var key: String
    /// An explicit `name:`, which turns off project-name prefixing.
    public var name: String?
    public var driver: String?
    /// `external: true`, meaning the volume is managed outside this project.
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
