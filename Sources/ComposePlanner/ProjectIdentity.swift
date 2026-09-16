import ComposeModel
import CryptoKit
import Foundation

/// The project name, the labels derived from it, and the hash that makes a second `up` sane.
///
/// The labels are namespaced to this project rather than to whatever created the container,
/// so that every front end reads and writes the same three keys and none of them stamps
/// another tool's name on someone's containers.
///
/// There is no state file anywhere. Everything this type produces is stamped onto containers
/// at create time, and read back off them to work out what a project currently is. The
/// containers are the record.
public struct ProjectIdentity: Sendable, Hashable {
    /// The project a container belongs to.
    public static let projectLabel = "com.compose.project"
    /// The key the container's service sits under in the file.
    public static let serviceLabel = "com.compose.service"
    /// The hash of the resolved service at the moment the container was created.
    public static let hashLabel = "com.compose.hash"

    public let name: String

    /// Normalises on the way in, so two spellings of the same project are the same project.
    public init(name: String) {
        self.name = Self.normalised(name)
    }

    /// Settle the project name from the three places it can come from, in the order compose
    /// prefers them: the command line, then the file, then the directory the file lives in.
    public static func resolve(
        explicitName: String? = nil,
        file: ComposeFile,
        projectDirectory: String
    ) -> ProjectIdentity {
        if let explicitName, !normalised(explicitName).isEmpty {
            return ProjectIdentity(name: explicitName)
        }
        if let fileName = file.name, !normalised(fileName).isEmpty {
            return ProjectIdentity(name: fileName)
        }
        let directory = URL(fileURLWithPath: projectDirectory).standardizedFileURL.lastPathComponent
        let fromDirectory = normalised(directory)
        return ProjectIdentity(name: fromDirectory.isEmpty ? "compose" : fromDirectory)
    }

    /// Lower case, and only the characters a container name may carry. Compose does the same,
    /// which matters because a project created by one tool has to be recognised by the other.
    public static func normalised(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let kept = lowered.unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
        }
        var name = String(String.UnicodeScalarView(kept))
        while let first = name.first, first == "_" || first == "-" {
            name.removeFirst()
        }
        return name
    }

    /// `container_name` when the file set one, otherwise the conventional `<project>-<service>`.
    public func containerName(for service: Service) -> String {
        service.containerName ?? "\(name)-\(service.name)"
    }

    /// The network a service with no `networks:` of its own joins.
    public var defaultNetworkName: String {
        "\(name)_default"
    }

    /// The three project labels, plus whatever the service itself declared. The project labels
    /// are written last on purpose: a file cannot overwrite them and hide from `down`.
    public func labels(for service: Service) -> [String: String] {
        var labels = service.labels
        labels[Self.projectLabel] = name
        labels[Self.serviceLabel] = service.name
        labels[Self.hashLabel] = Self.hash(of: service)
        return labels
    }

    /// Labels for a network this project creates, so `down` can tell its own networks from
    /// networks that were already there.
    public func networkLabels() -> [String: String] {
        [Self.projectLabel: name]
    }

    /// A hash over everything that would change the container, and nothing that would not.
    ///
    /// This is the whole of the reconciliation story: it is stamped on at create, compared on
    /// the next `up`, and a difference means recreate, because a container's configuration
    /// cannot be changed after it is created.
    public static func hash(of service: Service) -> String {
        let digest = SHA256.hash(data: Data(service.canonicalDescription.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
