# andrew-waters/compose#21: Read a network's legacy external: {name: x} form as external

https://github.com/andrew-waters/compose/issues/21

- State: open
- Labels: bug
- Opened by: @andrew-waters, 2 Nov 2026

## Description

## What problem are you trying to solve?

`parseTopLevelNetworks` in `Sources/ComposeParser/Parser.swift` reads `external` with `fieldValue.bool ?? false`. The legacy form, which compose still accepts:

```yaml
networks:
  shared:
    external:
      name: team-net
```

has no boolean value, so it becomes `external: false`. `up` then creates a new `<project>_shared` network and attaches the services to it, in place of joining `team-net`. Nothing is reported, so the services quietly end up on the wrong network. A string such as `external: "nope"` is read as false the same way.

Volumes had the same bug, and it was fixed in andrew-waters/compose#20 for andrew-waters/compose#19. Networks were left out of that change to keep it in scope.

## Proposed solution

Handle a network's `external` the way #20 handles a volume's in `parseTopLevelVolumes`:

- A boolean sets `isExternal` as now.
- A mapping means external. Its `name` becomes the network's `name`. A top-level `name:` that disagrees with it is refused with its line. Any other key gets a cosmetic note, and `x-` keys are skipped.
- Any other value is refused with its line.
- An external network's name is checked as the runtime checks one, so a bad name fails at parse time with its line and not part way through `up`.

The two can share a helper, so volumes and networks cannot drift apart again.

## Checked by

- Parser tests: the boolean form, the legacy form (name taken, external set), a conflicting `name:` refused, an unknown key in the legacy form noted, and a value that is neither a boolean nor a mapping refused.
- A planner test: a legacy-form external network that exists is joined and not created, and one that is missing fails with `missingExternalNetwork`.

## Working here

- You're in the team's harness, andrew-waters/compose, checked out at `~/Code/andrew-waters/compose`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/21-read-a-network-s-legacy-external-name-x/`: give each repo it touches a worktree there, on the branch `21-read-a-network-s-legacy-external-name-x`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/21-read-a-network-s-legacy-external-name-x/<name>" -b 21-read-a-network-s-legacy-external-name-x origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/compose itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/21-read-a-network-s-legacy-external-name-x/compose" -b 21-read-a-network-s-legacy-external-name-x origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/21-read-a-network-s-legacy-external-name-x/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/compose#21" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/21-read-a-network-s-legacy-external-name-x/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/compose#21]` and a summary in its front matter as `~/Code/andrew-waters/compose/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/21-read-a-network-s-legacy-external-name-x/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
