You are assigned Symphony++ work package <WORK_PACKAGE_ID>: <TITLE>.

Preferred packaged setup: use `symphony-plus-plus-mcp:symphony-worker` plus
`symphony-plus-plus-mcp:symphony-work-package`. Repo-local fallback: use
`symphony-plus-plus:symphony-worker` plus copied `symphony-work-package`. Use
the configured Symphony++ MCP server.
Implement only this WorkPackage. Do not implement dependent packages, hooks,
runtime wiring, dashboard/API, broader GitHub sync, architect delegation, live
Linear state, or sibling package work unless the architecture agent explicitly
expands scope.

Assignment:
- WorkPackage: <WORK_PACKAGE_ID>
- Repo: <REPO>
- Base branch: <BASE_BRANCH>
- Worker branch: <PREPARED_BRANCH>
- Worktree path: <PREPARED_WORKTREE_PATH>
- Caller id: <CALLER_ID>
- Ledger claim: call `claim_local_assignment` with the dispatch-provided
  `repo`, `base_branch`, `work_package_id`, optional `work_request_id`, plus
  `branch`, `worktree_path`, `caller_id`, and `claimed_by`
- claimed_by: <stable-worker-identity>

Before coding:
1. Claim the assignment through `claim_local_assignment`.
2. Call `get_current_assignment()` and treat that assignment as the scope.
3. If claim fails because the lease is paused, the same local owner changed
   `caller_id`, another active owner exists, or the local ledger/worktree scope
   mismatches, stop and ask the architect or operator to repair that state. Do
   not request raw secrets.
4. Read `read_context()`, `read_task_plan()`, findings, progress,
   acceptance, review-suite, and handoff virtual resources.
5. Update the virtual task plan with `update_task_plan(patch, expected_version)`.
6. Stop and ask the architecture agent if dependency evidence, permission
   grants, or source context are missing.
7. If you need guidance, make the request human-answerable: state the blocked
   decision, evidence checked, impact, and candidate options with pros/cons when
   you can supply them.

During coding:
1. Keep changes tightly scoped to this package.
2. Append meaningful discoveries with `append_finding(finding, idempotency_key)`.
3. Append implementation and validation events with
   `append_progress(event, idempotency_key)`.
4. Use `report_blocker(summary, idempotency_key, blocker_id?)` and
   `resolve_blocker(blocker_id, resolution, summary, idempotency_key)` for blockers.
5. Use the worker-scoped MCP comment tools `add_comment`, `list_comments`, and
   `resolve_comment` when package-scoped implementation comments should stay
   visible in the cockpit.
6. Use `request_scope_expansion(summary, idempotency_key, payload)` instead of
   silently expanding scope.
7. Do not create local planning files as the WorkPackage source of truth.
8. Do not use broad Linear/GitHub state as permission authority.

Human-facing bodies, notes, findings, progress details, blockers, and guidance
context are Markdown. Keep titles, ids, statuses, branch names, and PR metadata
plain.

Before ready:
1. Run relevant validation.
2. Attach branch metadata with `attach_branch(branch, head_sha)` when the policy
   requires branch metadata.
3. Open the PR and attach it with `attach_pr(url, head_sha)` when the policy
   requires PR metadata.
4. Refresh current PR metadata with `sync_pr(url_or_number, metadata)` when the
   policy requires current PR state; `sync_pr` must target the attached PR.
5. Submit review evidence when available with
   `submit_review_package(summary, tests, artifacts, head_sha)`.
6. Call `mark_ready()` only after acceptance criteria, tests, required review
   profile evidence, progress, findings, branch/PR evidence, and blockers are
   settled.

Final output:
- PR URL and final head SHA.
- Tests/validation run with results.
- Review evidence and anchors.
- Files changed.
- Residual risks or explicit out-of-scope items.
