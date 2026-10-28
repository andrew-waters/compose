---
type: plan
status: done
summary: "Create and mount named and anonymous volumes (andrew-waters/compose#19): kept by the parser, created and labelled by the planner, mounted as ext4 volumes by the plugin, and removed only by `down -v`, so Orchard can map the new mount kinds and operations for andrew-waters/orchard#162."
issues: [andrew-waters/compose#19, andrew-waters/orchard#162]
touches: [andrew-waters/compose, andrew-waters/orchard]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-28
---

# Create and mount named and anonymous volumes

A service that mounts a named or anonymous volume gets it: the volume is created on `up` if it is
not there, mounted into the container, and kept across `down` and recreates until `down -v`.
Today both kinds are dropped with a note, so a database loses its data whenever it is recreated.
Orchard's mapping of the new mount kinds and operations is its half, andrew-waters/orchard#162.

## Requirement

From andrew-waters/compose#19, whose decisions were agreed with the maintainer.

- **R1** The parser keeps `.named` and `.anonymous` mounts, short and long form, read-only
  included. A named volume the file does not declare is still refused. Top-level `volumes:` is no
  longer reported as deferred; a `driver` other than `local` gets a cosmetic note.
- **R2** A plain service's `canonicalDescription` is unchanged. A service that mounts a volume
  gains its mount lines, so it is recreated once on the first `up` after upgrading.
- **R3** `CreateOperation.Mount` carries a `source` of `.bind(hostPath)`, `.namedVolume(name)` or
  `.anonymousVolume(name)` in place of `hostPath`. New `Operation` cases `.createVolume` and
  `.removeVolume` take a `VolumeOperation(name:labels:)`. `CurrentState` gains `volumes`.
- **R4** `up` creates each declared, non-external named volume that does not exist, labelled with
  the project and the key over the file's own labels. A missing external volume that a service
  mounts fails the plan with `PlanError.missingExternalVolume`.
- **R5** Anonymous volumes are named `<project>_<service>_<12 hex of SHA-256(target)>`, labelled
  as anonymous, with the project, service and target, and are created only when missing, for
  services being created or recreated, so a recreate keeps the data.
- **R6** Volume creates come after network creates and before any container create.
- **R7** `down` leaves volumes alone; `DownOptions(removeVolumes: true)` removes every volume
  labelled with the project, sorted by name, after containers and networks.
- **R8** The plugin: `down -v` / `--volumes`, volumes in the snapshot, `ClientVolume.create` and
  `ClientVolume.delete` for the operations, and `Filesystem.volume` for a volume mount.
- **R9** README Scope and the site's compatibility table.

## Design

- **Model** (`Sources/ComposeModel`): `VolumeSpec`'s doc comment describes what is now done with
  it. `Service.Mount` is unchanged; its `description` already renders named (`key:/target`) and
  anonymous (`:/target`) mounts, which is what goes into the hash.
- **Parser** (`Sources/ComposeParser`): `parseMounts` stops dropping `.named` and `.anonymous`.
  `parseTopLevelVolumes` drops the deferred note and notes a non-`local` `driver` as cosmetic,
  the way `networks.<key>.driver` is.
- **Planner** (`Sources/ComposePlanner`):
  - `Operation.swift`: `CreateOperation.Mount(source:containerPath:readOnly:)` with
    `Mount.Source`; `VolumeOperation` shaped like `NetworkOperation`; the two new cases, with
    `service` nil and summaries `create volume x` / `remove volume x`.
  - `CurrentState.swift`: `VolumeState(name:labels:)` with `projectName`, and
    `CurrentState.volumes`, a last init argument defaulting to empty so existing callers compile.
  - `ProjectIdentity.swift`: `volumeLabel` (`com.compose.volume`), `volumeTargetLabel`
    (`com.compose.volume.target`), `anonymousVolumeLabel`
    (`com.apple.container.resource.anonymous`, spelt out since the planner cannot import
    ContainerResource), `volumeLabels(key:own:)` and `anonymousVolumeName(service:target:)`.
  - `Planner.swift`: `up` checks external volumes beside external networks, before any
    operation. After the network creates it emits one `.createVolume` per missing declared
    non-external volume, sorted by resolved name, then one per missing anonymous volume of a
    service being created or recreated, in start order, never the same name twice.
    `createOperation` maps each mount to its source. `down` gains the `removeVolumes` pass and
    its doc comment is rewritten. `PlanError.missingExternalVolume(name:service:)`.
- **Plugin** (`Sources/compose`): `Down` gets `-v` / `--volumes`. `snapshot()` adds
  `ClientVolume.list()`. `perform` creates with `ClientVolume.create(name:labels:)` (the
  `local` driver, the only one there is) and removes with `ClientVolume.delete(name:)`. `create`
  maps a bind to `.virtiofs`, and a volume by `ClientVolume.inspect` into
  `Filesystem.volume(name:format:source:destination:options:)`. `ensureBindSources` skips
  volumes.

**Patterns to follow:**

- `Planner.networkAssignments` and `missingExternalNetwork` for the external check.
- The network create and remove passes in `up` and `down` for ordering and labels.
- `Utility.getOrCreateVolume` upstream for how `container run` mounts a volume.

**Risks:**

- The hash: a plain service must keep its description; the existing pin test covers it. Services
  that mount volumes recreate once after upgrading, which is the point.
- `CreateOperation.Mount` and `Operation` change shape, which breaks Orchard until it maps them
  (andrew-waters/orchard#162). Released as a new minor version.
- A volume is ext4 with a `lost+found` at its root, so `postgres` refuses one mounted straight
  at its data directory (found in the manual run). The README says to set `PGDATA` one level
  down, as `container run` users already do.
- A volume is a disk attached to one container's machine, and the runtime does not stop a second
  attaching it. `up` refuses a volume mounted twice in the file, read-only included, or held by
  a running container outside its service (`PlanError.sharedVolume`, `.volumeInUse`). This
  refuses Docker's shared-volume pattern; a bind mount is the way to share files.
- The runtime will not delete a volume any container mounts, so `down -v` skips one still
  mounted by a container it is not removing, as it skips a network still in use.
- A named mount hashes its volume's own `name:` (or an external volume's key) when it has one,
  so renaming the volume recreates the container onto it.

**Decisions:**

- Are declared volumes no service mounts created too? **Yes, every declared non-external volume,
  as Docker does.**
- What order do volume creates go in? **Declared volumes by resolved name, then anonymous ones in
  start order, so a plan is stable whatever order the file wrote its keys in.**

## Tasks

- [x] [andrew-waters/compose#19](https://github.com/andrew-waters/compose/issues/19) Parser and model, with parser tests for each form, the refusal and the driver note (satisfies R1, R2)
- [x] [andrew-waters/compose#19](https://github.com/andrew-waters/compose/issues/19) Operations, state and planner, with planner tests comparing whole operation structs (satisfies R3, R4, R5, R6, R7)
- [x] [andrew-waters/compose#19](https://github.com/andrew-waters/compose/issues/19) Plugin runtime and `down -v` (satisfies R8)
- [x] [andrew-waters/compose#19](https://github.com/andrew-waters/compose/issues/19) Document it in the README Scope section and the site's compatibility table (satisfies R9)
- [x] [andrew-waters/compose#19](https://github.com/andrew-waters/compose/issues/19) Manual run: a `postgres` service on a named volume keeps its data across `down` and `up`, and loses it with `down -v`

## Open questions

- Release as the next minor once merged, so Orchard can move its pin for andrew-waters/orchard#162.
