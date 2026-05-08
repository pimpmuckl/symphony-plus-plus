# Symphony++ Operator Documentation

This directory is the durable operator/product guide for Symphony++. It explains
how the current system works: how operators create packages, how workers and
architects claim scoped grants, how MCP-backed planning resources are updated,
and how readiness evidence flows into human merge decisions.

Historical phase and package notes are not the active source of truth. Current
work starts from live WorkPackages, operator-approved package requests, MCP
resources, and the docs below.

## Contents

- `docs/` - operator guide, product spec, permission, MCP, testing, dashboard,
  GitHub, release, and role-boundary documents.
- `templates/` - worker/architect/reviewer prompts, Symphony++ workflow
  template, skill template, status templates, quick-work examples, and optional
  Codex hook nudges.
- `mcp/` - MCP tool/resource contracts for Symphony++.
- `schemas/` - JSON schema sketches for core records.
- `review/` - review-suite contract and readiness-gate definitions.
- `runbooks/` - hotfix, incident, migration, and pilot runbooks. Pilot
  migration notes are historical/conditional unless an operator explicitly
  assigns that pilot.

## Start Here

- Product/operator guide: `docs/01_IMPLEMENTATION_GUIDE.md`
- Role-oriented walkthrough: `docs/12_OPERATOR_TRAINING.md`
- Short command-flow runbook: `docs/09_OPERATIONAL_RUNBOOK.md`
- Release gate: `docs/11_RELEASE_VALIDATION.md`
- Security and guardrails: `docs/06_SECURITY_AND_GUARDRAILS.md`
- MCP and skill contract: `docs/04_MCP_AND_SKILL_CONTRACT.md`
- Local plugin install/refresh: `../plugins/symphony-plus-plus/README.md`

## Merge Policy

- One WorkPackage = one PR unless the overseeing architecture agent explicitly
  splits or combines scope.
- Every PR must record acceptance evidence, tests run, and any blocked
  validation.
- Workers may request scope expansion, but cannot silently expand scope.
- Human merge remains gated by branch protection, review-suite evidence, and
  package-specific readiness.
