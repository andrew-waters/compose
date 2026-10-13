---
type: requirement
status: in-progress
summary: "Compose files using post_start and pre_stop run on Apple's container runtime with the hooks honoured, instead of being refused."
issues: [andrew-waters/compose#6]
plans: [plans/2026-10-13-docker-compose-post-start-pre-stop.md]
---

# Compose post_start / pre_stop lifecycle hooks

## Problem

Compose files that use post_start or pre_stop (added in Docker Compose v2.30) are refused today, because the plugin never silently ignores unsupported keys. Anyone with such a file has to strip the hooks and run the commands by hand, or not use this tool. #6's reporter wants them to edit /etc/hosts on start and restore it on stop; that is one use among many.

## Goal

Compose files using post_start and pre_stop run on Apple's container runtime with the hooks honoured, instead of being refused.

## Who it's for

People running Docker Compose files on Apple's container runtime through the container compose plugin.

## Requirements

1. Parse post_start and pre_stop on a service as lists of hooks, each with command, environment, working_dir, user and privileged.
2. Run each post_start hook in the service's container after it starts, and each pre_stop hook before it stops.
3. Honour command, environment, working_dir and user on every hook.
4. Accept privileged: false; refuse privileged: true with key, service and line.
5. Run post_start wherever a plan starts a container (up), and pre_stop wherever a plan stops one (down, and recreation during up).
6. A failing post_start fails up with the hook's output and exit code, leaving the container running; a failing pre_stop is reported and the stop continues.

## Out of scope

- Fixing name resolution (extra_hosts, service-name aliases); that is a separate issue, even though it motivated #6.
- Running hooks in Orchard's Compose tab.
- privileged: true on a hook; container exec has no privileged mode.
- New subcommands (stop, start, restart); hooks attach to up and down only.

## Acceptance criteria

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

## Open questions

- STANDARDS.md and plans/_template.md are missing from the repo; who supplies them before the plan is written?

Planned in [plans/2026-10-13-docker-compose-post-start-pre-stop.md](../plans/2026-10-13-docker-compose-post-start-pre-stop.md).
