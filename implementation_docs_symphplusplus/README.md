# Symphony++ Operator Documentation

This directory contains the current Symphony++ product, operator, security,
MCP, review, release, template, schema, and runbook contracts.

The original P0-P8 implementation backlog has completed and is no longer the
active source of truth. Current work should be driven from live WorkPackages,
operator-created package requests, MCP resources, and the docs below.

## Contents

- `docs/` - product, permission, MCP, testing, dashboard, GitHub, operator,
  release, and role-boundary documents.
- `templates/` - worker/architect/reviewer prompts, Symphony++ workflow
  template, skill template, status templates, quick-work examples, and optional
  Codex hook nudges.
- `mcp/` - MCP tool/resource contracts for Symphony++.
- `schemas/` - JSON schema sketches for core records.
- `review/` - review-suite contract and readiness-gate definitions.
- `runbooks/` - hotfix, incident, migration, and pilot runbooks.

## Operator Entry Points

- Role-oriented walkthrough: `docs/12_OPERATOR_TRAINING.md`
- Short command-flow runbook: `docs/09_OPERATIONAL_RUNBOOK.md`
- Release gate: `docs/11_RELEASE_VALIDATION.md`
- Security and guardrails: `docs/06_SECURITY_AND_GUARDRAILS.md`
- MCP and skill contract: `docs/04_MCP_AND_SKILL_CONTRACT.md`

## Merge Policy

- One WorkPackage = one PR unless the overseeing architecture agent explicitly
  splits or combines scope.
- Every PR must record acceptance evidence, tests run, and any blocked
  validation.
- Workers may request scope expansion, but cannot silently expand scope.
- Human merge remains gated by branch protection, review-suite evidence, and
  package-specific readiness.
