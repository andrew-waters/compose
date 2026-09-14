import ComposeModel
import ComposeParser
import Foundation
import Testing

@Suite("Interpolation and environment")
struct InterpolationTests {
    private func imageOf(_ yaml: String, environment: [String: String] = [:], dotEnv: String? = nil) throws -> String? {
        try Fixture.parse(yaml, environment: environment, dotEnv: dotEnv).file.services["web"]?.image
    }

    @Test("The substitution forms compose documents")
    func substitutionForms() throws {
        let environment = ["TAG": "1.2.3", "EMPTY": ""]
        #expect(try imageOf("services:\n  web:\n    image: nginx:${TAG}\n", environment: environment) == "nginx:1.2.3")
        #expect(try imageOf("services:\n  web:\n    image: nginx:$TAG\n", environment: environment) == "nginx:1.2.3")
        #expect(try imageOf("services:\n  web:\n    image: nginx:${MISSING:-latest}\n", environment: environment) == "nginx:latest")
        #expect(try imageOf("services:\n  web:\n    image: nginx:${EMPTY:-latest}\n", environment: environment) == "nginx:latest")
        #expect(try imageOf("services:\n  web:\n    image: nginx:${EMPTY-latest}\n", environment: environment) == "nginx:")
        #expect(try imageOf("services:\n  web:\n    image: nginx:${TAG:+pinned}\n", environment: environment) == "nginx:pinned")
        #expect(try imageOf("services:\n  web:\n    image: nginx:$${TAG}\n", environment: environment) == "nginx:${TAG}")
        #expect(
            try imageOf("services:\n  web:\n    image: nginx:${MISSING:-${TAG}}\n", environment: environment)
                == "nginx:1.2.3"
        )
    }

    @Test("A variable the file says it needs stops the parse")
    func requiredVariable() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  web:\n    image: nginx:${TAG:?pin the tag}\n")
        }
        #expect(error?.reason == .requiredVariableUnset)
        #expect(error?.problem.contains("pin the tag") == true)
    }

    @Test("An unset variable expands to nothing, and is said out loud")
    func unsetVariableWarns() throws {
        let result = try Fixture.parse("services:\n  web:\n    image: nginx:${TAG}\n")
        #expect(result.file.services["web"]?.image == "nginx:")
        let warning = try #require(result.interpolationWarnings.first)
        #expect(warning.variable == "TAG")
        #expect(warning.path == "services.web.image")
    }

    @Test("The shell wins over the .env file")
    func dotEnvPrecedence() throws {
        let yaml = "services:\n  web:\n    image: nginx:${TAG}\n"
        #expect(try imageOf(yaml, dotEnv: "TAG=from-dotenv\n") == "nginx:from-dotenv")
        #expect(try imageOf(yaml, environment: ["TAG": "from-shell"], dotEnv: "TAG=from-dotenv\n") == "nginx:from-shell")
    }

    @Test("env_file is read at parse time, and the inline block wins")
    func envFileMerging() throws {
        let result = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                env_file: ./api.env
                environment:
                  MODE: inline
            """,
            files: ["/project/api.env": "MODE=file\nQUIET='yes'\n# a comment\nTOKEN=abc # trailing\n"]
        )
        let web = try #require(result.file.services["web"])
        #expect(web.environment["MODE"] == "inline")
        #expect(web.environment["QUIET"] == "yes")
        #expect(web.environment["TOKEN"] == "abc")
    }

    @Test("An env_file that is not there is an error, unless the file says otherwise")
    func missingEnvFile() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  web:\n    image: nginx\n    env_file: ./nope.env\n")
        }
        #expect(error?.reason == .unreadableFile)

        let optional = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                env_file:
                  - path: ./nope.env
                    required: false
            """
        )
        #expect(optional.file.services["web"]?.environment.isEmpty == true)
    }

    @Test("A bare name in environment takes the value from the shell, or is left out")
    func environmentPassthrough() throws {
        let result = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                environment:
                  - PRESENT
                  - ABSENT
                  - SET=here
            """,
            environment: ["PRESENT": "yes"]
        )
        let web = try #require(result.file.services["web"])
        #expect(web.environment == ["PRESENT": "yes", "SET": "here"])
    }
}

@Suite("The formats compose hides inside strings")
struct EmbeddedValueTests {
    private func ports(_ entry: String) throws -> [Service.Port] {
        let result = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                ports:
                  - "\(entry)"
            """
        )
        return result.file.services["web"]?.ports ?? []
    }

    @Test("Port short forms")
    func portShortForms() throws {
        #expect(try ports("8080:80") == [Service.Port(hostPort: 8080, containerPort: 80)])
        #expect(try ports("8080:80/udp") == [Service.Port(hostPort: 8080, containerPort: 80, networkProtocol: .udp)])
        #expect(try ports("127.0.0.1:8080:80") == [Service.Port(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 80)])
        #expect(try ports("[::1]:8080:80") == [Service.Port(hostIP: "::1", hostPort: 8080, containerPort: 80)])
        #expect(
            try ports("9090-9092:80-82") == [
                Service.Port(hostPort: 9090, containerPort: 80),
                Service.Port(hostPort: 9091, containerPort: 81),
                Service.Port(hostPort: 9092, containerPort: 82),
            ]
        )
    }

    @Test("Ports that cannot mean anything are errors")
    func portErrors() throws {
        #expect(throws: ParseError.self) { try ports("70000:80") }
        #expect(throws: ParseError.self) { try ports("8080:80/sctp") }
        #expect(throws: ParseError.self) { try ports("9090-9092:80") }
        #expect(throws: ParseError.self) { try ports("a:b") }
    }

    @Test("The long port form is the short form with room to breathe")
    func longPortForm() throws {
        let result = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                ports:
                  - target: 80
                    published: "8080"
                    protocol: udp
                    host_ip: 127.0.0.1
            """
        )
        #expect(
            result.file.services["web"]?.ports
                == [Service.Port(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 80, networkProtocol: .udp)]
        )
    }

    @Test("Bind mounts resolve against the file, not the working directory")
    func bindMountPaths() throws {
        let result = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                volumes:
                  - ./site:/usr/share/nginx/html:ro
                  - /etc/hosts:/etc/hosts
                  - type: bind
                    source: ../shared
                    target: /shared
            """
        )
        let mounts = try #require(result.file.services["web"]?.mounts)
        #expect(mounts == [
            Service.Mount(source: .bind("/project/site"), target: "/usr/share/nginx/html", readOnly: true),
            Service.Mount(source: .bind("/etc/hosts"), target: "/etc/hosts"),
            Service.Mount(source: .bind("/shared"), target: "/shared"),
        ])
    }

    @Test("A command written as a string is split the way a shell would split it")
    func commandForms() throws {
        let result = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                command: sh -c "echo hello world"
            """
        )
        #expect(result.file.services["web"]?.command == ["sh", "-c", "echo hello world"])
    }

    @Test("Memory sizes carry units")
    func memorySizes() throws {
        func memory(_ text: String) throws -> UInt64? {
            try Fixture.parse(
                """
                services:
                  web:
                    image: nginx
                    deploy:
                      resources:
                        limits:
                          memory: \(text)
                """
            ).file.services["web"]?.resources?.memoryBytes
        }
        #expect(try memory("512m") == 512 << 20)
        #expect(try memory("1g") == 1 << 30)
        #expect(try memory("1.5g") == UInt64(1.5 * Double(1 << 30)))
        #expect(try memory("2048") == 2048)
        #expect(throws: ParseError.self) { try memory("plenty") }
    }
}
