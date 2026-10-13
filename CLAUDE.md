# compose

The `container compose` plugin: Docker Compose files on Apple's container runtime. This repo is
both the code and the team's Gannin harness, so plans, requirements and findings live beside the
code (see [STANDARDS.md](STANDARDS.md)).

## Projects

There is no `projects/` folder. The one code repo is this one, `andrew-waters/compose`. Orchard
(`andrew-waters/orchard`) links `ComposeModel`, `ComposeParser` and `ComposePlanner`, but is a
separate project; changes it needs are filed there as issues, not made from here.

## How work goes here

- Never work in the main checkout. Each issue gets one worktree,
  `.worktrees/<issue>-<slug>/compose`, on a branch of the same name, cut from `origin/HEAD`.
  `.worktrees/` is ignored by git.
- An issue's plan is `plans/YYYY-MM-DD-<slug>.md` from [plans/_template.md](plans/_template.md),
  and ships in the same pull request as the code. Tick its tasks as they land and set
  `status: done` when the last one does.
- Propose a plan before changing code. Once it is agreed, make the whole change, then build and
  test once at the end.
- Pull requests say `Closes andrew-waters/compose#N` for each issue they finish. Merges are merge
  commits.

## One commit, one push

CI runs on every push of code to a branch with an open pull request, drafts included. It runs on a macOS
runner, which GitHub bills at ten times the Linux rate, and a run takes a long while. A branch with
no pull request runs nothing. So in a Gannin session:

1. Make the whole change in the worktree, build and test once locally, and commit it as **one
   commit**, the plan's ticked tasks included.
2. Do not push, and do not open a pull request, not even a draft, while Gannin's review is going
   on. `ready-for-review` and the reviewer read the local worktree; they need nothing on GitHub.
   This overrides the brief's "a draft is fine".
3. Fix review findings locally and fold them into the same commit (`git commit --amend`, safe
   because nothing has been pushed). Run the scoped tests that cover the fix, not the whole suite
   each round.
4. When Gannin says the review has settled, push once and open the pull request ready for review.
5. After that, collect any further feedback and push it as one commit, not fix by fix. Do not
   force-push a branch someone has reviewed on GitHub without asking.

`concurrency` cancels a run that a newer push supersedes, but the minutes it used are already
spent.
- Releases are cut from tags with the `release` skill ([.claude/skills/release](.claude/skills/release/SKILL.md)).
  Nothing is released by merging.

## Layout

| Target | What it is | Tests |
|---|---|---|
| `ComposeModel` | The resolved spec types, and `KeySupportTable`: every compose key and whether it is supported, deferred or impossible, with a severity | through the parser and planner tests |
| `ComposeParser` | YAML to model: interpolation, `.env`, `env_file`, short and long forms, a line and column on every error | `ComposeParserTests` |
| `ComposePlanner` | Dependency graph, project identity and hashing, and `Planner.up` / `Planner.down`, which turn a file and a snapshot into ordered `Operation`s | `ComposePlannerTests` |
| `compose` (executable) | The plugin: parses, plans, prints, and carries out the plan in `Runtime.swift`. The only target that talks to the runtime | `ComposePluginTests` (`@testable import compose`) |

## Rules the code keeps

- **No key is silently ignored.** Every compose key is in `KeySupportTable`. An unsupported key
  refuses the file, naming the key, the service and the line; a key whose support depends on its
  value (such as `restart`) is decided in the parser with `note(...)`.
- **The planner decides, the runtime carries out.** Anything with a choice in it (ordering,
  whether a failure is fatal, which containers to recreate) belongs in the planner, where it is
  pure and tested. `Runtime.swift` only executes operations.
- **The service hash is a format.** `Service.canonicalDescription` feeds the hash stamped on every
  container, and any change to it recreates containers on the next `up`. A new field must add
  lines only when it is set, and a test pins the description of a plain service so an upgrade
  does not recreate everything.
- **A new `Operation` case reaches Orchard.** Orchard switches over `Operation`, so a new case
  needs an issue on `andrew-waters/orchard`.

## Adding or changing a compose key

Done means all of these, in the same pull request:

1. Model, parser and `KeySupportTable` entry, with parser tests for each form and each refusal.
2. Planner and runtime changes, with planner tests that compare whole operation structs, not
   only `summary` strings.
3. The README's **Scope** section.
4. The compatibility table in `site/index.html` (the "Coming from Docker Compose" matrix), which
   deploys to compose.andon.dev from main.

## Building and testing

Builds and test runs are slow and load the whole machine. Make every edit first, then run once,
capturing the output to a file, and scope the run where you can:

```bash
swift build
swift test --filter ComposePlannerTests     # or ComposeParserTests, ComposePluginTests
swift test                                  # before opening a pull request
```

CI skips commits and pull requests that only touch the harness's documents, Gannin's session
files, `.claude/`, the site or Markdown; the list is at the top of `.github/workflows/ci.yml`.
Otherwise it runs `make test`, then `make build` (a release build with the version stamped in), checks the
installed plugin layout, and fails if `Sources/compose/Version.swift` holds anything but the
`0.0.0-dev` placeholder. Never edit that version by hand.

To see a change working against the real runtime without installing it, use the `run` skill
([.claude/skills/run](.claude/skills/run/SKILL.md)).

## Writing

No em dashes, en dashes or ellipsis characters anywhere: code comments, docs, commits, pull
requests, issues, tag messages. No Claude attribution lines on commits or pull requests. Comments
explain why, in full sentences, at the density the surrounding code already has.
