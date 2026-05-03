# Task Plan: SYMPP-P4-001 Standalone Create Work CLI/API

## Goal

Implement only SYMPP-P4-001: a standalone create-work service plus human-facing command that creates one parentless WorkPackage, mints one worker grant, returns the one-time raw secret only in the creation response, renders initial virtual planning files, and documents quick-fix/hotfix usage.

## Plan

- [x] Read package spec and repo instructions.
- [x] Inspect existing WorkPackage, AccessGrant, lifecycle policy, virtual planning renderer, MCP worker, and Mix task patterns.
- [x] Confirm P1-002, P1-003, and P1-004 dependency surfaces exist in this branch.
- [x] Add a tight create-work service API that validates required inputs, applies kind policy defaults, creates a parentless package, appends initial plan context, mints exactly one worker grant, and renders virtual files.
- [x] Add a `mix sympp.create_work` command that accepts JSON/YAML file input plus `--database` and prints a redacted JSON result containing the one-time secret only at creation.
- [x] Add focused unit/integration tests for parsing, required fields, policy defaults, one-grant minting, parentless creation, virtual rendering, worker MCP claim, and no normal-read secret exposure.
- [x] Update directly relevant docs/examples for quick-fix and hotfix usage.
- [x] Run focused tests, formatting, specs, and lint.
- [ ] Commit, push, open PR, and complete T1/T2/GitHub review cycle on the final pushed head.

## Boundaries

- Do not implement SYMPP-P4-002, SYMPP-P4-003, dashboard, Phase 6, Phase 7, live Linear creation, or runtime defaults outside this package.
- Do not log, commit, or persist raw worker secrets. The raw worker secret appears only in the create response.
- Preserve existing Symphony and Symphony++ behavior unless the package explicitly requires the create-work path.

## Blockers

None currently.
