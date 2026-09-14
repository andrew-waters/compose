import ComposeModel
import ComposeParser
import ComposePlanner
import Testing

@Suite("Ordering")
struct DependencyGraphTests {
    @Test("Dependencies start before the services that depend on them")
    func startOrder() throws {
        let graph = try DependencyGraph(services: try Sample.file(Sample.chain).services)
        #expect(graph.startOrder == ["db", "api", "web"])
        #expect(graph.stopOrder == ["web", "api", "db"])
    }

    @Test("Services with no relationship keep a stable order")
    func stableOrder() throws {
        let file = try Sample.file(
            """
            services:
              zebra:
                image: a
              alpha:
                image: b
              mongoose:
                image: c
            """
        )
        #expect(try DependencyGraph(services: file.services).startOrder == ["alpha", "mongoose", "zebra"])
    }

    @Test("A cycle is refused, and named")
    func cycle() throws {
        let file = try Sample.file(
            """
            services:
              a:
                image: a
                depends_on: [b]
              b:
                image: b
                depends_on: [c]
              c:
                image: c
                depends_on: [a]
            """
        )
        let error = #expect(throws: PlanError.self) { try DependencyGraph(services: file.services) }
        guard case .dependencyCycle(let path) = try #require(error) else {
            Issue.record("expected a cycle")
            return
        }
        #expect(path.first == path.last)
        #expect(Set(path) == ["a", "b", "c"])
    }
}

@Suite("Bringing a project up")
struct UpTests {
    @Test("From nothing: network, image, container, start, in dependency order")
    func fromNothing() throws {
        let file = try Sample.file(Sample.chain)
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState())

        #expect(plan.operations.map(\.summary) == [
            "create network shop_default",
            "pull postgres:16",
            "create container shop-db",
            "start shop-db",
            "pull api:1",
            "create container shop-api",
            "start shop-api",
            "pull nginx",
            "create container shop-web",
            "start shop-web",
        ])
        #expect(plan.decisions.map(\.action) == [.create, .create, .create])
    }

    @Test("A second up over an unchanged project does nothing at all")
    func secondUpIsEmpty() throws {
        let file = try Sample.file(Sample.chain)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "api", in: file),
                try Sample.container(service: "web", in: file),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["postgres:16", "api:1", "nginx:latest"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.isEmpty)
        #expect(plan.decisions.allSatisfy { $0.action == .unchanged })
    }

    @Test("A stopped container is started, not recreated")
    func stoppedContainerIsStarted() throws {
        let file = try Sample.file(Sample.chain)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file, running: false),
                try Sample.container(service: "api", in: file),
                try Sample.container(service: "web", in: file),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["postgres:16", "api:1", "nginx"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == ["start shop-db"])
    }

    @Test("A service whose definition moved on is recreated, because a container cannot change")
    func changedServiceIsRecreated() throws {
        let file = try Sample.file(Sample.chain)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file, hash: "an-older-hash"),
                try Sample.container(service: "api", in: file),
                try Sample.container(service: "web", in: file),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["postgres:16", "api:1", "nginx"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == [
            "stop shop-db",
            "remove shop-db",
            "create container shop-db",
            "start shop-db",
        ])
        #expect(plan.decisions.first { $0.service == "db" }?.action == .recreate)
    }

    @Test("Force recreates everything, in dependency order")
    func forceRecreate() throws {
        let file = try Sample.file(Sample.chain)
        let state = CurrentState(
            containers: [try Sample.container(service: "db", in: file)],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["postgres:16", "api:1", "nginx"]
        )
        let plan = try Planner.up(
            file: file,
            project: Sample.project,
            state: state,
            options: UpOptions(forceRecreate: true)
        )
        #expect(Array(plan.operations.map(\.summary).prefix(4)) == [
            "stop shop-db",
            "remove shop-db",
            "create container shop-db",
            "start shop-db",
        ])
    }

    @Test("A container left over from a service the file dropped is removed first")
    func orphansGoFirst() throws {
        let previous = try Sample.file(Sample.chain)
        let file = try Sample.file(
            """
            services:
              db:
                image: postgres:16
            """
        )
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: previous),
                try Sample.container(service: "web", in: previous, publishedHostPorts: [8080]),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["postgres:16"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == ["stop shop-web", "remove shop-web"])
        #expect(plan.decisions.last?.action == .remove)

        let kept = try Planner.up(
            file: file,
            project: Sample.project,
            state: state,
            options: UpOptions(removeOrphans: false)
        )
        #expect(kept.isEmpty)
    }

    @Test("A service that builds is built rather than pulled")
    func buildsRatherThanPulls() throws {
        let file = try Sample.file(
            """
            services:
              api:
                build: ./api
            """
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState())
        #expect(plan.operations.map(\.summary) == [
            "create network shop_default",
            "build shop-api:latest from /project/api",
            "create container shop-api",
            "start shop-api",
        ])
    }

    @Test("An image already here is not pulled again, unless asked for")
    func pullPolicy() throws {
        let file = try Sample.file("services:\n  web:\n    image: nginx\n")
        let present = CurrentState(images: ["nginx:latest"])
        let plan = try Planner.up(file: file, project: Sample.project, state: present)
        #expect(!plan.operations.contains { $0.summary.hasPrefix("pull") })

        let always = try Planner.up(
            file: file,
            project: Sample.project,
            state: present,
            options: UpOptions(pullPolicy: .always)
        )
        #expect(always.operations.contains { $0.summary == "pull nginx" })
    }

    @Test("A created container carries the project labels and its own")
    func createCarriesLabels() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
                labels:
                  com.example.role: front
                environment:
                  B: two
                  A: one
                ports:
                  - "8080:80"
            """
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState())
        let create = try #require(
            plan.operations.compactMap { operation -> CreateOperation? in
                guard case .createContainer(let create) = operation else { return nil }
                return create
            }.first
        )
        #expect(create.containerName == "shop-web")
        #expect(create.networkName == "shop_default")
        #expect(create.labels[ProjectIdentity.projectLabel] == "shop")
        #expect(create.labels[ProjectIdentity.serviceLabel] == "web")
        #expect(create.labels[ProjectIdentity.hashLabel]?.count == 64)
        #expect(create.labels["com.example.role"] == "front")
        #expect(create.environment == ["A=one", "B=two"])
        #expect(create.ports == [CreateOperation.Port(hostPort: 8080, containerPort: 80, networkProtocol: "tcp")])
    }
}

@Suite("Refusing to make a plan")
struct PlanRefusalTests {
    @Test("Two services cannot publish the same host port")
    func portConflictWithinTheFile() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
                ports: ["8080:80"]
              admin:
                image: admin
                ports: ["8080:81"]
            """
        )
        let error = #expect(throws: PlanError.self) {
            try Planner.up(file: file, project: Sample.project, state: CurrentState())
        }
        guard case .portConflict(let port, _, let heldBy) = try #require(error) else {
            Issue.record("expected a port conflict")
            return
        }
        #expect(port == 8080)
        #expect(heldBy.contains("service"))
    }

    @Test("A port something else already holds fails the whole plan before anything is created")
    func portConflictWithTheHost() throws {
        let file = try Sample.file("services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n")
        let state = CurrentState(
            containers: [ContainerState(name: "someone-elses", publishedHostPorts: [8080])]
        )
        let error = #expect(throws: PlanError.self) {
            try Planner.up(file: file, project: Sample.project, state: state)
        }
        #expect(error?.description.contains("someone-elses") == true)
    }

    @Test("A port a container of this project already holds is not a conflict with itself")
    func portHeldByOwnContainer() throws {
        let file = try Sample.file("services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n")
        let unchanged = CurrentState(
            containers: [try Sample.container(service: "web", in: file, publishedHostPorts: [8080])],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["nginx"]
        )
        #expect(try Planner.up(file: file, project: Sample.project, state: unchanged).isEmpty)

        // The same port, on a container this plan is about to remove and recreate.
        let changed = CurrentState(
            containers: [
                try Sample.container(service: "web", in: file, hash: "older", publishedHostPorts: [8080])
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["nginx"]
        )
        #expect(try Planner.up(file: file, project: Sample.project, state: changed).operations.count == 4)
    }

    @Test("Two services cannot want the same container name")
    func duplicateContainerName() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
                container_name: shared
              admin:
                image: admin
                container_name: shared
            """
        )
        let error = #expect(throws: PlanError.self) {
            try Planner.up(file: file, project: Sample.project, state: CurrentState())
        }
        #expect(error?.description.contains("shared") == true)
    }

    @Test("An external network has to be there already")
    func missingExternalNetwork() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
                networks: [shared]
            networks:
              shared:
                external: true
            """
        )
        let error = #expect(throws: PlanError.self) {
            try Planner.up(file: file, project: Sample.project, state: CurrentState())
        }
        #expect(error?.description.contains("shared") == true)

        let present = CurrentState(networks: [NetworkState(name: "shared")])
        let plan = try Planner.up(file: file, project: Sample.project, state: present)
        #expect(!plan.operations.contains { $0.summary.hasPrefix("create network") })
    }
}

@Suite("Taking a project down")
struct DownTests {
    @Test("Stop in reverse order, then remove the network this project created")
    func downOrder() throws {
        let file = try Sample.file(Sample.chain)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "api", in: file),
                try Sample.container(service: "web", in: file, running: false),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())]
        )
        let plan = try Planner.down(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == [
            "remove shop-web",
            "stop shop-api",
            "remove shop-api",
            "stop shop-db",
            "remove shop-db",
            "remove network shop_default",
        ])
    }

    @Test("A network something else is still on is left alone")
    func networkInUseSurvives() throws {
        let file = try Sample.file("services:\n  web:\n    image: nginx\n")
        let state = CurrentState(
            containers: [
                try Sample.container(service: "web", in: file),
                ContainerState(name: "a-guest", isRunning: true, networkName: "shop_default"),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())]
        )
        let plan = try Planner.down(file: file, project: Sample.project, state: state)
        #expect(!plan.operations.contains { $0.summary.hasPrefix("remove network") })
    }

    @Test("Networks this project did not create are never removed")
    func foreignNetworksSurvive() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
                networks: [shared]
            networks:
              shared:
                external: true
            """
        )
        let state = CurrentState(
            containers: [try Sample.container(service: "web", in: file, networkName: "shared")],
            networks: [NetworkState(name: "shared")]
        )
        let plan = try Planner.down(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == ["stop shop-web", "remove shop-web"])
    }
}

@Suite("Project identity")
struct ProjectIdentityTests {
    @Test("The hash follows the service, not the way the file was written")
    func hashIsAboutMeaning() throws {
        let first = try Sample.file(
            """
            services:
              web:
                image: nginx
                environment:
                  A: one
                  B: two
                ports: ["8080:80"]
            """
        )
        let reordered = try Sample.file(
            """
            services:
              web:
                ports: ["8080:80"]
                environment:
                  B: two
                  A: one
                image: nginx
            """
        )
        let changed = try Sample.file(
            """
            services:
              web:
                image: nginx
                environment:
                  A: one
                  B: three
                ports: ["8080:80"]
            """
        )
        let web = try #require(first.services["web"])
        #expect(ProjectIdentity.hash(of: web) == ProjectIdentity.hash(of: try #require(reordered.services["web"])))
        #expect(ProjectIdentity.hash(of: web) != ProjectIdentity.hash(of: try #require(changed.services["web"])))
    }

    @Test("A project name is settled from the command line, then the file, then the directory")
    func projectNameResolution() throws {
        let named = try Sample.file("name: Shop Front\nservices:\n  web:\n    image: nginx\n")
        #expect(ProjectIdentity.resolve(file: named, projectDirectory: "/tmp/whatever").name == "shopfront")

        let unnamed = try Sample.file("services:\n  web:\n    image: nginx\n")
        #expect(ProjectIdentity.resolve(file: unnamed, projectDirectory: "/tmp/My Project").name == "myproject")
        #expect(
            ProjectIdentity.resolve(explicitName: "override", file: named, projectDirectory: "/tmp/whatever").name
                == "override"
        )
    }

    @Test("Container names follow the project unless the file names one")
    func containerNaming() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
              db:
                image: postgres
                container_name: the-database
            """
        )
        #expect(Sample.project.containerName(for: try #require(file.services["web"])) == "shop-web")
        #expect(Sample.project.containerName(for: try #require(file.services["db"])) == "the-database")
    }
}
