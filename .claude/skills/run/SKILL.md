---
name: run
description: Build the container compose plugin from a worktree and drive it against Apple's container runtime on this Mac, without installing it. Use to see a change working for real, to demo a feature, or to reproduce a bug end to end.
---

# Running the plugin against the real runtime

The plugin binary runs fine straight out of the build directory, so there is no need for
`sudo make install` (which would also replace whatever plugin version the user has installed).

## 1. Check the runtime is up

```bash
container system status        # status must be "running"
container --version
```

If it is not running, ask the user to run `! container system start`.

## 2. Build once

From the worktree, with `SCRATCH` set to the session's scratchpad directory:

```bash
swift build > "$SCRATCH/build.log" 2>&1; echo "exit $?"
BIN="$(swift build --show-bin-path)/compose"
```

`--show-bin-path` matters: this package builds into `.build/out/Products/Debug`, not the usual
`.build/debug`.

## 3. Write a compose file in the scratchpad

Keep demo projects out of the repo, one directory per project, and give each a `name:` so its
containers (`<name>-<service>`) are easy to find and clean up. Use images already pulled
(`container image list`); `nginx:alpine` and `alpine` are usually there.

Two traps when writing the YAML:

- A plain scalar cannot contain `: ` (colon, space). Write commands in list form, or quote them,
  or the parser stops with "mapping values are not allowed in this context".
- `$VAR` is interpolated from your shell when the file is read. Write `$$VAR` for a variable that
  should be read inside the container.

## 4. Drive it

Options go after the subcommand: `$BIN up -f other.yaml`, not `$BIN -f other.yaml up`.

```bash
cd "$SCRATCH/demo"
$BIN up --dry-run              # the plan, nothing changed
$BIN up                        # numbered steps, output under each
$BIN up                        # a second up over an unchanged file: "Everything is already up to date."
container exec <name>-<service> <command>   # look inside
$BIN down
```

Check exit codes as well as output. To see a recreate, change something that is in the service
hash (an environment value, a hook) and run `up` again. Files written to a bind mount
(`./out:/out`) are a simple way to prove something ran inside the container after it is gone.

## 5. Clean up

```bash
$BIN down
container ls -a | grep <name>   # should print nothing
```

Remove any container or network left by a run that failed part way with `container rm -f` and
`container network rm`. Leave the user's own containers alone.
