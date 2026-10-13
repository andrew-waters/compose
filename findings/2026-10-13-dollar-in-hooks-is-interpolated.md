---
type: finding
summary: "$VAR in a hook command is filled in from the user's shell when the file is read, so hooks need $$VAR for the container's variables."
issues: [andrew-waters/compose#6]
tags: [compose-spec, interpolation, docs]
---

# `$VAR` in a hook is the shell's, not the container's

Compose interpolates the whole file when it is read, hook commands included. A hook written as

```yaml
command: ["sh", "-c", "echo GREETING=$GREETING"]
environment:
  GREETING: hello
```

prints `GREETING=` and the parser warns that `GREETING` is not set, because `$GREETING` was
replaced from the user's shell before the hook ever ran. `$$GREETING` passes a literal `$` through
and prints `GREETING=hello`. This is Docker Compose's behaviour too, so it is kept, and the README
says so; it is the first thing people will trip over when writing hooks.
