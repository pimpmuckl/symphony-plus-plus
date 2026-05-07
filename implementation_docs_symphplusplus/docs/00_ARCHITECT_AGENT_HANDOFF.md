# Architect Agent Handoff: Symphony++

Use this when an operator assigns an architect to sequence a phase or coordinate
multiple related Symphony++ WorkPackages. The original static implementation
backlog is complete; current architecture work starts from the operator's
package request, live WorkPackage records, and the product/operator docs in this
directory.

## Operating Model

- Keep one worker PR per WorkPackage unless the operator explicitly approves a
  split or combined scope.
- Use the current WorkPackage ledger and MCP resources as the source of truth
  for package state, virtual planning files, findings, progress, acceptance,
  and review evidence.
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
3. The `symphony-work-package` skill package from
   `.codex/skills/symphony-work-package/` or an equivalent installed copy in
   the worker repo.
4. MCP setup for the Symphony++ stdio server; see
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

## Stop Conditions

Pause and ask the operator if:

- A worker needs access outside the granted WorkPackage scope.
- A reviewer request would turn the lane into runtime redesign, package
  semantics changes, or broad historical cleanup.
- Grant enforcement, sibling access denial, or secret redaction behavior is
  uncertain.
- The branch cannot be explained in one concise phase summary.
