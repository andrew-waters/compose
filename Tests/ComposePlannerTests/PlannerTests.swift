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
        let create = try #require(plan.createOperations.first)
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

@Suite("Turning a service into a container")
struct CreateOperationTests {
    @Test("An image's entrypoint survives a command override")
    func processArguments() {
        #expect(
            Planner.processArguments(imageEntrypoint: ["/bin/tini", "--"], imageCmd: ["nginx"], command: [])
                == ["/bin/tini", "--", "nginx"]
        )
        #expect(
            Planner.processArguments(
                imageEntrypoint: ["/bin/tini", "--"],
                imageCmd: ["nginx"],
                command: ["sleep", "1"]
            ) == ["/bin/tini", "--", "sleep", "1"]
        )
        #expect(Planner.processArguments(imageEntrypoint: nil, imageCmd: ["nginx"], command: []) == ["nginx"])
        #expect(Planner.processArguments(imageEntrypoint: nil, imageCmd: ["nginx"], command: ["sleep"]) == ["sleep"])
        #expect(Planner.processArguments(imageEntrypoint: nil, imageCmd: nil, command: []).isEmpty)
    }

    @Test("The networks a plan will create are the ones a front end can name in advance")
    func networkNames() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
              db:
                image: postgres
                networks: [backend]
              shared:
                image: alpine
                networks: [outside]
            networks:
              backend: {}
              outside:
                external: true
            """
        )
        let names = Planner.networkNames(in: file, project: Sample.project)
        #expect(names["web"] == "shop_default")
        #expect(names["db"] == "shop_backend")
        // An external network keeps the name it already has, unprefixed.
        #expect(names["shared"] == "outside")

        // And they are the same names the plan actually uses.
        let plan = try Planner.up(
            file: file,
            project: Sample.project,
            state: CurrentState(networks: [NetworkState(name: "outside")])
        )
        #expect(Set(plan.createOperations.map(\.networkName)) == Set(names.values.compactMap { $0 }))
    }

    @Test("An image reference is compared in the form the runtime keeps it in")
    func imageReferenceNormalisation() {
        #expect(Planner.normalisedImageReference("alpine") == "docker.io/library/alpine:latest")
        #expect(Planner.normalisedImageReference("alpine:3.22") == "docker.io/library/alpine:3.22")
        #expect(Planner.normalisedImageReference("jrei/systemd-ubuntu") == "docker.io/jrei/systemd-ubuntu:latest")
        #expect(Planner.normalisedImageReference("ghcr.io/foo/bar") == "ghcr.io/foo/bar:latest")
        #expect(Planner.normalisedImageReference("localhost:5000/thing") == "localhost:5000/thing:latest")
        #expect(
            Planner.normalisedImageReference("docker.io/library/nginx:latest") == "docker.io/library/nginx:latest"
        )
        #expect(
            Planner.normalisedImageReference("alpine@sha256:abc") == "docker.io/library/alpine@sha256:abc"
        )
    }

    @Test("An image the runtime already has under its long name is not pulled again")
    func longFormImagesAreRecognised() throws {
        let file = try Sample.file("services:\n  web:\n    image: alpine\n    command: sleep 1\n")
        let state = CurrentState(images: ["docker.io/library/alpine:latest"])
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(!plan.operations.contains { $0.summary.hasPrefix("pull") })
    }

    @Test("A port published to one interface stays on that interface")
    func hostAddressSurvives() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
                ports:
                  - "127.0.0.1:8080:80"
                  - "9090:90/udp"
            """
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState())
        let create = try #require(plan.createOperations.first)
        #expect(create.ports == [
            CreateOperation.Port(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, networkProtocol: "tcp"),
            CreateOperation.Port(hostPort: 9090, containerPort: 90, networkProtocol: "udp"),
        ])
    }

    @Test("Mounts and limits arrive in the shape the create call wants")
    func mountsAndLimits() throws {
        let file = try Sample.file(
            """
            services:
              db:
                image: postgres:16
                volumes:
                  - ./data:/var/lib/postgresql/data
                  - ./seed:/seed:ro
                working_dir: /srv
                deploy:
                  resources:
                    limits:
                      cpus: "0.5"
                      memory: 512m
            """
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState())
        let create = try #require(plan.createOperations.first)
        #expect(create.mounts == [
            CreateOperation.Mount(source: .bind("/project/data"), containerPath: "/var/lib/postgresql/data", readOnly: false),
            CreateOperation.Mount(source: .bind("/project/seed"), containerPath: "/seed", readOnly: true),
        ])
        #expect(create.workingDirectory == "/srv")
        #expect(create.cpus == 0.5)
        #expect(create.memoryBytes == 512 << 20)
    }

    @Test("A service's platform reaches its pull, its build and its container")
    func platformCarried() throws {
        let file = try Sample.file(
            """
            services:
              web:
                image: nginx
                platform: linux/amd64
              api:
                build: ./api
                platform: linux/amd64
            """
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState())
        let project = Sample.project
        #expect(plan.operations.contains(
            .pullImage(PullOperation(service: "web", imageReference: "nginx", platform: "linux/amd64"))
        ))
        #expect(plan.operations.contains(
            .buildImage(BuildOperation(
                service: "api",
                imageReference: "shop-api:latest",
                context: "/project/api",
                platform: "linux/amd64"
            ))
        ))
        let web = try #require(plan.createOperations.first { $0.service == "web" })
        let webService = try #require(file.services["web"])
        #expect(web == CreateOperation(
            service: "web",
            containerName: "shop-web",
            imageReference: "nginx",
            environment: [],
            command: [],
            workingDirectory: nil,
            mounts: [],
            ports: [],
            networkName: "shop_default",
            labels: project.labels(for: webService),
            cpus: nil,
            memoryBytes: nil,
            platform: "linux/amd64"
        ))
    }

    @Test("A service with no platform leaves the choice to the runtime")
    func noPlatform() throws {
        let file = try Sample.file("services:\n  web:\n    image: nginx\n")
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState())
        #expect(plan.operations.contains(.pullImage(PullOperation(service: "web", imageReference: "nginx"))))
        #expect(plan.createOperations.first?.platform == nil)
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
        guard case .duplicatePort(let port, let services) = try #require(error) else {
            Issue.record("expected a duplicate port")
            return
        }
        #expect(port == 8080)
        #expect(services == ["admin", "web"])
        #expect(error?.description == "services `admin` and `web` both publish host port 8080")
    }

    @Test("A port something else already holds fails the whole plan before anything is created")
    func portConflictWithTheHost() throws {
        let file = try Sample.file("services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n")
        let state = CurrentState(
            containers: [ContainerState(name: "someone-elses", isRunning: true, publishedHostPorts: [8080])]
        )
        let error = #expect(throws: PlanError.self) {
            try Planner.up(file: file, project: Sample.project, state: state)
        }
        #expect(error?.description.contains("someone-elses") == true)
    }

    @Test("A stopped container is not holding the port it was configured with")
    func stoppedContainersDoNotHoldPorts() throws {
        let file = try Sample.file("services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n")
        let state = CurrentState(
            containers: [ContainerState(name: "someone-elses", isRunning: false, publishedHostPorts: [8080])],
            images: ["nginx"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.contains { $0.summary == "create container shop-web" })
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

@Suite("Lifecycle hooks")
struct HookPlanningTests {
    static let hooked = """
        services:
          web:
            image: nginx
            depends_on: [db]
            post_start:
              - command: ./one.sh
                environment: {B: "2", A: "1"}
                working_dir: /srv
                user: www-data
              - command: ./two.sh
            pre_stop:
              - command: ./bye.sh
                environment: [MODE=stop]
          db:
            image: postgres:16
        """

    static let postStart = [
        HookOperation(
            service: "web",
            containerName: "shop-web",
            phase: .postStart,
            index: 0,
            command: ["./one.sh"],
            environment: ["A=1", "B=2"],
            workingDirectory: "/srv",
            user: "www-data",
            failureIsFatal: true
        ),
        HookOperation(
            service: "web",
            containerName: "shop-web",
            phase: .postStart,
            index: 1,
            command: ["./two.sh"],
            failureIsFatal: true
        ),
    ]

    static let preStop = [
        HookOperation(
            service: "web",
            containerName: "shop-web",
            phase: .preStop,
            index: 0,
            command: ["./bye.sh"],
            environment: ["MODE=stop"],
            failureIsFatal: false
        ),
    ]

    @Test("post_start hooks run in order right after their container starts")
    func postStartFollowsStart() throws {
        let file = try Sample.file(Self.hooked)
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState(images: ["nginx", "postgres:16"]))
        #expect(plan.operations.map(\.summary) == [
            "create network shop_default",
            "create container shop-db",
            "start shop-db",
            "create container shop-web",
            "start shop-web",
            "run post_start[0] in shop-web",
            "run post_start[1] in shop-web",
        ])
        #expect(plan.hookOperations == Self.postStart)
    }

    @Test("A stopped container that is started again runs its post_start hooks")
    func restartedContainerRunsPostStart() throws {
        let file = try Sample.file(Self.hooked)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "web", in: file, running: false),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["nginx", "postgres:16"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == [
            "start shop-web",
            "run post_start[0] in shop-web",
            "run post_start[1] in shop-web",
        ])
        #expect(plan.hookOperations == Self.postStart)
    }

    @Test("A running container that has not changed runs no hooks")
    func unchangedRunsNothing() throws {
        let file = try Sample.file(Self.hooked)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "web", in: file),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["nginx", "postgres:16"]
        )
        #expect(try Planner.up(file: file, project: Sample.project, state: state).operations.isEmpty)
    }

    @Test("Recreating runs pre_stop on the old container and post_start on the new one")
    func recreateRunsBoth() throws {
        let file = try Sample.file(Self.hooked)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "web", in: file, hash: "an-older-hash"),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["nginx", "postgres:16"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == [
            "run pre_stop[0] in shop-web",
            "stop shop-web",
            "remove shop-web",
            "create container shop-web",
            "start shop-web",
            "run post_start[0] in shop-web",
            "run post_start[1] in shop-web",
        ])
        #expect(plan.hookOperations == Self.preStop + Self.postStart)
    }

    @Test("Recreating a container that is already stopped skips its pre_stop hooks")
    func recreateStoppedSkipsPreStop() throws {
        let file = try Sample.file(Self.hooked)
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "web", in: file, running: false, hash: "an-older-hash"),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["nginx", "postgres:16"]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == [
            "remove shop-web",
            "create container shop-web",
            "start shop-web",
            "run post_start[0] in shop-web",
            "run post_start[1] in shop-web",
        ])
        #expect(plan.hookOperations == Self.postStart)
    }

    @Test("down runs pre_stop before stopping, and skips it for a container already stopped")
    func downRunsPreStop() throws {
        let file = try Sample.file(Self.hooked)
        let running = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "web", in: file),
            ]
        )
        let plan = try Planner.down(file: file, project: Sample.project, state: running)
        #expect(plan.operations.map(\.summary) == [
            "run pre_stop[0] in shop-web",
            "stop shop-web",
            "remove shop-web",
            "stop shop-db",
            "remove shop-db",
        ])
        #expect(plan.hookOperations == Self.preStop)

        let stopped = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file),
                try Sample.container(service: "web", in: file, running: false),
            ]
        )
        let quiet = try Planner.down(file: file, project: Sample.project, state: stopped)
        #expect(quiet.operations.map(\.summary) == [
            "remove shop-web",
            "stop shop-db",
            "remove shop-db",
        ])
        #expect(quiet.hookOperations.isEmpty)
    }

    @Test("A container whose service has left the file runs no hooks on its way out")
    func orphansRunNoHooks() throws {
        let previous = try Sample.file(Self.hooked)
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
                try Sample.container(service: "web", in: previous),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: ["postgres:16"]
        )
        let down = try Planner.down(file: file, project: Sample.project, state: state)
        #expect(down.hookOperations.isEmpty)
        #expect(down.operations.map(\.summary).contains("stop shop-web"))

        let up = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(up.operations.map(\.summary) == ["stop shop-web", "remove shop-web"])
    }

    @Test("A platform changes the hash only when it is set")
    func platformInTheHash() throws {
        let plain = Service(name: "web", image: "nginx")
        #expect(plain.canonicalDescription == "service=web\nimage=nginx")
        let amd64 = Service(name: "web", image: "nginx", platform: "linux/amd64")
        #expect(amd64.canonicalDescription == "service=web\nimage=nginx\nplatform=linux/amd64")
        #expect(ProjectIdentity.hash(of: amd64) != ProjectIdentity.hash(of: plain))
    }

    @Test("Editing a hook changes the hash; a service with none hashes as it always did")
    func hooksInTheHash() throws {
        // Pinned, so a container created before hooks existed is not recreated by the upgrade.
        #expect(Service(name: "db", image: "postgres:16").canonicalDescription == "service=db\nimage=postgres:16")

        var service = Service(name: "web", image: "nginx", postStart: [Service.Hook(command: ["./one.sh"])])
        let before = ProjectIdentity.hash(of: service)
        service.postStart[0].user = "root"
        #expect(ProjectIdentity.hash(of: service) != before)
        service.postStart = []
        #expect(ProjectIdentity.hash(of: service) == ProjectIdentity.hash(of: Service(name: "web", image: "nginx")))

        // The same hook as pre_stop rather than post_start is a different container.
        let asPostStart = Service(name: "web", image: "nginx", postStart: [Service.Hook(command: ["./x.sh"])])
        let asPreStop = Service(name: "web", image: "nginx", preStop: [Service.Hook(command: ["./x.sh"])])
        #expect(ProjectIdentity.hash(of: asPostStart) != ProjectIdentity.hash(of: asPreStop))
    }
}

@Suite("Volumes")
struct VolumePlanningTests {
    /// `db` keeps its data on a named volume and its scratch space on an anonymous one.
    static let database = """
        services:
          db:
            image: postgres:16
            volumes:
              - pgdata:/var/lib/postgresql/data
              - /var/lib/data
        volumes:
          pgdata:
            labels:
              tier: gold
              com.compose.project: someone-else
        """

    /// SHA-256 of `/var/lib/data`, first twelve hex digits. Written out rather than worked out,
    /// so a change to how the name is derived fails here rather than orphaning volumes.
    static let anonymous = "shop_db_94388feac72b"

    static let images = ["postgres:16"]

    @Test("From nothing: network, then volumes with their labels, then the container that mounts them")
    func fromNothing() throws {
        let file = try Sample.file(Self.database)
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState(images: Self.images))

        #expect(Array(plan.operations.prefix(3)) == [
            .createNetwork(NetworkOperation(name: "shop_default", labels: Sample.project.networkLabels())),
            .createVolume(
                VolumeOperation(
                    name: "shop_pgdata",
                    // The project's labels win over the file's, so `down -v` still finds it.
                    labels: ["tier": "gold", "com.compose.project": "shop", "com.compose.volume": "pgdata"]
                )
            ),
            .createVolume(
                VolumeOperation(
                    name: Self.anonymous,
                    labels: [
                        "com.apple.container.resource.anonymous": "",
                        "com.compose.project": "shop",
                        "com.compose.service": "db",
                        "com.compose.volume.target": "/var/lib/data",
                    ]
                )
            ),
        ])
        #expect(plan.operations.map(\.summary).dropFirst(3) == ["create container shop-db", "start shop-db"])
        let create = try #require(plan.createOperations.first)
        #expect(create.mounts == [
            CreateOperation.Mount(
                source: .namedVolume("shop_pgdata"),
                containerPath: "/var/lib/postgresql/data",
                readOnly: false
            ),
            CreateOperation.Mount(source: .anonymousVolume(Self.anonymous), containerPath: "/var/lib/data", readOnly: false),
        ])
    }

    @Test("A recreate keeps both volumes: neither is created again, and the new container mounts the same ones")
    func recreateReusesVolumes() throws {
        let file = try Sample.file(Self.database)
        let state = CurrentState(
            // The old container holds both volumes, which is no clash: it goes before the new one
            // is created.
            containers: [
                try Sample.container(service: "db", in: file, hash: "stale", volumes: ["shop_pgdata", Self.anonymous]),
            ],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: Self.images,
            volumes: [VolumeState(name: "shop_pgdata"), VolumeState(name: Self.anonymous)]
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == [
            "stop shop-db",
            "remove shop-db",
            "create container shop-db",
            "start shop-db",
        ])
        #expect(plan.createOperations.first?.mounts.map(\.source) == [
            .namedVolume("shop_pgdata"),
            .anonymousVolume(Self.anonymous),
        ])
    }

    @Test("A declared volume is created even when no container is, and an anonymous one only when one is")
    func declaredVolumeWithoutCreate() throws {
        let file = try Sample.file(Self.database)
        let state = CurrentState(
            containers: [try Sample.container(service: "db", in: file)],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            images: Self.images
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(plan.operations == [
            .createVolume(
                VolumeOperation(
                    name: "shop_pgdata",
                    labels: ["tier": "gold", "com.compose.project": "shop", "com.compose.volume": "pgdata"]
                )
            ),
        ])
    }

    @Test("`name:` replaces the project prefix, and declared volumes are created in name order")
    func explicitName() throws {
        let file = try Sample.file(
            """
            services:
              app:
                image: app:1
                volumes:
                  - zeta:/z
                  - alpha:/a
            volumes:
              zeta:
                name: archive
              alpha:
            """
        )
        let plan = try Planner.up(file: file, project: Sample.project, state: CurrentState(images: ["app:1"]))
        let volumes = plan.operations.compactMap { operation -> VolumeOperation? in
            guard case .createVolume(let volume) = operation else { return nil }
            return volume
        }
        #expect(volumes == [
            VolumeOperation(name: "archive", labels: ["com.compose.project": "shop", "com.compose.volume": "zeta"]),
            VolumeOperation(name: "shop_alpha", labels: ["com.compose.project": "shop", "com.compose.volume": "alpha"]),
        ])
        #expect(plan.createOperations.first?.mounts.map(\.source) == [.namedVolume("archive"), .namedVolume("shop_alpha")])
    }

    static let external = """
        services:
          app:
            image: app:1
            volumes:
              - shared:/shared:ro
        volumes:
          shared:
            name: team-data
            external: true
        """

    @Test("An external volume that exists is mounted and never created")
    func externalPresent() throws {
        let file = try Sample.file(Self.external)
        let state = CurrentState(images: ["app:1"], volumes: [VolumeState(name: "team-data")])
        let plan = try Planner.up(file: file, project: Sample.project, state: state)
        #expect(!plan.operations.contains { if case .createVolume = $0 { return true } else { return false } })
        #expect(plan.createOperations.first?.mounts == [
            CreateOperation.Mount(source: .namedVolume("team-data"), containerPath: "/shared", readOnly: true),
        ])
    }

    @Test("An external volume that does not exist stops the plan before anything is done")
    func externalMissing() throws {
        let file = try Sample.file(Self.external)
        let error = #expect(throws: PlanError.self) {
            try Planner.up(file: file, project: Sample.project, state: CurrentState(images: ["app:1"]))
        }
        #expect(error == .missingExternalVolume(name: "team-data", service: "app"))
    }

    @Test("A volume mounted twice in the file is refused, read-only or not")
    func sharedVolume() throws {
        let twoServices = try Sample.file(
            """
            services:
              web:
                image: nginx
                volumes: ["assets:/usr/share/nginx/html:ro"]
              build:
                image: builder:1
                volumes: ["assets:/out"]
            volumes:
              assets:
            """
        )
        let across = #expect(throws: PlanError.self) {
            try Planner.up(file: twoServices, project: Sample.project, state: CurrentState())
        }
        #expect(across == .sharedVolume(name: "shop_assets", services: ["build", "web"]))

        let oneService = try Sample.file(
            """
            services:
              web:
                image: nginx
                volumes: ["assets:/a", "assets:/b:ro"]
            volumes:
              assets:
            """
        )
        let within = #expect(throws: PlanError.self) {
            try Planner.up(file: oneService, project: Sample.project, state: CurrentState())
        }
        #expect(within == .sharedVolume(name: "shop_assets", services: ["web"]))
    }

    @Test("A volume a running container outside the service holds is refused; a stopped one is not")
    func volumeHeldElsewhere() throws {
        let file = try Sample.file(Self.external)
        let holder = ContainerState(name: "someone", isRunning: true, volumes: ["team-data"])
        let state = CurrentState(images: ["app:1"], volumes: [VolumeState(name: "team-data")])
        let error = #expect(throws: PlanError.self) {
            try Planner.up(
                file: file,
                project: Sample.project,
                state: CurrentState(containers: [holder], images: state.images, volumes: state.volumes)
            )
        }
        #expect(error == .volumeInUse(name: "team-data", service: "app", heldBy: "container `someone`"))

        let stopped = ContainerState(name: "someone", isRunning: false, volumes: ["team-data"])
        let plan = try Planner.up(
            file: file,
            project: Sample.project,
            state: CurrentState(containers: [stopped], images: state.images, volumes: state.volumes)
        )
        #expect(plan.createOperations.count == 1)
    }

    @Test("down leaves every volume alone unless asked")
    func downKeepsVolumes() throws {
        let file = try Sample.file(Self.database)
        let state = CurrentState(
            containers: [try Sample.container(service: "db", in: file)],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            volumes: [VolumeState(name: "shop_pgdata", labels: ["com.compose.project": "shop"])]
        )
        let plan = try Planner.down(file: file, project: Sample.project, state: state)
        #expect(plan.operations.map(\.summary) == ["stop shop-db", "remove shop-db", "remove network shop_default"])
    }

    @Test("down with removeVolumes removes only this project's volumes, by name, after the networks")
    func downRemovesProjectVolumes() throws {
        let file = try Sample.file(Self.database)
        let anonymousLabels = Sample.project.anonymousVolumeLabels(service: "db", target: "/var/lib/data")
        let state = CurrentState(
            containers: [try Sample.container(service: "db", in: file)],
            networks: [NetworkState(name: "shop_default", labels: Sample.project.networkLabels())],
            volumes: [
                VolumeState(name: "shop_pgdata", labels: ["com.compose.project": "shop", "com.compose.volume": "pgdata"]),
                VolumeState(name: Self.anonymous, labels: anonymousLabels),
                // External, or there before the project: no label, so never removed.
                VolumeState(name: "team-data"),
                VolumeState(name: "other_data", labels: ["com.compose.project": "other"]),
            ]
        )
        let plan = try Planner.down(
            file: file,
            project: Sample.project,
            state: state,
            options: DownOptions(removeVolumes: true)
        )
        #expect(plan.operations == [
            .stopContainer(ContainerReference(containerName: "shop-db", service: "db")),
            .removeContainer(ContainerReference(containerName: "shop-db", service: "db")),
            .removeNetwork(NetworkOperation(name: "shop_default", labels: Sample.project.networkLabels())),
            .removeVolume(VolumeOperation(name: Self.anonymous, labels: anonymousLabels)),
            .removeVolume(
                VolumeOperation(name: "shop_pgdata", labels: ["com.compose.project": "shop", "com.compose.volume": "pgdata"])
            ),
        ])
    }

    @Test("down -v leaves a volume a container outside the project still mounts")
    func downSkipsVolumeInUse() throws {
        let file = try Sample.file(Self.database)
        let labels = ["com.compose.project": "shop", "com.compose.volume": "pgdata"]
        let state = CurrentState(
            containers: [
                try Sample.container(service: "db", in: file, volumes: ["shop_pgdata"]),
                // Stopped, and still enough for the runtime to refuse the delete.
                ContainerState(name: "a-guest", volumes: ["shop_pgdata"]),
            ],
            volumes: [VolumeState(name: "shop_pgdata", labels: labels)]
        )
        let plan = try Planner.down(
            file: file,
            project: Sample.project,
            state: state,
            options: DownOptions(removeNetworks: false, removeVolumes: true)
        )
        #expect(plan.operations.map(\.summary) == ["stop shop-db", "remove shop-db"])
    }

    @Test("A service without volumes hashes as it always did; one with them hashes their mounts")
    func volumesInTheHash() throws {
        #expect(Service(name: "db", image: "postgres:16").canonicalDescription == "service=db\nimage=postgres:16")
        let mounted = Service(
            name: "db",
            image: "postgres:16",
            mounts: [
                Service.Mount(source: .named("pgdata"), target: "/data"),
                Service.Mount(source: .anonymous, target: "/scratch"),
            ]
        )
        #expect(mounted.canonicalDescription == "service=db\nimage=postgres:16\nmount=:/scratch\nmount=pgdata:/data")

        // A volume with a name of its own hashes that name, so renaming it recreates the
        // container onto the new volume.
        let renamed = Service(
            name: "db",
            image: "postgres:16",
            mounts: [Service.Mount(source: .named("pgdata"), target: "/data", hostName: "team-data")]
        )
        #expect(renamed.canonicalDescription == "service=db\nimage=postgres:16\nmount=pgdata[team-data]:/data")
    }

    @Test("Renaming a volume in the file recreates the service that mounts it")
    func renamedVolumeRecreates() throws {
        let before = try Sample.file(Self.external)
        let after = try Sample.file(Self.external.replacingOccurrences(of: "team-data", with: "team-data-2"))
        let state = CurrentState(
            containers: [try Sample.container(service: "app", in: before, volumes: ["team-data"])],
            images: ["app:1"],
            volumes: [VolumeState(name: "team-data"), VolumeState(name: "team-data-2")]
        )
        let plan = try Planner.up(file: after, project: Sample.project, state: state)
        #expect(plan.decisions.map(\.action) == [.recreate])
        #expect(plan.createOperations.first?.mounts.map(\.source) == [.namedVolume("team-data-2")])
    }
}
