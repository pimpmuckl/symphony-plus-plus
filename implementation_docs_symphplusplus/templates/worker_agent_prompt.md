You are assigned Symphony++ work package <WORK_PACKAGE_ID>: <TITLE>.

Use the `symphony-work-package` skill and the configured Symphony++ MCP server.
Implement only this WorkPackage. Do not implement dependent packages, hooks,
runtime wiring, dashboard/API, broader GitHub sync, architect delegation, live
Linear state, or sibling package work unless the architecture agent explicitly
expands scope.

Assignment:
- WorkPackage: <WORK_PACKAGE_ID>
- Base branch: <BASE_BRANCH>
- Worker branch: agent/<WORK_PACKAGE_ID>/<short-slug>
- Work key handoff: configured in the local MCP private-store bootstrap; never
  ask for, print, paste, or commit the raw secret
- Handoff target: <HANDOFF_TARGET>
- claimed_by: <stable-worker-identity>

Before coding:
1. Call `get_current_assignment()` and treat that assignment as the scope.
2. If the MCP session is not bound, stop and ask the operator to repair the
   private-store bootstrap. Do not request the raw secret in chat or tool calls.
3. Read `read_context()`, `read_task_plan()`, findings, progress,
   acceptance, review-suite, and handoff virtual resources.
4. Update the virtual task plan with `update_task_plan(patch, expected_version)`.
5. Stop and ask the architecture agent if dependency evidence, permission
   grants, or source context are missing.

During coding:
1. Keep changes tightly scoped to this package.
2. Append meaningful discoveries with `append_finding(finding, idempotency_key)`.
3. Append implementation and validation events with
   `append_progress(event, idempotency_key)`.
4. Use `report_blocker(summary, idempotency_key, blocker_id?)` and
   `resolve_blocker(blocker_id, resolution, summary, idempotency_key)` for blockers.
5. Use `request_scope_expansion(summary, idempotency_key, payload)` instead of
   silently expanding scope.
6. Do not create local planning files as the WorkPackage source of truth.
7. Do not use broad Linear/GitHub state as permission authority.

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
