---
type: finding
summary: "A running container's /etc/hosts can be edited with exec, though the create surface cannot set it."
issues: [andrew-waters/compose#6]
tags: [runtime, apple-container, networking]
---

# `/etc/hosts` is writable once a container runs

`extra_hosts` is refused because the create surface cannot write the hosts file
(`KeySupportTable.service["extra_hosts"]`). After the container starts, though, a process run in
it can: a `post_start` hook appending `10.0.0.42 api.internal` to `/etc/hosts` in an
`nginx:alpine` container worked, and `container exec hookdemo-web tail -2 /etc/hosts` showed

```
192.168.65.2 hookdemo-web
10.0.0.42 api.internal
```

Seen with `container` 1.5.0. The runtime writes its own entry for the container's hostname first.

This is a possible route for `extra_hosts` (and for service-name aliases) without runtime
support: write the entries with an exec after start. It is not done today; the open issue on
name resolution should weigh it against waiting for
[apple/container#1809](https://github.com/apple/container/issues/1809). Anything written this way
is lost if the runtime rewrites the file, so check that before relying on it.
