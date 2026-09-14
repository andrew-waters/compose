# container-compose

Compose-style orchestration for [Apple's container](https://github.com/apple/container):
bring a set of services up and down from a single file, on the Linux-containers-as-VMs
stack that ships with macOS, without Docker Desktop.

> **Status: the package works, the front ends do not exist.** The compose model, the parser
> and the planner are written and tested. There is no `container compose` plugin yet, and no
> Compose tab in Orchard. Everything below describes the whole design; the section on
> building says what is actually here.

## Why this exists

Apple has explicitly ruled compose out of `container` upstream. The long-running compose
pull request ([apple/container#239](https://github.com/apple/container/pull/239)) was closed
in April 2026 by a maintainer, with the reasoning that Docker Compose is a free-standing
project whose source is not mingled with the Docker engine or CLI, and that container's
maintainers are focused on core functionality and on supporting plugins for ecosystem
integration.

The usual shortcut is closed too. What `podman compose` does, point `DOCKER_HOST` at a
translating socket and shell out to real `docker-compose`, needs a Docker-compatible API
that container does not have.

So compose on this stack has to be built from scratch, outside the project, by someone who
wants it. That is what this is.

## What it will be

Three pieces, sharing one implementation:

- **A Swift package.** The compose model, YAML parsing, a dependency graph, and a planner
  that turns a compose file plus the current state of the world into an ordered list of
  operations. Pure logic: no subprocesses, no XPC, testable without a running daemon.
- **A `container compose` plugin.** A thin binary over that package, installed into
  container's plugin directory, so `container compose up` works from the terminal.
- **A tab in [Orchard](https://github.com/andrew-waters/orchard).** Orchard links the
  package directly and executes plans over the same XPC path it already uses to create
  containers and networks, so the GUI never shells out and never depends on the plugin
  being installed.

The planner being a pure function is the reason for this shape. Ordering and reconciliation
are where compose tools get subtly wrong, and both are testable here without starting a
single container.

## Scope

The dividing line for v1 is what container's own create surface can already express.

**Supported:** `image`, `build`, `container_name`, `command`, `environment`, `env_file`,
`working_dir`, `ports`, bind `volumes`, `labels`, `networks`, `deploy.resources`, and
`depends_on` in its list form.

**Not yet:** `entrypoint`, named `volumes`, attaching to multiple networks, `profiles`,
`healthcheck`, and `depends_on` with conditions.

**Not possible today:** `restart`, `user`, `cap_add`, `devices`, `tmpfs`, `ulimits`,
`secrets`, `configs`, `extra_hosts`. These need runtime support container does not have.
Restart policy is tracked upstream at
[#2142](https://github.com/apple/container/issues/2142), health at
[#1502](https://github.com/apple/container/issues/1502).

Unsupported keys are never silently ignored. Quietly dropping `restart: always` would leave
someone believing their database comes back after a crash. The plugin refuses a file it
cannot honour, naming the key, the service and the line. Orchard lists what it would ignore,
lets you decide, and keeps showing it on the project afterwards.

One limitation worth stating up front: without health reporting in the runtime, `up` starts
dependencies before dependents but does not wait for them to become ready.

## Commands

`up` and `down`, matching compose. The previous Go implementation used `start` and `stop`;
those do not carry over.

## Relationship to container-compose/cli

[`container-compose/cli`](https://github.com/container-compose/cli) is an earlier Go
implementation that wraps the `container` CLI. It is superseded by this repository. Go
cannot be linked into a native macOS app, and the whole point of this design is that the
planning logic is shared between the terminal and the GUI rather than reimplemented.

## Building

```
swift build
swift test
```

Three library targets, and nothing that executes anything:

- `ComposeModel`, the spec types, plus the table of which compose keys are honoured, deferred
  or impossible, with a severity on each.
- `ComposeParser`, YAML to model: interpolation, `.env` and `env_file`, short and long forms,
  and a line and column on every error.
- `ComposePlanner`, the dependency graph, project identity and hashing, and the planner
  itself, which takes a parsed file and a snapshot of what exists and returns an ordered list
  of operations.

[Yams](https://github.com/jpsim/Yams) is the only dependency, and deliberately the only one.
It is the YAML parser `apple/container` already uses, so linking this package into Orchard
adds nothing to Orchard's dependency graph. It also reports a line and column for every node,
which is what lets a refusal name the line it is refusing.

## Requirements

- Apple silicon Mac running macOS 26
- [apple/container](https://github.com/apple/container) 1.4.1 or later

## Licence

MIT.
