import ComposeModel
import ComposeParser
import Foundation
import Testing

/// A file set held in memory, so that `env_file` and `.env` can be exercised without writing
/// anything to a temporary directory.
struct StubFileSystem: ComposeFileSystem {
    let files: [String: String]

    func fileExists(atPath path: String) -> Bool {
        files[path] != nil
    }

    func contentsOfFile(atPath path: String) throws -> String {
        guard let text = files[path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return text
    }
}

enum Fixture {
    static let projectDirectory = "/project"

    static func parse(
        _ yaml: String,
        environment: [String: String] = [:],
        files: [String: String] = [:],
        dotEnv: String? = nil
    ) throws -> ParseResult {
        var contents = files
        if let dotEnv { contents["\(projectDirectory)/.env"] = dotEnv }
        let options = ParseOptions(
            projectDirectory: projectDirectory,
            environment: environment,
            dotEnvPath: dotEnv == nil ? nil : ".env",
            fileSystem: StubFileSystem(files: contents)
        )
        return try ComposeFileParser.parse(yaml: yaml, options: options)
    }

    /// One of the `.yml` files next to these tests.
    static func text(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "yml", subdirectory: "Fixtures")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
