# Architect Agent Handoff: Symphony++

Use this when an operator assigns an architect to sequence a phase or coordinate
multiple related Symphony++ WorkPackages. Current architecture work starts from
the operator's package request, live WorkPackage records, and the
product/operator docs in this directory.

For Codex, use the plugin-installed
`symphony-plus-plus-mcp:symphony-architect` skill, backed by
`plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md`, as the
practical playbook for v2 WorkRequest-led orchestration. It complements the
`symphony-plus-plus-mcp:symphony-work-package` worker skill: architects clarify,
decide, slice, dispatch, and route guidance; workers implement one dispatched
package.

## Operating Model

- Keep one worker PR per WorkPackage unless the operator explicitly approves a
  split or combined scope.
- Use the current WorkPackage ledger and MCP resources as the source of truth
  for package state, virtual planning files, findings, progress, acceptance,
  and review evidence.
- For v2 WorkRequest-led lanes, use the scoped WorkRequest MCP tools where
  available to read requests, ask/answer/close questions, record decisions,
  author/approve/skip planned slices, mark the WorkRequest sliced after
  approved slices satisfy the request, dispatch approved slices, and route
  guidance. If MCP is unavailable, record the blocker and use the
  dashboard/operator-approved artifact as fallback.
- Preserve upstream Symphony and Linear behavior unless the assigned package
  explicitly changes that surface.
- Keep phase branches explainable. Stop if the phase can no longer be
  summarized in a short status note with merged packages, open blockers,
  validation, and residual risks.
- Do not put raw worker grants, bearer tokens, GitHub tokens, Linear tokens, or
  MCP auth material into files, logs, PR bodies, or review text.

## Dispatch Workers

For each worker, send:

1. The WorkPackage id, target branch, base branch, owned paths, acceptance
   criteria, and required review-suite lanes.
2. The verbatim prompt in `templates/worker_agent_prompt.md`.
3. The `symphony-plus-plus-mcp:symphony-work-package` skill package from the
   `plugins/symphony-plus-plus-mcp/` Codex plugin, `.codex/skills/symphony-work-package/`,
   or an equivalent installed copy in the worker repo.
4. MCP setup for the Symphony++ local HTTP server; see
   `.codex/skills/symphony-work-package/references/mcp_wiring.md`.
5. Any dependency summaries or operator decisions needed to avoid scope drift.

Worker PR title format:

```text
[SYMPP-...] <package title>
```

## Review Responsibilities

For every worker PR, check:

- Scope matches the assigned package and owned paths.
- Acceptance criteria are explicitly satisfied.
- Validation and review-suite evidence are current for the PR head.
- No raw secret logging or accidental broad access is introduced.
- Existing Symphony behavior is preserved unless the package explicitly changes
  it.
- Findings, progress, blocker resolution, branch, PR, and readiness evidence
  are updated through the MCP-backed WorkPackage state.
- Implementing workers ran the required review-suite ladder. T1 comes before
  T2, but once T2 is reached the lane does not step down to T1; after
  GitHub-review fixes, rerun T2 plus GitHub review only.

## Stop Conditions

Pause and ask the operator if:

- A worker needs access outside the granted WorkPackage scope.
- A reviewer request would turn the lane into runtime redesign, package
  semantics changes, or broad historical cleanup.
- A reviewer request implies new product behavior not recorded in the
  WorkRequest, decision log, or operator-approved package scope.
- Grant enforcement, sibling access denial, or secret redaction behavior is
  uncertain.
- The branch cannot be explained in one concise phase summary.
