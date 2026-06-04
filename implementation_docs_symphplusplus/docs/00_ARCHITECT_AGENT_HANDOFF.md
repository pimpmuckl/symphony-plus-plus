# Architect Agent Handoff: Symphony++

Use this when an operator assigns an architect to clarify a WorkRequest,
organize a product plan, sequence a phase, or coordinate multiple related
Symphony++ execution records. Current architecture work starts from the
WorkRequest, its optional product plan tree, planned slices, live linked
WorkPackage records, and the product/operator docs in this directory.

For Codex, use the plugin-installed
`symphony-plus-plus-mcp:symphony-architect` skill, backed by
`plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md`, as the
practical playbook for WorkRequest-led product planning. It complements the
`symphony-plus-plus-mcp:symphony-work-package` worker skill: architects clarify,
decide, slice, dispatch, and route guidance; workers implement one dispatched
planned slice through its linked WorkPackage execution record.

V3 product-tree note: the cockpit is WorkRequest-first. Product plan nodes are
optional, architect-authored product groupings for larger requests. Planned
slices are the architect-to-worker execution units. WorkPackages remain
downstream execution/audit records for grants, worktrees, PRs, findings,
progress, reviews, and readiness evidence.

## Operating Model

- Keep one worker PR per dispatched planned slice/WorkPackage unless the
  operator explicitly approves a split or combined scope.
- Use the WorkRequest and optional product tree as the product-facing source of
  truth. Use the WorkPackage ledger and MCP resources as the source of truth
  for worker execution state, virtual planning files, findings, progress,
  acceptance, and review evidence.
- For WorkRequest-led lanes, use the scoped WorkRequest MCP tools where
  available to read requests, ask/answer/close questions, record decisions,
  author/approve/skip planned slices, mark the WorkRequest sliced after
  approved slices satisfy the request, dispatch approved slices, and route
  guidance. If MCP is unavailable, record the blocker and use the
  dashboard/operator-approved artifact as fallback.
- For trusted local HTTP WorkRequest architect lanes, normal claim/reconnect is
  `claim_local_architect_assignment` when `local_architect_claim` is present.
  `claim_private_handoff` is recovery-only for that path and remains the
  fallback when local claim metadata is absent.
- Preserve upstream Symphony and Linear behavior unless the assigned package
  explicitly changes that surface.
- Keep phase branches explainable. Stop if the phase can no longer be
  summarized in a short status note with merged packages, open blockers,
  validation, and residual risks.
- Do not put raw worker grants, bearer tokens, GitHub tokens, Linear tokens, or
  MCP auth material into files, logs, PR bodies, or review text.

## Dispatch Workers

For each worker, send:

1. The planned-slice goal plus linked WorkPackage id, target branch, base
   branch, owned paths, acceptance criteria, and required review-suite lanes.
2. The verbatim prompt in `templates/worker_agent_prompt.md`.
3. The `symphony-plus-plus-mcp:symphony-work-package` skill package from the
   `plugins/symphony-plus-plus-mcp/` Codex plugin, `.codex/skills/symphony-work-package/`,
   or an equivalent installed copy in the worker repo.
4. MCP setup for the Symphony++ local HTTP server; see
   `.codex/skills/symphony-work-package/references/mcp_wiring.md`.
5. The `claim_local_assignment` metadata plus prepared branch, worktree path,
   caller id, and stable `claimed_by`.
6. Any dependency summaries or operator decisions needed to avoid scope drift.

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
- Implementing workers ran the required current-head review profile. When
  Review Suite is installed, that means the current orchestrator profile
  (`brief`, `normal`, `deep`, or `emergency`). When it is not installed,
  workers must still report review progress and final evidence through
  Symphony++ MCP. After material changes, rerun the same required review
  profile. GitHub review remains an additional anchored step only when package
  policy requires it.

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
