# Standards for harness documents

Gannin reads the front matter of every document under `requirements/`, `plans/`, `findings/` and
`prompts/` to link it to issues and show it on the board. Keep the front matter exact; the body is
for people.

## Where things go

| Kind | Path | Template |
|---|---|---|
| Requirement | `requirements/<slug>.md` | [requirements/_template.md](requirements/_template.md) |
| Plan | `plans/YYYY-MM-DD-<slug>.md`, dated the day it was started | [plans/_template.md](plans/_template.md) |
| Finding | `findings/YYYY-MM-DD-<slug>.md`, dated the day it was learned | none; see below |
| Prompt | `prompts/<slug>.md` | see `prompts/planning-facilitator.md` |

The slug is the issue's slug where there is one (`docker-compose-post-start-pre-stop`), so a
requirement and its plan share it.

## Front matter

Every document has:

- `type`: `requirement`, `plan`, `finding` or `prompt`.
- `summary`: one sentence, in quotes, saying what it is for. Shown on the board.

Requirements and plans also have:

- `status`: one of
  - `draft`: being written; not agreed.
  - `in-progress`: agreed, and work against it has started.
  - `done`: every task has landed (plans), or every acceptance criterion is met by merged code
    (requirements).
  - `dropped`: decided against. Say why in the body.
- `issues`: every issue it is about, as `[owner/repo#N, ...]`. A plan lists the parent issue and
  each task's issue.

A requirement also has `plans: [plans/...md]`. A plan also has:

- `requirement`: the path of its requirement.
- `touches`: the repos it changes or depends on, as `[owner/repo, ...]`.
- `owner`: the GitHub handle accountable for it.
- `agreed_by` and `agreed_at`: who agreed the plan and the date (`YYYY-MM-DD`), once it is agreed.

A finding also has `issues` (the issue it came out of) and `tags`, a short list such as
`[runtime, apple-container]`.

## Plans

- Tasks are checkboxes, one per issue: `- [ ] [owner/repo#N](url) What it does (satisfies R1, R2)`.
  Tick each when its code is merged or, when the plan ships with the code, when it is committed on
  the branch.
- Every acceptance criterion in the requirement is satisfied by at least one task.
- Decisions are recorded as the question and the answer in bold, under the section they belong to,
  so the reasoning stays next to what it decided.
- Set `status: done` when the last task is ticked, and set the requirement to `done` when the code
  meeting it is merged.

## Findings

A finding is something learned while working that is not obvious from the code and will matter
again: a runtime behaviour, a library trap, a constraint upstream. One finding per file. Say what
was observed, how it was seen (a command, an error, a link), and what to do about it. If it turns
out to be wrong, delete it.

## Writing

No em dashes, en dashes or ellipsis characters. Plain hyphens for ranges.
