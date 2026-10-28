# andrew-waters/compose#19: Create and mount named and anonymous volumes

https://github.com/andrew-waters/compose/issues/19

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 28 Oct 2026

## Description

## What problem are you trying to solve?

Compose files that use named or anonymous volumes lose those mounts. `parseMounts` in `Sources/ComposeParser/ServiceParsing.swift` drops them with a note ("`<name>` is a named volume, and nothing here creates one yet; the mount is dropped"), the top-level `volumes:` is marked deferred in `parseTopLevelVolumes`, and `CreateOperation.Mount` in `Sources/ComposePlanner/Operation.swift` can only describe a host path. Databases are the most common reason a compose file declares volumes, so a `postgres` or `redis` service comes up without its data volume and loses its data when it is recreated.

This is the compose half of andrew-waters/orchard#162. Orchard maps the new mount kinds and operations once this is released (it will bump to the new minor version).

## Proposed solution

These decisions are already agreed with the maintainer.

### Parser and model

- Keep `.named` and `.anonymous` mounts in place of dropping them. A named volume the file does not declare is still refused, as now.
- Top-level `volumes:` is supported: drop the deferred note and update `VolumeSpec`'s doc comment. A `driver` other than `local` gets a cosmetic note, so no key is silently ignored.
- Hash: services that mount a volume now get those mounts in `canonicalDescription`, so they are recreated once on the first `up` after upgrading (which is what attaches the volume). A plain service's description must not change; the existing pin test covers it.

### Operations and state

- `CreateOperation.Mount` gets a `source` of three kinds in place of `hostPath`: `.bind(hostPath)`, `.namedVolume(name)` and `.anonymousVolume(name)`, each carrying the resolved name. A breaking API change, fine at 0.x.
- New `Operation` cases `.createVolume(VolumeOperation)` and `.removeVolume(VolumeOperation)`, with `VolumeOperation(name:labels:)` shaped like `NetworkOperation`. Give them `service` (nil) and `summary` ("create volume x", "remove volume x").
- `CurrentState` gains `volumes: [VolumeState]` (name, labels), defaulting to empty.

### Planner `up`

- Named volumes resolve as `VolumeSpec.resolvedName` already does: `<project>_<key>` unless `name:` is set. Each declared, non-external volume that does not exist is created, labelled `com.compose.project=<project>` and `com.compose.volume=<key>`, plus the file's own `labels:` (project labels written last, as for containers).
- `external: true` volumes are never created. A service mounting one that does not exist fails the plan with a new `PlanError.missingExternalVolume(name:service:)`, before any operation, like `missingExternalNetwork`.
- **Anonymous volumes are deterministic and labelled.** The name is `<project>_<service>_<first 12 hex of SHA-256 of the target path>`. Labels: upstream's anonymous label `com.apple.container.resource.anonymous` with value `""` (spelt out as a constant in the planner, since it cannot import ContainerResource), plus `com.compose.project`, `com.compose.service` and `com.compose.volume.target=<target>`. One is created only if it does not exist, so a recreate keeps its data. Unlike Docker, an `up` after a plain `down` reuses it too; that is accepted. Names must match upstream's `^[A-Za-z0-9][A-Za-z0-9_.-]*$`, which project and service names already do.
- Volume creates come after network creates and before any container is created. Only volumes for services being created or recreated need an anonymous create; declared named volumes are created whether or not a service in this run needs creating, as Docker does.

### Planner `down`

- Volumes are left alone by default.
- `DownOptions(removeVolumes:)`, default `false`. When true, every volume in the state carrying `com.compose.project=<project>` is removed, sorted by name, after the containers and networks. External volumes, and a `name:` volume that already existed before the project (so never got the label), are never removed.
- Update the doc comment on `Planner.down`, which currently says nothing creates volumes.

### Plugin

- `down -v` / `--volumes` sets `removeVolumes`.
- `Runtime.snapshot()` also lists volumes (`ClientVolume.list()`, name and labels).
- `perform` runs `.createVolume` with `ClientVolume.create(name:driver:driverOpts:labels:)` and `.removeVolume` with `ClientVolume.delete(name:)`.
- `create` maps a bind mount to `.virtiofs` as now, and a volume mount by inspecting it (`ClientVolume.inspect`) and building `Filesystem.volume(name:format:source:destination:options:)`. `ensureBindSources` only looks at bind mounts.
- This adds `Operation` cases, so it reaches Orchard; andrew-waters/orchard#162 is that issue.

## Checked by

- Parser tests: short and long named mounts, short and long anonymous mounts, read-only, undeclared named volume still refused, top-level `volumes:` no longer reported as deferred, non-local driver noted.
- Planner tests comparing whole operation structs: a named volume created with its labels; an existing one not created again; `name:` overriding the prefix; external present (no create) and missing (`missingExternalVolume`); anonymous naming, labels, and reuse on recreate; ordering (networks, then volumes, then containers); `down` keeps volumes; `down` with `removeVolumes` removes only project-labelled ones; the plain-service hash pin unchanged.
- README Scope section and the site's compatibility table (`site/index.html`) updated.
- Manual run with the plugin: a `postgres` service on a named volume keeps its data across `down` and `up`, and loses it with `down -v`.

## Alternatives considered

- Fresh UUID anonymous volumes on every create: a recreate loses the data and old ones pile up until `down -v`.
- Matching Docker exactly (reuse an anonymous volume only on recreate) by carrying each container's mounts in `ContainerState`: more faithful, but more state in both the plugin and Orchard for little gain.
- Bind-mounting a directory under the project in place of a volume: changes what compose files mean and performs worse for databases than an ext4 volume.

## Working here

- You're in the team's harness, andrew-waters/compose, checked out at `~/Code/andrew-waters/compose`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/19-create-and-mount-named-and-anonymous/`: give each repo it touches a worktree there, on the branch `19-create-and-mount-named-and-anonymous`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/19-create-and-mount-named-and-anonymous/<name>" -b 19-create-and-mount-named-and-anonymous origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/compose itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/19-create-and-mount-named-and-anonymous/compose" -b 19-create-and-mount-named-and-anonymous origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/19-create-and-mount-named-and-anonymous/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/compose#19" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/19-create-and-mount-named-and-anonymous/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/compose#19]` and a summary in its front matter as `~/Code/andrew-waters/compose/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/19-create-and-mount-named-and-anonymous/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
