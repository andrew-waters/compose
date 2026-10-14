# andrew-waters/compose#15: Containers are never registered in Apple container's DNS: hostname lacks the trailing dot

https://github.com/andrew-waters/compose/issues/15

- State: open
- Opened by: @andrew-waters, 14 Oct 2026

## Description

(Not loaded in Gannin yet. `gh issue view 15 --repo andrew-waters/compose --comments` has it.)

## Working here

- You're in the team's harness, andrew-waters/compose, checked out at `~/Code/andrew-waters/compose`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/15-containers-are-never-registered-in-apple/`: give each repo it touches a worktree there, on the branch `15-containers-are-never-registered-in-apple`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/15-containers-are-never-registered-in-apple/<name>" -b 15-containers-are-never-registered-in-apple origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/compose itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/15-containers-are-never-registered-in-apple/compose" -b 15-containers-are-never-registered-in-apple origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/15-containers-are-never-registered-in-apple/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/compose#15" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/compose#15]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/15-containers-are-never-registered-in-apple/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
