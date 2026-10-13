---
type: plan
status: done
summary: "Support Docker Compose v2.30's post_start and pre_stop service hooks in the container compose plugin, as requested in andrew-waters/compose#6. Orchard is out of scope."
issues: [andrew-waters/compose#6, andrew-waters/compose#7, andrew-waters/compose#8, andrew-waters/compose#9, andrew-waters/compose#10, andrew-waters/compose#11, andrew-waters/compose#12]
touches: [andrew-waters/compose, andrew-waters/orchard, apple/container]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-13
requirement: requirements/docker-compose-post-start-pre-stop.md
---

# Compose post_start / pre_stop lifecycle hooks

Support Docker Compose v2.30's post_start and pre_stop service hooks in the container compose plugin, as requested in andrew-waters/compose#6. Orchard is out of scope.

## Requirement

In full in [requirements/docker-compose-post-start-pre-stop.md](../requirements/docker-compose-post-start-pre-stop.md).

**Problem:** Compose files that use post_start or pre_stop (added in Docker Compose v2.30) are refused today, because the plugin never silently ignores unsupported keys. Anyone with such a file has to strip the hooks and run the commands by hand, or not use this tool. #6's reporter wants them to edit /etc/hosts on start and restore it on stop; that is one use among many.

**Goal:** Compose files using post_start and pre_stop run on Apple's container runtime with the hooks honoured, instead of being refused.

**Who it's for:** People running Docker Compose files on Apple's container runtime through the container compose plugin.

**Scope:**

1. Parse post_start and pre_stop on a service as lists of hooks, each with command, environment, working_dir, user and privileged.
2. Run each post_start hook in the service's container after it starts, and each pre_stop hook before it stops.
3. Honour command, environment, working_dir and user on every hook.
4. Accept privileged: false; refuse privileged: true with key, service and line.
5. Run post_start wherever a plan starts a container (up), and pre_stop wherever a plan stops one (down, and recreation during up).
6. A failing post_start fails up with the hook's output and exit code, leaving the container running; a failing pre_stop is reported and the stop continues.

**Out of scope:**

- Fixing name resolution (extra_hosts, service-name aliases); that is a separate issue, even though it motivated #6.
- Running hooks in Orchard's Compose tab.
- privileged: true on a hook; container exec has no privileged mode.
- New subcommands (stop, start, restart); hooks attach to up and down only.

**Acceptance criteria:**

- **R1** When a service declares post_start or pre_stop, the plugin shall accept the file and keep each hook's command, environment, working_dir and user, instead of refusing it.
- **R2** When a hook sets privileged: true, the plugin shall refuse the file, naming the key, the service and the line.
- **R3** When a hook sets privileged: false, the plugin shall accept it and run the hook as normal.
- **R4** When up starts a service's container, the plugin shall run that service's post_start hooks inside it, in declared order, each finishing before the next starts and before up reports the service as started.
- **R5** When a hook runs, the plugin shall run its command with the hook's environment, working_dir and user.
- **R6** When a post_start hook exits non-zero, up shall fail, reporting the service, the hook's output and its exit code, and shall leave the container running.
- **R7** When down, or a recreation during up, stops a running container, the plugin shall run that service's pre_stop hooks inside it, in declared order, before stopping it.
- **R8** When a pre_stop hook exits non-zero, the plugin shall report the service, the hook's output and its exit code, and shall carry on stopping the container.
- **R9** When a container is already stopped, the plugin shall skip its pre_stop hooks without an error.
- **R10** When the README's scope section is read, it shall list post_start and pre_stop as supported and state that privileged: true is refused and Orchard does not run hooks.
- **R11** When a service's post_start or pre_stop hooks change between one up and the next, up shall recreate that service's container, running its pre_stop hooks before the old container stops and its post_start hooks after the new one starts.
- **R12** When the plugin is upgraded to this version, up shall not recreate containers for services that declare no hooks.

**Decisions:**

- Whose problem are we solving first: lifecycle-hook parity, or the /etc/hosts and name-resolution need behind #6? **Hook parity. post_start/pre_stop should run instead of being refused; /etc/hosts is one use among many, and name resolution stays a separate issue.**
- Which hook fields are in scope: command, working_dir, environment, user, privileged? **All five fields: full parity with the Compose spec, subject to the runtime's exec being able to do user and privileged.**
- How should a hook with privileged be handled, given container exec has no privileged mode? **Accept privileged: false as a no-op; refuse privileged: true, naming the key, service and line, like other unsupported keys. command, environment, working_dir and user are honoured.**
- What happens when a hook exits non-zero? **Asymmetric. A failing post_start fails up, showing the hook's output and exit code, and leaves the container running. A failing pre_stop is reported but the stop or down carries on.**
- Is Orchard's Compose tab part of this work? **Plugin only. Orchard is out of scope and not planned.**
- Are requirements R1-R10 and the non-goals right? **Approved; move to design.**
- Are R11 and R12, raised by putting hooks in the hash, right? **Approved; back to design.**

## Design

**Model.** Add `Service.Hook` (command, environment, workingDirectory, user) and `postStart`/`preStop: [Hook]` on `Service`. `privileged` isn't stored: `false` is accepted and dropped, `true` is refused at parse time.

**Parser.** Add `post_start` and `pre_stop` cases to `parseService`, with a `parseHooks` helper that reuses `parseCommand` and `parseEnvironment`. `privileged: true` raises a behavioural `.unsupported` finding at `services.<name>.<hook>[i].privileged`, following the `restart` pattern, so the plugin refuses the file naming key, service and line. Add both keys to `KeySupportTable.service` as `.supported`.

**Hash.** `canonicalDescription` gains hook lines only when a service has hooks, so editing a hook recreates the container (R11) while services without hooks keep their existing hash across the upgrade (R12).

**Planner.** Add `Operation.runHook(HookOperation)`. `HookOperation` carries the service, container name, phase (postStart/preStop), index, the resolved command, environment, working directory and user, and `failureIsFatal` (true for post_start, false for pre_stop). `up` emits each post_start hook right after `startContainer`; `up` (on recreate) and `down` emit pre_stop hooks right before `stopContainer`, which is only emitted for running containers, so a stopped container gets none. All of it is pure and covered by planner tests.

**Runtime.** `perform(.runHook)` follows `container exec`: fetch the container, copy its init process configuration, override executable, arguments, environment, working directory and user, `createProcess`, start, stream stdout and stderr live under the step line (as build output is shown), and wait for the exit code. In `execute`, a non-fatal failure is reported and the plan carries on; a fatal one stops the plan as today, leaving the container running.

**Docs.** README scope lists the keys as supported, with the privileged and Orchard caveats.

**Orchard.** Out of scope for code. A task files an issue on andrew-waters/orchard about the new `runHook` operation so Orchard refuses or lists hooks rather than silently skipping them when it bumps this package.

**Areas it touches:**

- `andrew-waters/compose` `Sources/ComposeModel/KeySupport.swift`: Table of every compose key and its support level (supported, deferred, unsupported with a reason). post_start and pre_stop are absent, so they are refused today as unknown keys. New keys must be added here.
- `apple/container` `Sources/ContainerCommands/Container/ContainerExec.swift`: container exec runs a new process in a running container. It honours env and env files, a working directory, and user (by name or uid/gid), so a hook's command, environment, working_dir and user all map onto it.
- `andrew-waters/compose` `Sources/ComposePlanner/Operation.swift#L8-L15`: Plan operations include startContainer and stopContainer. The plugin has only up and down (Sources/compose/Compose.swift#L18), so hooks attach to wherever a plan starts or stops a container: post_start on up, pre_stop on down and on recreation during up.
- `andrew-waters/compose` `Sources/ComposeModel/Service.swift`: Service holds only what the implementation can act on. Hooks become a new Service.Hook type and postStart/preStop arrays here.
- `apple/container` `Sources/ContainerCommands/Container/ContainerExec.swift#L45-L130`: exec copies the container's initProcess config, overrides executable, args, env, cwd and user, then calls ContainerClient.createProcess(containerId:processId:configuration:stdio:) and waits for the exit code. ContainerAPIClient is already linked by the plugin, so hooks can run in process the same way.

**Patterns to follow:**

- `andrew-waters/compose` `Sources/ComposeModel/KeySupport.swift#L139-L154`: How an unsupported key is declared: .unsupported(severity:, reason:). user is unsupported for services because create cannot set it; privileged because there is no privileged mode.
- `andrew-waters/compose` `Sources/ComposeParser/ServiceParsing.swift#L8-L100`: parseService switches on each key; supported keys get a parse helper, value-dependent refusals (restart) call note(...) with .unsupported(severity: .behavioural, ...). post_start/pre_stop need a case here; privileged: true on a hook follows the restart pattern. parseCommand and parseEnvironment can be reused for a hook's command and environment.
- `andrew-waters/compose` `Sources/ComposePlanner/Planner.swift#L185-L300`: up and down emit startContainer/stopContainer per service in dependency order, only stopping containers that are running. Hook steps slot in right after each start and right before each stop; the isRunning check already gives R9. Orphans have no service, so no hooks.
- `andrew-waters/compose` `Sources/ComposePlanner/Operation.swift`: Operations are a public enum carrying plain value structs; each case has a service and a one-line summary used for progress and --dry-run. A new runHook case with a HookOperation struct fits this shape.

**Risks:**

- `apple/container` `Sources/Services/ContainerAPIService/Client/Flags.swift`: The exec process flags have no privileged option and ProcessConfiguration has no capabilities field, so a hook's privileged: true cannot be honoured by exec today.
- `andrew-waters/compose` `Sources/ComposeModel/Service.swift#L173-L208`: canonicalDescription feeds the service hash (ProjectIdentity.hash), and a hash change means recreate. Whether hooks are part of it decides if editing a hook recreates every container that has one.
- `andrew-waters/compose` `Sources/compose/Runtime.swift#L60-L100`: Runtime.execute stops at the first failed operation. pre_stop failures must be reported and carried on past (R8), so the operation needs to say whether its failure is fatal; that decision belongs in the planner, per the planner-decides convention (processArguments).
- `andrew-waters/orchard` `(not cloned)`: Orchard links ComposePlanner. A new Operation case breaks any exhaustive switch in Orchard when it next bumps this package, or is skipped if it has a default case. Orchard is out of scope, but its owner needs to know.

**Decisions:**

- Should editing a service's hooks recreate its container (hooks in the service hash)? **Yes. Hooks are part of the service hash, so editing one recreates the container on the next up.**
- How should a hook's output be shown while up or down runs? **Stream stdout and stderr live under the hook's step line, as build output is shown today.**
- How do we handle the new Operation case reaching Orchard? **A task files an issue on andrew-waters/orchard describing the runHook case and asking Orchard to refuse or list hooks rather than skip them. Orchard's owner picks it up.**
- Is the design right? **Approved; move to tasks.**

## Tasks

- [x] [andrew-waters/compose#7](https://github.com/andrew-waters/compose/issues/7) Model and parse post_start and pre_stop hooks (satisfies R1, R2, R3)
- [x] [andrew-waters/compose#8](https://github.com/andrew-waters/compose/issues/8) Include hooks in the service hash, only when present (satisfies R11, R12)
- [x] [andrew-waters/compose#9](https://github.com/andrew-waters/compose/issues/9) Emit runHook operations from the planner (satisfies R4, R7, R9, R11)
- [x] [andrew-waters/compose#10](https://github.com/andrew-waters/compose/issues/10) Run hooks in the plugin runtime (satisfies R4, R5, R6, R8)
- [x] [andrew-waters/compose#11](https://github.com/andrew-waters/compose/issues/11) Document post_start and pre_stop support in the README (satisfies R10)
- [x] [andrew-waters/compose#12](https://github.com/andrew-waters/compose/issues/12) Tell Orchard about the new runHook operation (filed as andrew-waters/orchard#126)

**Decisions:**

- Are the six tasks right? **Approved; the plan is ready.**

## Open questions

- STANDARDS.md and plans/_template.md are missing from the repo; who supplies them before the plan is written? **Added after the fact, modelled on this plan, alongside CLAUDE.md.**
