---
name: release
description: Cut a release of the container compose plugin: choose the version, write the annotated tag, push it, watch CI publish the GitHub release, then tell the people whose issues it closes. Use when asked to release, tag, ship or publish a version.
---

# Releasing the plugin

A release is an annotated tag on `main`. Pushing the tag runs the `release` job in
`.github/workflows/ci.yml`. The tests do not run again on a tag. Instead the job checks that main
passed CI on the code being released, then builds the plugin with the version stamped in from the
tag, checks the binary reports it, packages `compose-<version>-macos-arm64.tar.gz` and creates the
GitHub release. Merging to `main` releases nothing.

There is no changelog file. The release notes are generated from the pull requests merged since
the last tag (`gh release create --generate-notes`), and the title is the first line of the tag
message. Never edit `Sources/compose/Version.swift` by hand: it holds the `0.0.0-dev` placeholder
and CI fails a pull request that changes it.

Pushing a tag publishes a release. Confirm the version and the tag message with the user before
pushing it, unless they have already said to go ahead.

## 1. Check main is ready

```bash
git fetch origin --tags
git log --oneline "$(git describe --tags --abbrev=0 origin/main)"..origin/main   # what is going out
gh run list --branch main --workflow CI --event push --limit 5                  # the latest code commit must be success
```

If main's run failed, read why before anything else (`gh run view <id> --log-failed`). A failure
that never reached the code, such as `Couldn't fetch updates from remote repositories` or
`Failed to connect to github.com`, is the runner's network: rerun just the failed job with
`gh run rerun <id> --failed` and wait for it, because the release job will refuse a tag whose code
has no passing run on main. A failure in the tests or the build is a bug; fix it on a branch first.

Commits that only touch the harness, the site or Markdown (Gannin's own commits among them) get no
CI run, so the newest run on main may be for an older commit; that is fine as long as it passed and
no code has changed since. Wait for a run still in progress. The release job makes the same check
and refuses to publish if it fails, but a refused tag has to be deleted and pushed again, so check
first.

## 2. Choose the version

Tags are bare semver (`0.4.0`, not `v0.4.0`). Before 1.0:

- **Minor** (`0.4.0` to `0.5.0`) for a new key, command or behaviour, and for anything breaking.
- **Patch** (`0.5.0` to `0.5.1`) for fixes only.

## 3. Write the tag message

The first line is the release title: a short sentence for a person, saying what this release does,
with no trailing full stop. Then a blank line and a body, wrapped at about 95 columns:

- What changed for someone using the plugin, in a paragraph or two.
- Anything breaking: what stops working, and what to do about it. Say it plainly.
- An `Also in this release:` line for smaller things.

No em dashes, en dashes or ellipsis characters, and no attribution lines. `git cat-file -p 0.4.0`
shows a good example. Write the message to a file in the scratchpad rather than passing it with
`-m`, so the body keeps its line breaks.

## 4. Tag and push

```bash
git tag -a 0.5.0 -F /path/to/tag-message.txt origin/main
git cat-file -p 0.5.0          # check the message and that it points at main's head
git push origin 0.5.0
```

## 5. Watch the release job

```bash
gh run list --workflow CI --limit 3                 # find the run for the tag
gh run watch <run-id> --exit-status
gh release view 0.5.0 --json name,assets -q '.name, .assets[].name'
```

The release must exist, carry the tag message's first line as its title, and have
`compose-0.5.0-macos-arm64.tar.gz` attached. If the job fails, read the failing step's log before
doing anything; do not delete and re-push a tag that people may already have fetched without
asking the user.

## 6. After the release

- Comment on the issues the release closes, mentioning whoever reported them by handle, with what
  shipped, the version and a link to the release.
- Set each requirement the release completes to `status: done` (see `STANDARDS.md`).
- Installing is `make build` then `sudo make install`; the container installer wipes the plugin
  directory on every upgrade (apple/container#1617), so users may need to reinstall.
