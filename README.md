# Compose (for Apple Containers)

Container compose is a plugin for [apple/container](https://github.com/apple/container) that
brings Docker Compose ergonomics to Apple's container runtime.

Unlike earlier community efforts, which tend to be standalone binaries, this is an actual
_plugin_, installed into the `container` CLI, so the commands are:

```
container compose up
container compose down
```

It runs standalone on the CLI, and the same package backs the Compose tab in the
[Orchard](https://github.com/andrew-waters/orchard) app for containers, so a project brought
up in the terminal and one brought up in the app are the same project.

I would also encourage the community to rally around a single solution, contribute to it to
bring it up to spec with all features missing from Docker and for other UIs to build on so
that efforts are centralised and consistent rather than a fragmented ecosystem.

## Why this exists

Apple has explicitly ruled compose out of `container` upstream. The long-running compose
pull request ([apple/container#239](https://github.com/apple/container/pull/239)) was closed
in April 2026 by a maintainer, with the reasoning that Docker Compose is a free-standing
project whose source is not mingled with the Docker engine or CLI, and that container's
maintainers are focused on core functionality and on supporting plugins for ecosystem
integration.

So compose on this stack has to be built from scratch, outside the project, by someone who
wants it. That is what this is.

## How it fits together

Three pieces, sharing one implementation:

- **A Swift package.** The compose model, YAML parsing, a dependency graph, and a planner
  that turns a compose file plus the current state of the world into an ordered list of
  operations. Pure logic: no subprocesses, no XPC, testable without a running daemon.
- **A `container compose` plugin.** A thin binary over that package, installed into
  container's plugin directory, so `container compose up` works from the terminal.
- **A Compose tab in [Orchard](https://github.com/andrew-waters/orchard).** Orchard links
  this package over SwiftPM and executes plans over the same XPC path it already uses to
  create containers and networks, so the GUI never shells out and does not need the plugin
  installed at all.

The planner being a pure function is the reason for this shape. Ordering and reconciliation
are where compose tools get subtly wrong, and both are testable here without starting a
single container.

## Scope

The dividing line is what container's own create surface can already express.

**Supported:** `image`, `build`, `container_name`, `command`, `environment`, `env_file`,
`working_dir`, `ports`, `volumes` (bind, named and anonymous) and the top-level `volumes`,
`labels`, `networks`, `dns`, `dns_search`, `dns_opt`, `deploy.resources`, `depends_on` in its
list form, `platform`, and the `post_start` and `pre_stop` lifecycle hooks.

`platform` takes `os/arch` or `os/arch/variant`, such as `linux/amd64`. The image is pulled,
built and run as that platform; on Apple silicon a `linux/amd64` service runs under Rosetta,
which has to be installed (`softwareupdate --install-rosetta`). A service without it runs as
the host's platform, as before.

A named volume is created by `up` when it is missing, as `<project>_<key>` unless the file gives
it a `name:`, and labelled with the project. An `external: true` volume is never created, and
`up` stops before doing anything if one a service mounts does not exist. An anonymous volume
(`- /var/lib/data`) is named after the project, the service and its path, so a recreated
container finds the same data; unlike Docker, an `up` after a plain `down` finds it too.
`down` leaves every volume in place; `down -v` removes the ones this project created, except one
a container outside the project still mounts. Volumes
use container's `local` driver; a file naming another is told so. A service that mounts a volume
is recreated once on the first `up` after upgrading, which is what attaches it.

A volume here is an ext4 filesystem, not a directory, so it has a `lost+found` at its root.
An image that refuses a data directory that is not empty needs pointing one level down: for
`postgres`, set `PGDATA: /var/lib/postgresql/data/pgdata` and mount the volume at
`/var/lib/postgresql/data`, as with `container run`.

That disk is attached to one container at a time, so a volume can be mounted only once:
two services sharing one, or a service mounting one a running container elsewhere already
has, stops `up` before it does anything. That includes read-only mounts. Share files between
services with a bind mount instead.

Hooks run inside the service's container with their `command`, `environment`, `working_dir`
and `user`; anything a hook leaves out is what the container's own process runs with. `up`
runs each `post_start` hook, in order, after it starts a container. `down`, and `up` when it
recreates a container, run each `pre_stop` hook before stopping a running one; a container
that is already stopped skips them. A hook's output is shown as it runs.

A `post_start` that fails, by exiting non-zero or by not starting at all, fails `up` with its
output and exit code and leaves the container in place. `up` keeps a running container, so it
will not run the hook again: run `down` and then `up` once it is fixed. A failing `pre_stop`
is reported and the stop goes ahead. Changing a service's hooks recreates its container on
the next `up`.

`privileged: false` on a hook is accepted, and `privileged: true` is refused: a process run in
a container has no privileged mode. As everywhere in a compose file, `$VAR` in a hook is
filled in from your shell when the file is read; write `$$VAR` for the container's own
variable. Orchard does not run hooks.

**Not yet:** `entrypoint`, attaching to multiple networks, `profiles`,
`include`, `healthcheck`, and `depends_on` with conditions. `pull_policy` is read but not
honoured: an image is pulled when it is missing.

**Not possible today:** `restart`, `user`, `cap_add`, `devices`, `tmpfs`, `ulimits`,
`secrets`, `configs`, `extra_hosts`, `privileged`, `network_mode`. These need runtime support
container does not have. Restart policy is tracked upstream at
[#2142](https://github.com/apple/container/issues/2142), health at
[#1502](https://github.com/apple/container/issues/1502).

Unsupported keys are never silently ignored. Quietly dropping `restart: always` would leave
someone believing their database comes back after a crash. The plugin refuses a file it
cannot honour, naming the key, the service and the line. Orchard lists what it would ignore,
lets you decide, and keeps showing it on the project afterwards.

Two limitations worth stating up front. Without health reporting in the runtime, `up` starts
dependencies before dependents but does not wait for them to become ready. And a service
does not answer to its service name: hostnames have to be unique across every container on
the machine, so a container is reachable as `<project>-<service>` rather than as `db`.
Compose's own naming needs per-network namespacing, which is
[apple/container#1809](https://github.com/apple/container/issues/1809).

A container is registered in container's DNS only under a qualified name. A `container_name`
with a dot in it, such as `postgres.stack`, is used as it is. Any other name is registered as
`<name>.<domain>` when a default domain is set in `~/.config/container/config.toml`, and is
not resolvable by name at all when none is:

```toml
[dns]
domain = "stack"
```

The domain has to exist (`sudo container system dns create stack`) and container has to be
restarted to read it. The older `com.apple.container.defaults` setting is ignored by container
1.x ([apple/container#1794](https://github.com/apple/container/issues/1794)). Even once a name
resolves, traffic only flows between containers on the same network: a name looked up from
another network resolves, but the connection gets no answer.

Containers created by an earlier version of the plugin were registered under a bare name and
cannot be resolved. The hostname is not part of the service hash, so `up` does not replace them
by itself; recreate them once with `container compose up --force-recreate`, or `down` then `up`.

## Using it

Every release ships the plugin directory built and packaged exactly as it is installed, so
unpacking it into container's plugin directory is the whole install:

```
tar -xzf compose-<version>-macos-arm64.tar.gz
sudo mkdir -p /usr/local/libexec/container-plugins
sudo cp -R compose /usr/local/libexec/container-plugins/
```

Or build it yourself:

```
make build
sudo make install
```

The plugin directory is root owned, which is what the `sudo` is for. The container installer
wipes that directory on every upgrade
([apple/container#1617](https://github.com/apple/container/issues/1617)), so expect to
install again after updating container.

Then, in a directory with a `compose.yaml`:

```
container compose up                 # create and start everything, in dependency order
container compose up --dry-run       # work out the plan, print it, change nothing
container compose down               # stop and remove it all again
```

`up` and `down`, matching compose. There are no other verbs yet: container's own `ls`,
`logs` and `exec` cover the rest meanwhile.

Both verbs take `-f` to point at a file elsewhere, `-p` to name the project (it otherwise
comes from the file's `name`, then from the directory), and `--dry-run`. `up` also takes
`--force-recreate`, `--pull missing|always|never` and `--keep-orphans`; `down` takes
`--keep-networks`, and `-v` / `--volumes` to remove the project's volumes too.

Running `up` twice is the interesting case. The second run compares each service against the
hash stamped on the container it produced, and creates, starts, leaves alone, recreates or
removes each one accordingly. Containers are the only record: there is no state file.

### What it refuses

The plugin will not run a file it cannot honour. It names the key, the service and the line,
and creates nothing:

```
error: compose.yaml asks for 2 things this cannot do
  8:14: `restart` in service `db` is not honoured: container has no restart policy; a
        container that exits stays exited
  15:11: `user` in service `api` is not honoured: the create surface cannot set the process user
error: nothing was created.
```

Keys that cost nothing to ignore, such as an obsolete `version`, are printed as notes and
stepped over. The difference is a severity carried per key, not a judgement made at the
point of refusal.

## Using it from Orchard

[Orchard](https://github.com/andrew-waters/orchard) is a native macOS app for managing
containers, machines and local AI models on `apple/container`, and its Compose tab is built
on this package:

```
brew install orchard
```

It reads a compose file, shows what it found and what it would ignore before anything runs,
and then executes the same plans this plugin does. The plugin does not have to be installed
for that. Source and releases are at
[andrew-waters/orchard](https://github.com/andrew-waters/orchard).

## Building

```
swift build
swift test
```

Three library targets, none of which executes anything:

- `ComposeModel`, the spec types, plus the table of which compose keys are honoured,
  deferred or impossible, with a severity on each.
- `ComposeParser`, YAML to model: interpolation, `.env` and `env_file`, short and long
  forms, and a line and column on every error.
- `ComposePlanner`, the dependency graph, project identity and hashing, and the planner
  itself, which takes a parsed file and a snapshot of what exists and returns an ordered
  list of operations.

Plus one executable target, `compose`, which is the plugin: it parses, plans, prints, and
executes the plan. It is the only target that knows a runtime exists.

[Yams](https://github.com/jpsim/Yams) is the libraries' only dependency, and deliberately
so. It is the YAML parser `apple/container` already uses, so linking this package adds
nothing to the dependency graph. It also reports a line and column for every node, which is
what lets a refusal name the line it is refusing.

The plugin adds `apple/container` itself and `swift-argument-parser`, both kept inside the
executable target: a package that makes plans has no business linking a client for the thing
that carries them out. One operation, `build`, is not carried out in process. Starting the
BuildKit builder, dialling it and unpacking the result are all things the `container` CLI
already does, so the plugin shells out to `container build` rather than reimplementing the
hard part. Orchard does the same for the same reason.

## Releasing

A release is an annotated tag on `main`, such as `0.5.0`, whose first line is the release title.
Pushing it makes CI build, package and publish the release with notes generated from the merged
pull requests; nothing is released by merging. The steps are in
[.claude/skills/release/SKILL.md](.claude/skills/release/SKILL.md), and how work is planned and
reviewed here is in [CLAUDE.md](CLAUDE.md) and [STANDARDS.md](STANDARDS.md).

## Requirements

- Apple silicon Mac running macOS 26
- [apple/container](https://github.com/apple/container) 1.4.1 or later

## Licence

MIT.
