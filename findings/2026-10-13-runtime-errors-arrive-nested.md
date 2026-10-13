---
type: finding
summary: "Errors raised inside the guest reach the plugin as text with every layer's message wrapped round the one below."
issues: [andrew-waters/compose#6]
tags: [runtime, apple-container, errors]
---

# Runtime errors from the guest arrive nested

A process that fails to start inside a container (here, a hook whose executable does not exist)
comes back from `ContainerClient.createProcess` / `ClientProcess.start` as a
`ContainerizationError` whose `localizedDescription` carries every layer, quotes and all:

```
failed to start process 049d5007 in container hookfail-web (cause: "internalError: "failed to
start process (cause: "internalError: "startProcess: failed to start process: internalError:
"vmexec error: internalError: "failed to find target executable /no/such/script"""")"")
```

Seen with `container` 1.5.0 on macOS 26, running `down` on a service whose `pre_stop` named a
missing script.

The inner layers crossed from the VM over XPC as strings, so the typed `cause` chain runs out
before the useful message; only the text has it. `Runtime.innermostCause(of:)` takes the message
after the last `: "` when the text contains `(cause: "`, which gives
`failed to find target executable /no/such/script`. Use `Runtime.friendly(_:)` for anything shown
to a person.
