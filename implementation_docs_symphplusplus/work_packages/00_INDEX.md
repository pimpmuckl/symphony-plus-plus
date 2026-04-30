# Work Package Index

Use this as the architecture agent's queue. Dependencies must be merged before dependent packages start unless the architecture agent explicitly creates a safe split.

## Phase overview

### Phase 0 — Baseline fork

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P0-001](SYMPP-P0-001_upstream-fork-baseline-and-local-run.md) | Upstream fork baseline and local run | setup | worker | none |
| [SYMPP-P0-002](SYMPP-P0-002_repository-map-and-extension-seam-analysis.md) | Repository map and extension seam analysis | analysis | worker | SYMPP-P0-001 |
| [SYMPP-P0-003](SYMPP-P0-003_Symphony-planning-assets-and-repo-conventions.md) | Symphony++ planning assets and repo conventions | docs | worker | SYMPP-P0-001 |

### Phase 1 — Core ledger

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P1-001](SYMPP-P1-001_workpackage-ledger-schema-and-repository-api.md) | WorkPackage ledger schema and repository API | core | worker | SYMPP-P0-002 |
| [SYMPP-P1-002](SYMPP-P1-002_accessgrant-and-workkey-service.md) | AccessGrant and WorkKey service | security | worker | SYMPP-P1-001 |
| [SYMPP-P1-003](SYMPP-P1-003_lifecycle-state-machine-and-policy-templates.md) | Lifecycle state machine and policy templates | core | worker | SYMPP-P1-001, SYMPP-P1-002 |
| [SYMPP-P1-004](SYMPP-P1-004_virtual-planning-file-renderers.md) | Virtual planning file renderers | core | worker | SYMPP-P1-001 |
| [SYMPP-P1-005](SYMPP-P1-005_audit-event-ledger-and-idempotency-keys.md) | Audit event ledger and idempotency keys | core | worker | SYMPP-P1-001, SYMPP-P1-002 |

### Phase 2 — Symphony adapter

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P2-001](SYMPP-P2-001_tracker-kind-Symphony-pp-adapter.md) | `tracker.kind: Symphony_pp` adapter | adapter | worker | SYMPP-P1-001, SYMPP-P1-003, SYMPP-P1-004 |
| [SYMPP-P2-002](SYMPP-P2-002_Symphony-workflow-config-and-dispatch-filters.md) | Symphony++ workflow config and dispatch filters | adapter | worker | SYMPP-P2-001 |
| [SYMPP-P2-003](SYMPP-P2-003_agentrun-binding-and-orchestrator-reconciliation.md) | AgentRun binding and orchestrator reconciliation | adapter | worker | SYMPP-P1-002, SYMPP-P2-001 |

### Phase 3 — Agent interface

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P3-001](SYMPP-P3-001_mcp-server-scaffold.md) | MCP server scaffold | mcp | worker | SYMPP-P1-002, SYMPP-P1-004 |
| [SYMPP-P3-002](SYMPP-P3-002_worker-mcp-tools-and-resources.md) | Worker MCP tools and resources | mcp | worker | SYMPP-P3-001, SYMPP-P1-004, SYMPP-P1-005 |
| [SYMPP-P3-003](SYMPP-P3-003_architect-mcp-tools.md) | Architect MCP tools | mcp | worker | SYMPP-P3-001, SYMPP-P1-002 |
| [SYMPP-P3-004](SYMPP-P3-004_codex-skill-package-and-workflow-prompts.md) | Codex Skill package and workflow prompts | skill | worker | SYMPP-P3-002 |
| [SYMPP-P3-005](SYMPP-P3-005_codex-hooks-and-guardrail-nudges.md) | Codex hooks and guardrail nudges | hooks | worker | SYMPP-P3-004 |

### Phase 4 — Quick work

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P4-001](SYMPP-P4-001_standalone-create-work-cli-api.md) | Standalone create-work CLI/API | product | worker | SYMPP-P1-002, SYMPP-P1-003, SYMPP-P1-004 |
| [SYMPP-P4-002](SYMPP-P4-002_quick-fix-hotfix-and-investigation-policy-templates.md) | Quick-fix, hotfix, and investigation policy templates | product | worker | SYMPP-P1-003, SYMPP-P4-001 |
| [SYMPP-P4-003](SYMPP-P4-003_end-to-end-standalone-hotfix-scenario.md) | End-to-end standalone hotfix scenario | e2e | worker | SYMPP-P3-002, SYMPP-P4-001, SYMPP-P4-002 |

### Phase 5 — Dashboard

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P5-001](SYMPP-P5-001_dashboard-api-endpoints.md) | Dashboard API endpoints | dashboard | worker | SYMPP-P1-004, SYMPP-P1-005, SYMPP-P2-003 |
| [SYMPP-P5-002](SYMPP-P5-002_dashboard-board-ui.md) | Dashboard board UI | dashboard | worker | SYMPP-P5-001 |
| [SYMPP-P5-003](SYMPP-P5-003_work-package-detail-ui-and-timeline.md) | Work package detail UI and timeline | dashboard | worker | SYMPP-P5-001 |
| [SYMPP-P5-004](SYMPP-P5-004_runtime-observability-and-alerts.md) | Runtime observability and alerts | dashboard | worker | SYMPP-P2-003, SYMPP-P5-001 |

### Phase 6 — GitHub/review integration

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P6-001](SYMPP-P6-001_github-pr-attachment-and-sync.md) | GitHub PR attachment and sync | integration | worker | SYMPP-P4-003, SYMPP-P5-001 |
| [SYMPP-P6-002](SYMPP-P6-002_review-suite-artifact-contract.md) | Review-suite artifact contract | integration | worker | SYMPP-P4-003 |
| [SYMPP-P6-003](SYMPP-P6-003_changed-file-scope-guard-and-readiness-gates.md) | Changed-file scope guard and readiness gates | security | worker | SYMPP-P6-001, SYMPP-P6-002, SYMPP-P1-003 |

### Phase 7 — Phase/architect delegation

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P7-001](SYMPP-P7-001_phase-entity-and-architect-grants.md) | Phase entity and architect grants | delegation | worker | SYMPP-P1-002, SYMPP-P1-003 |
| [SYMPP-P7-002](SYMPP-P7-002_child-work-creation-and-worker-key-minting.md) | Child work creation and worker-key minting | delegation | worker | SYMPP-P7-001, SYMPP-P3-003 |
| [SYMPP-P7-003](SYMPP-P7-003_architect-approval-and-merge-to-phase-workflow.md) | Architect approval and merge-to-phase workflow | delegation | worker | SYMPP-P7-002, SYMPP-P6-003 |

### Phase 8 — Hardening and pilot

| ID | Title | Kind | Owner | Dependencies |
|---|---|---|---|---|
| [SYMPP-P8-001](SYMPP-P8-001_full-integration-test-harness.md) | Full integration test harness | hardening | worker | SYMPP-P4-003, SYMPP-P6-003, SYMPP-P7-003 |
| [SYMPP-P8-002](SYMPP-P8-002_security-hardening-and-audit-review.md) | Security hardening and audit review | security | worker | SYMPP-P6-003, SYMPP-P7-002 |
| [SYMPP-P8-003](SYMPP-P8-003_kraken-pilot-migration-playbook.md) | Kraken pilot migration playbook | pilot | architect | SYMPP-P8-001, SYMPP-P8-002 |
| [SYMPP-P8-004](SYMPP-P8-004_documentation-release-readiness-and-operator-training.md) | Documentation, release readiness, and operator training | docs | worker | SYMPP-P8-001, SYMPP-P8-002 |

