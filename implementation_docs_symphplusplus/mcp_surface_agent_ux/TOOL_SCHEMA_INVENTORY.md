# MCP Tool Schema Inventory

Current table generated from `implementation_docs_symphplusplus/mcp/mcp_tools_contract.json` during the final MCP surface sweep. The JSON contract remains the source of truth; use this table to scan the live compact contract alongside `ROADMAP.md`.

Contract version: 3. Tool schemas: 79.

2026-06-12 cleanup note: claim schemas still accept compatible optional hint fields, but `mcp_tools_contract.json` separates them as `advanced_hint_arguments`. Normal prompts and generated architect handoffs use durable ids by default; optional `claimed_by` stays accepted for explicit audit ownership but is not copied into architect handoff prompt claim arguments.

| Tool | Discovery groups | Required args | Required argument sets | Optional args | Scout classification |
|---|---|---|---|---|---|
| `sympp.health` | unbound_tools, bound_worker_tools, bound_architect_tools | none | none | none | keep |
| `release_current_assignment` | unbound_tools, bound_worker_tools, bound_architect_tools | none | none | reason | normalize error/output |
| `solo_attach` | unbound_tools | base_branch, caller_id, repo, workspace_path | none | title | infer/default |
| `solo_show` | unbound_tools | session_id | none | none | keep |
| `solo_list` | unbound_tools | none | none | base_branch, caller_id, repo, status, workspace_path | infer/default |
| `solo_record_task_plan` | unbound_tools | session_id, summary | none | body, idempotency_key, payload, status | infer/default |
| `solo_append_progress` | unbound_tools | session_id, summary | none | body, idempotency_key, payload, status | infer/default |
| `solo_append_finding` | unbound_tools | session_id, summary | none | body, idempotency_key, payload, severity, status | infer/default |
| `solo_record_decision` | unbound_tools | decision, session_id | none | body, idempotency_key, payload, rationale, scope_impact | infer/default |
| `solo_report_blocker` | unbound_tools | session_id, summary | none | blocker_id, body, idempotency_key, payload | infer/default |
| `solo_resolve_blocker` | unbound_tools | blocker_id, resolution, session_id | none | body, idempotency_key, payload, summary | infer/default |
| `solo_record_validation` | unbound_tools | result, session_id, summary | none | body, command, evidence, idempotency_key, payload | infer/default |
| `solo_pause` | unbound_tools | session_id | none | none | keep |
| `solo_resume` | unbound_tools | session_id | none | none | keep |
| `solo_complete` | unbound_tools | session_id | none | none | keep |
| `solo_archive` | unbound_tools | session_id | none | none | keep |
| `claim_local_assignment` | unbound_tools | work_package_id | none | claimed_by; advanced hints: base_branch, branch, caller_id, repo, work_request_id, worktree_path | normalize error/output |
| `claim_local_architect_assignment` | unbound_tools | work_request_id | none | claimed_by; advanced hints: architect_anchor_work_package_id, base_branch, caller_id, phase_id, repo | normalize error/output |
| `create_work_request` | unbound_tools | base_branch, repo, request_kind, title | description or human_description | claimed_by, constraints, created_by_kind, created_by_name, created_via, creator_kind, creator_name, description, human_description, status, workflow_mode | keep |
| `add_work_request_comment` | trusted_local_http_extra_tools | body, created_by, work_request_id | none | none | keep |
| `record_work_request_operator_decision` | trusted_local_http_extra_tools | created_by, decision, rationale, scope_impact, work_request_id | none | source_id | keep |
| `get_current_assignment` | bound_worker_tools, bound_architect_tools, worker_tools | none | none | none | keep |
| `read_context` | bound_worker_tools, worker_tools | none | none | none | keep |
| `read_task_plan` | bound_worker_tools, worker_tools | none | none | none | keep |
| `update_task_plan` | bound_worker_tools, worker_tools | expected_version | none | body, id, patch, status, title, work_package_id | infer/default |
| `append_finding` | bound_worker_tools, worker_tools | body, title | none | id, idempotency_key, severity, work_package_id | infer/default |
| `append_progress` | bound_worker_tools, worker_tools | summary | none | body, idempotency_key, payload, status, work_package_id | infer/default |
| `set_status` | bound_worker_tools, worker_tools | expected_status, status | none | reason, work_package_id | infer/default |
| `report_blocker` | bound_worker_tools, worker_tools | summary | none | blocker_id, body, idempotency_key, payload, status, work_package_id | infer/default |
| `resolve_blocker` | shared_worker_architect_tools, bound_worker_tools, bound_architect_tools, architect_tools, worker_tools | blocker_id, resolution, summary | none | body, idempotency_key, payload, status, work_package_id | infer/default |
| `add_comment` | shared_worker_architect_tools, bound_worker_tools, bound_architect_tools, architect_tools, worker_tools | body | none | target_id, target_kind, work_package_id | infer/default |
| `list_comments` | shared_worker_architect_tools, bound_worker_tools, bound_architect_tools, architect_tools, worker_tools | none | none | target_id, target_kind, work_package_id | infer/default |
| `resolve_comment` | shared_worker_architect_tools, bound_worker_tools, bound_architect_tools, architect_tools, worker_tools | comment_id | none | resolution_note, work_package_id | infer/default |
| `create_guidance_request` | bound_worker_tools, worker_tools | context, question, summary | none | idempotency_key, work_package_id | infer/default |
| `read_guidance_request` | shared_worker_architect_tools, bound_worker_tools, bound_architect_tools, architect_tools, worker_tools | guidance_request_id | none | work_package_id | infer/default |
| `request_scope_expansion` | bound_worker_tools, worker_tools | summary | none | body, idempotency_key, payload, status, work_package_id | infer/default |
| `attach_branch` | bound_worker_tools, worker_tools | branch, head_sha | none | body, idempotency_key, payload, status, summary, work_package_id | infer/default |
| `attach_pr` | bound_worker_tools, worker_tools | none | url or number | body, head_sha, idempotency_key, metadata, number, payload, repository, status, summary, url, work_package_id | infer/default |
| `sync_pr` | bound_worker_tools, worker_tools | metadata | none | body, head_sha, idempotency_key, number, payload, repository, status, summary, url, work_package_id | infer/default |
| `submit_review_package` | bound_worker_tools, worker_tools | artifacts, summary, tests | none | acceptance_criteria_met, body, head_sha, idempotency_key, payload, reviews, status, work_package_id | infer/default |
| `attach_review_suite_result` | bound_worker_tools, worker_tools | none | none | anchor, head_sha, idempotency_key, lane, profile, reviewer, round_id, status, suite, summary, verdict, work_package_id | normalize error/output |
| `mark_ready` | bound_worker_tools, worker_tools | none | none | none | keep |
| `create_child_work_package` | bound_architect_tools, architect_tools | package | none | none | keep |
| `mint_child_worker_key` | bound_architect_tools, architect_tools | work_package_id | none | template | rename/reword |
| `revoke_child_worker_key` | bound_architect_tools, architect_tools | grant_id, reason | none | none | rename/reword |
| `list_work_requests` | bound_architect_tools, architect_tools | none | none | status | keep |
| `read_work_request` | bound_architect_tools, architect_tools | work_request_id | none | include_planning_scratch | infer/default |
| `read_work_request_product_tree` | bound_architect_tools, architect_tools | work_request_id | none | include_planning_scratch, view | infer/default |
| `read_work_request_delivery_board` | bound_architect_tools, architect_tools | work_request_id | none | include_planning_scratch | infer/default |
| `reconcile_work_request` | bound_architect_tools, architect_tools | work_request_id | none | apply, recorded_by | keep |
| `cleanup_work_request_planned_slice_runtime` | bound_architect_tools, architect_tools | outcome, planned_slice_id, reason, work_request_id | none | abandoned_rationale, successor_planned_slice_id, successor_work_package_id, superseded_reason | rename/reword |
| `record_planned_slice_delivery` | bound_architect_tools, architect_tools | idempotency_key, outcome, planned_slice_id, work_request_id | none | abandoned_rationale, merge_commit_sha, no_pr_evidence, pr_merged_at, pr_number, pr_repository, pr_url, recorded_by, successor_planned_slice_id, successor_work_package_id, superseded_reason | keep |
| `revoke_planned_slice_worker_key` | bound_architect_tools, architect_tools | grant_id, planned_slice_id, reason, work_request_id | none | none | rename/reword |
| `list_guidance_requests` | bound_architect_tools, architect_tools | none | none | status, work_package_id, work_request_id | infer/default |
| `answer_guidance_request` | bound_architect_tools, architect_tools | answer, guidance_request_id | none | answered_by | keep |
| `escalate_guidance_request` | bound_architect_tools, architect_tools | guidance_request_id, reason, recommended_language | none | decision_prompt | keep |
| `set_work_request_status` | bound_architect_tools, architect_tools | current_status, next_status, work_request_id | none | none | infer/default |
| `ask_work_request_question` | bound_architect_tools, architect_tools | category, question, why_needed, work_request_id | none | asked_by_agent_run_id, decision_prompt | infer/default |
| `answer_work_request_question` | bound_architect_tools, architect_tools | answer, question_id, work_request_id | none | answered_by, current_status, expected_question_status | infer/default |
| `answer_work_request_question_and_record_decision` | bound_architect_tools, architect_tools | answer, decision, question_id, rationale, scope_impact, source_type, work_request_id | none | answered_by, created_by, current_status, expected_question_status, source_id | infer/default |
| `close_work_request_question` | bound_architect_tools, architect_tools | question_id, work_request_id | none | current_status, expected_question_status | infer/default |
| `record_work_request_decision` | bound_architect_tools, architect_tools | created_by, decision, rationale, scope_impact, source_type, work_request_id | none | source_id | infer/default |
| `add_work_request_planned_slice` | bound_architect_tools, architect_tools | acceptance_criteria, forbidden_file_globs, goal, owned_file_globs, review_lanes, stop_conditions, target_base_branch, title, validation_steps, work_package_kind, work_request_id | none | branch_pattern | infer/default |
| `upsert_work_request_product_plan_node` | bound_architect_tools, architect_tools | title, work_request_id | none | completion_mark, created_by, description, node_kind, parent_id, position, product_tree_node_id | infer/default |
| `move_work_request_planned_slice_to_product_node` | bound_architect_tools, architect_tools | planned_slice_id, work_request_id | none | created_by, position, product_tree_node_id, role | rename/reword |
| `approve_work_request_planned_slice` | bound_architect_tools, architect_tools | current_status, planned_slice_id, work_request_id | none | none | infer/default |
| `skip_work_request_planned_slice` | bound_architect_tools, architect_tools | current_status, planned_slice_id, work_request_id | none | none | infer/default |
| `mark_work_request_sliced` | bound_architect_tools, architect_tools | current_status, work_request_id | none | none | infer/default |
| `dispatch_work_request_planned_slice` | bound_architect_tools, architect_tools | planned_slice_id, work_request_id | none | claimed_by | infer/default |
| `prepare_work_package_worktree` | bound_architect_tools, architect_tools | work_package_id | none | branch, target_repo_root | keep |
| `cleanup_work_package_worktree` | bound_architect_tools, architect_tools | work_package_id | none | target_repo_root | keep |
| `read_child_status` | bound_architect_tools, architect_tools | work_package_id | none | none | keep |
| `approve_scope_expansion` | bound_architect_tools, architect_tools | allowed_file_globs, rationale, work_package_id | none | request_id | keep |
| `read_phase_board` | bound_architect_tools, architect_tools | phase_id | none | none | keep |
| `request_child_replan` | bound_architect_tools, architect_tools | reason, work_package_id | none | none | remove/simplify |
| `approve_child_ready_state` | bound_architect_tools, architect_tools | rationale, work_package_id | none | request_id | keep |
| `merge_child_into_phase` | bound_architect_tools, architect_tools | merge_artifact, work_package_id | none | none | keep |
| `split_work_package` | bound_architect_tools, architect_tools | child_specs, work_package_id | none | none | remove/simplify |
| `publish_phase_update` | bound_architect_tools, architect_tools | phase_id, update | none | none | remove/simplify |
