---
type: finding
summary: "Containerization's Timeout.run cannot bound a read on a pipe that something else holds open, because its task group waits for the read."
issues: [andrew-waters/compose#6]
tags: [concurrency, containerization]
---

# `Timeout.run` cannot stop a pipe read

`ContainerizationExtras.Timeout.run(seconds:operation:)` races the operation against a sleep in a
task group and throws `CancellationError` when the sleep wins. A task group does not return until
all its children have, and cancellation is only a request. A `for try await` over
`FileHandle.bytes.lines` blocked on a pipe does not respond to it, so the timeout fires and then
waits for the read anyway.

This matters for hooks: a hook such as `sh -c 'daemon &'` exits while the background process
still holds the hook's stdout and stderr, so the end of the stream never comes.

What the plugin does instead (`HookTranscript.drain` in `Sources/compose/Runtime.swift`): the
relays run as unstructured tasks, the hook polls for them to finish against a deadline it owns,
and once the deadline passes it stops showing output and moves on without awaiting the relays.
Use the same shape for any deadline on I/O that another process controls.
