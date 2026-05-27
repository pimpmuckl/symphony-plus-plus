# V2.1 Final Local Cutover

This runbook is for the architect/operator after the final V2.1 WorkPackage PR
has landed into `feature/sympp-v21-ledger-claims`. Worker PRs must not execute
these local adoption steps.

## Preconditions

- All V2.1 WorkPackage PRs are merged into `feature/sympp-v21-ledger-claims`.
- The feature branch is current with `origin/main`:

```powershell
git fetch origin main feature/sympp-v21-ledger-claims
git merge-base --is-ancestor origin/main origin/feature/sympp-v21-ledger-claims
```

- The final PR records `make -C elixir all`, focused test evidence, Review
  Suite normal, Review Suite GitHub review, and the remaining legacy hit
  classification.
- No raw work keys, private handoff payloads, bearer tokens, MCP tokens, GitHub
  tokens, or secret-bearing commands are copied into PR text or docs.

## Merge Feature Branch To Main

1. Open or update the GitHub PR from
   `feature/sympp-v21-ledger-claims` to `main`.
2. Confirm the PR head is the feature branch head that contains the final
   WorkPackage PR.
3. Wait for branch protection and review requirements.
4. Merge through GitHub. Do not perform a local history rewrite.
5. After merge, refresh the local operator checkout:

```powershell
git fetch origin main
git checkout main
git pull --ff-only origin main
```

## Sync Plugin Cache

Run this only after `main` contains the V2.1 cutover commits:

```powershell
.\scripts\refresh-local-plugin.ps1 -ValidateInstalledCache
```

If only one package must be repaired, use the narrow package flag:

```powershell
.\scripts\refresh-local-plugin.ps1 -PluginName symphony-plus-plus -ValidateInstalledCache
.\scripts\refresh-local-plugin.ps1 -PluginName symphony-plus-plus-mcp -ValidateInstalledCache
```

For dedicated WorkRequest/WorkPackage MCP homes, enable or repair the opt-in
companion only in that dedicated Codex home:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
```

Do not enable the MCP companion in the normal global Codex home unless every
generic session on that home should connect to Symphony++ MCP.

## Restart MCP And Dashboard

1. Stop any old `mix sympp.cockpit` process for this checkout.
2. Start the daemon from the updated `main` checkout:

```powershell
Set-Location elixir
mix sympp.cockpit
```

3. In a second shell from the repository root, verify the HTTP MCP daemon:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

4. Restart or reload dedicated Codex MCP sessions. Current-session tool lists
   are loaded at session startup; cache refresh alone does not mutate an
   already-open model tool list.

## Verify Ledger State

Use the existing default ledger unless the operator intentionally passes an
isolated `--database` path.

1. Open the dashboard and confirm existing WorkRequests and WorkPackages load.
2. Run `sympp.health` from the dedicated MCP session and confirm the returned
   ledger identity points at the expected local SQLite ledger.
3. Dispatch only a safe temporary fixture or an operator-approved pending slice.
   Normal dispatch output must contain `worker_bootstrap.type=ledger_claim`,
   `mode=local_assignment`, and `claim.tool=claim_local_assignment`.
4. Confirm normal dispatch output does not include `worker_secret_handoff`,
   `run_mcp_command`, `.secret`, or `local-private-file`.
5. Prepare the worker worktree and claim with `claim_local_assignment` using
   dispatch metadata plus runtime `branch`, `worktree_path`, `caller_id`, and
   `claimed_by`.
6. Reconnect with the same local claim and confirm it heartbeats the existing
   claim lease instead of asking for a worker secret.

Do not delete existing `worker-secrets` files during cutover. If old files are
present, treat them as legacy recovery material and remove them only through an
explicit operator cleanup step after the new workflow has been verified.

## Remaining Legacy Hit Classes

The post-cutover grep target is:

```powershell
rg -n "local-private-file|claim_work_key|private_handoff|worker-secrets" elixir plugins .codex implementation_docs_symphplusplus
```

Allowed remaining hits:

- Recovery-only code paths gated by `legacy_private_handoff`, `claim_work_key`,
  or `claim_private_handoff`.
- Secret-handoff implementation and tests that prove old recovery paths are
  redacted, gated, and non-default.
- Documentation that labels private-store/bootstrap flows as legacy,
  recovery, or architect bootstrap/recovery.
- Historical pilot/dogfood docs that are not the current operator path.

Fix remaining hits when they instruct normal planned-slice workers to ask for a
work key, private handoff metadata, `worker-secrets`, or `local-private-file`.
