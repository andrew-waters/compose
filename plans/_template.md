---
type: plan
status: draft
summary: "One sentence: what this plan delivers, and for which issue."
issues: [andrew-waters/compose#N]
touches: [andrew-waters/compose]
owner: github-handle
agreed_by: []
agreed_at:
requirement: requirements/<slug>.md
---

# Title

One or two sentences: what changes for whom, and what is out of scope.

## Requirement

In full in [requirements/&lt;slug&gt;.md](../requirements/<slug>.md). Copy its Problem, Goal, Who
it's for, Scope, Out of scope and Acceptance criteria here once it is agreed, so the plan reads
on its own.

**Decisions:**

- Question asked while settling the requirement? **The answer, in bold.**

## Design

What changes, target by target (model, parser, planner, plugin runtime, docs), in the order the
data flows. Say where each decision lives and why, especially anything the planner decides that
the runtime then carries out.

**Areas it touches:**

- `owner/repo` `path/to/File.swift#L1-L20`: what is there today and what changes.

**Patterns to follow:**

- `owner/repo` `path/to/File.swift#L1-L20`: the existing code this should look like, and why.

**Risks:**

- `owner/repo` `path`: what could go wrong or surprise someone, and who needs to know.

**Decisions:**

- Design question? **The answer, in bold.**

## Tasks

Each task is one issue, small enough to review in one sitting, and says which acceptance criteria
it satisfies. Tick it when it lands.

- [ ] [andrew-waters/compose#N](https://github.com/andrew-waters/compose/issues/N) What it does (satisfies R1, R2)
- [ ] [andrew-waters/compose#N](https://github.com/andrew-waters/compose/issues/N) Document it in the README Scope section and the site's compatibility table (satisfies Rn)

**Decisions:**

- Are the tasks right? **The answer, in bold.**

## Open questions

- Anything not yet decided, and who decides it.
