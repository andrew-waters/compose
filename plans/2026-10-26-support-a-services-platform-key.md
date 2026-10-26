---
type: plan
status: done
summary: "Honour a service's `platform:` (andrew-waters/compose#17): parsed and validated, carried on the pull, build and create operations, and run by the plugin with Rosetta for amd64, so Orchard can map it for andrew-waters/orchard#147."
issues: [andrew-waters/compose#17, andrew-waters/orchard#147]
touches: [andrew-waters/compose, andrew-waters/orchard]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-26
---

# Support a service's platform key

A service with `platform: linux/amd64` is pulled, built and run as amd64, under Rosetta on Apple silicon. A service without the key plans, hashes and runs exactly as before. Orchard's own mapping of the key is its half of andrew-waters/orchard#147.

## Requirement

From andrew-waters/compose#17, agreed with the plan for andrew-waters/orchard#147.

- **R1** `platform:` is parsed (interpolated, `os/arch` or `os/arch/variant`, lowercased) and supported in `KeySupportTable`; anything else is refused with its line.
- **R2** It is carried on `CreateOperation`, `BuildOperation` and `PullOperation`, optional and defaulting to `nil`, so Orchard compiles unchanged until it maps it.
- **R3** A service without it keeps its hash; one with it hashes differently.
- **R4** The plugin pulls, builds and creates as that platform, with `rosetta` set for amd64 on arm64 and the host's kernel.
- **R5** README Scope and the site's compatibility table.

**Decisions:**

- Should the plugin infer a platform from the image when the file names none, like `container run` from 1.6.1? **No. It keeps the host's platform, as today; the plugin builds against container 1.4.1, which has no platforms route. Orchard does its own inference.**

## Design

- **Model**: `Service.platform: String?`. `canonicalDescription` adds `platform=` after the resources lines, only when set.
- **Parser**: `parsePlatform` in `Values.swift`, beside `validateName`. Two or three non-empty parts of letters, digits, `_` and `-`.
- **Planner**: passes `service.platform` to the three operations. No decision is made here; an image already present is not re-pulled, and the runtime's `fetch(platform:)` pulls the missing variant at create.
- **Runtime**: `ClientImage.pull(platform:)`; `container build --platform=<p>` in place of `--arch=arm64` when set; create resolves the platform, fetches, unpacks and reads the config for it, keeps the host's kernel (the CLI does the same) and sets `platform`, `rosetta` (`needsRosetta`) and `runtimeHandler`.

**Risks:**

- `andrew-waters/compose` `Sources/ComposeModel/Service.swift`: the hash format. Pinned by a test that a plain service's description is unchanged.
- An amd64 service on a Mac without Rosetta fails at create with the runtime's error. Orchard checks first; the plugin leaves it to the runtime, as `container run` does.

## Tasks

- [x] [andrew-waters/compose#17](https://github.com/andrew-waters/compose/issues/17) Model, parser, key table, operations, planner and runtime, with parser, planner and runtime tests (satisfies R1, R2, R3, R4)
- [x] [andrew-waters/compose#17](https://github.com/andrew-waters/compose/issues/17) Document it in the README Scope section and the site's compatibility table (satisfies R5)

## Open questions

- Release as 0.7.0 once merged, so Orchard can move its pin from 0.5.x.
