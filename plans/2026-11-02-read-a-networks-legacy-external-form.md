---
type: plan
status: done
summary: "Read a network's legacy `external: {name: x}` form as external (andrew-waters/compose#21): one parser helper for networks and volumes, the runtime's network name rule checked at parse time, and a network's own host name in the service hash so renaming it recreates the container."
issues: [andrew-waters/compose#21]
touches: [andrew-waters/compose]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-11-02
---

# Read a network's legacy external form as external

A network written as `external: {name: team-net}` is joined as `team-net` and never created, where today it is read as `external: false` and `up` quietly creates `<project>_<key>` in its place. Volumes were fixed the same way in andrew-waters/compose#20; this brings networks level and makes the two share their code. Nothing changes for Orchard: no new `Operation` case, and `Service` only gains a field with a default.

## Requirement

From andrew-waters/compose#21.

- **R1** A boolean `external` sets the network external or not, as now.
- **R2** A mapping means external, and its `name` becomes the network's name. A top-level `name:` that disagrees is refused with its line; any other key is noted as cosmetic, and `x-` keys are skipped.
- **R3** Any other value (`external: "nope"`, a list) is refused with its line.
- **R4** A name a network keeps as written (its `name:`, or the key of an external one) is checked against the runtime's rule at parse time, and so is a key that ends `<project>_<key>`.
- **R5** Renaming the network a service joins, or making it external, recreates the service; a service on a project network keeps its hash.
- **R7** All of this holds for the implicit `default` network, which a service that lists no network is on, when the file declares it.
- **R6** README Scope.

**Decisions:**

- Should the hash bug (networks hashed by key only) be fixed here or in its own issue? **Here.**
- Should the name check cover a plain network's `name:` too, or only an external one? **Both, as for volumes.**
- Should a top-level `default` override the implicit network? **Yes; overriding `default` is the commonest use of the old form, found in review.**

## Design

- **Model**: `Service.networkHostNames: [String: String]`, keyed by network key, holding the name of the network the service joins (the first it lists, or `default`) only when it does not follow from the project. `canonicalDescription` renders `network=<key>[<name>]` for it and `network=<key>` otherwise, over the union of `networks` and those keys so the implicit `default` is included, as `Mount.hostName` does for volumes; a plain service's description is unchanged.
- **Parser**: `parseExternal` and `assignName` in `Parser.swift`, used by `parseTopLevelNetworks` and `parseTopLevelVolumes`, so the two cannot drift again. `validateNetworkName` in `Values.swift` follows the runtime's `NetworkResource.nameValid`: `^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$`, the same in container 1.4.1 and 1.6.1, and stricter than the volume rule. A network with no name of its own has its key checked by `validateNetworkKey`, since it ends `<project>_<key>`; the length is left to the runtime, as the project name is not known here. `resolveHostNames` (was `resolveVolumeHostNames`) stamps the joined network beside mounts.
- **Planner**: `networkAssignment` looks up `file.networks[service.networks.first ?? "default"]`, so a declared `default` reaches the create operation, `networkNames` and the `missingExternalNetwork` check. `NetworkSpec.resolvedName` already prefers `name`.
- **Runtime**: unchanged.

**Risks:**

- `Sources/ComposeModel/Service.swift`: the hash format. A service on an external or named network is recreated once on the first `up` after upgrading, which is the fix; a test pins the description of a service on a project network.
- A network `name:` the runtime refuses (uppercase, say) used to fail part way through `up`; it now fails at parse time. That is the intent, but a file that only ever ran `config` will now be refused.

## Tasks

- [x] [andrew-waters/compose#21](https://github.com/andrew-waters/compose/issues/21) Shared `external` parsing, the network name check, network host names in the hash, with parser and planner tests (satisfies R1 to R5, R7)
- [x] [andrew-waters/compose#21](https://github.com/andrew-waters/compose/issues/21) Document it in the README Scope section; the site's matrix already lists networks and needs no change (satisfies R6)

## Open questions

- None.
