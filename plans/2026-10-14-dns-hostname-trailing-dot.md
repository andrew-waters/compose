---
type: plan
status: done
summary: "Register compose containers in Apple container's DNS by building the attachment hostname and DNS domain as `container run` does, for andrew-waters/compose#15."
issues: [andrew-waters/compose#15]
touches: [andrew-waters/compose]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-14
requirement:
---

# Register compose containers in container's DNS

Containers made by `container compose up` become resolvable by name, the same as those made by
`container run`. Per-network service names (apple/container#1809) stay out of scope.

## Requirement

From [andrew-waters/compose#15](https://github.com/andrew-waters/compose/issues/15); the issue is
small enough to need no separate requirement.

**Problem:** the plugin attaches a container with its bare name as the hostname and sends no DNS
domain. Container's DNS matches a fully qualified name with a trailing dot exactly, so
`<name>.<domain>` is NXDOMAIN for every compose container.

**Goal:** a compose container registers under the same name `container run` would give it.

**Acceptance criteria:**

- R1: a container name with a dot is attached as `<name>.`.
- R2: a name without a dot is attached as `<name>.<domain>.` when a default domain is set in
  container's config.toml, and that domain is sent as the container's DNS domain.
- R3: with no default domain, the name is left bare, as today.
- R4: the service hash does not change, so an upgrade does not recreate every container.
- R5: the README and the site say how names resolve and that traffic stays within a network.

**Decisions:**

- Send the default domain to the container's resolver too, or only fix the hostname? **Send it,
  following the CLI.**

## Design

`Runtime.create` already loads `ContainerSystemConfig`. It now passes `dns.domain` as
`DNSConfiguration.domain` and builds the attachment hostname with `Runtime.hostname(containerName:dnsDomain:)`,
a pure function that copies `getAttachmentConfigurations` in apple/container's
`Sources/Services/ContainerAPIService/Client/Utility.swift`. It lives in the plugin, not the
planner, because the planner never sees the runtime's config and the rule is the runtime's own.

**Areas it touches:**

- `andrew-waters/compose` `Sources/compose/Runtime.swift`: the DNS configuration and attachment in
  `create`, and the new `hostname` helper.
- `andrew-waters/compose` `Tests/ComposePluginTests/RuntimeTests.swift`: the helper's four cases.
- `andrew-waters/compose` `README.md`, `site/index.html`: how names resolve.

**Risks:**

- The hostname is not part of `Service.canonicalDescription`, so containers created before this
  keep their unresolvable hostname until recreated (`up --force-recreate`, or `down` then `up`).
  The README says so, and the pull request body carries the same line for the release notes.

## Tasks

- [x] [andrew-waters/compose#15](https://github.com/andrew-waters/compose/issues/15) Build the hostname and DNS domain as the CLI does, with tests (satisfies R1, R2, R3, R4)
- [x] [andrew-waters/compose#15](https://github.com/andrew-waters/compose/issues/15) Document name resolution in the README and on the site (satisfies R5)

## Open questions

- None.
