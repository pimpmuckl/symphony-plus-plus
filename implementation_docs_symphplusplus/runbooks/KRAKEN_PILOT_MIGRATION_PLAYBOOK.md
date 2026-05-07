# Kraken Pilot Migration Playbook

## Goal

Run a low-risk Symphony++ pilot for Kraken without moving the active Kraken rewrite/rework program into Symphony++ first.

This playbook is operator-facing. A human should be able to run the pilot from these steps without reading Symphony++ internals.

## Non-goals

- Do not migrate active `feat/kraken-rework-*` or `feat/kraken-rewrite-*` work before this mini-pilot succeeds.
- Do not allow automated production merge.
- Do not push directly to `main`.
- Do not create live Linear state during the pilot.
- Do not run live Twitch/Gemini/provider validation unless a human explicitly approves the credentialed side effect.
- Do not use stale historical Kraken bugs as pilot work unless the current `main` code can still reproduce them.

## Source Repos

Use these repositories as the pilot target set:

| Checkout | WorkPackage repo | Checkout ref | WorkPackage / PR base | Purpose |
|---|---|---|---|---|
| `C:\Code\nextide-saas-vod-kraken` | `kraken` | `origin/main` | `main` | Kraken implementation work |
| `C:\Code\nextide-saas-vod-stack` | `vod-stack` | `origin/main` | `main` | Stack smoke/signoff validation only |

Use non-owner worktrees for implementation. In Kraken, branch from
`origin/main`, push explicit feature refs, set WorkPackage `repo` to the
tracker slug `kraken`, and set WorkPackage `base_branch` to the PR base name
`main`.

Create or reuse explicit pilot worktrees before dispatching standalone workers:

```powershell
$krakenOwner = "C:\Code\nextide-saas-vod-kraken"
$pilotBaseBranch = "main" # Replace with "dev" only after recording the operator-approved dev override.
$KRAKEN_QF_WORKTREE = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-qf"
$KRAKEN_HF_WORKTREE = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-hf"

git -C $krakenOwner fetch origin "${pilotBaseBranch}:refs/remotes/origin/${pilotBaseBranch}"
if ($LASTEXITCODE -ne 0) { throw "Kraken origin/$pilotBaseBranch fetch failed" }

$pilotBranches = @(
  @{Path=$KRAKEN_QF_WORKTREE; Branch="feat/sympp-pilot-qf-doc-or-log-hygiene"; Label="quick-fix"},
  @{Path=$KRAKEN_HF_WORKTREE; Branch="fix/sympp-pilot-synthetic-smoke-hygiene"; Label="hotfix"}
)
foreach ($pilot in $pilotBranches) {
  $pilotPath = $pilot["Path"]
  $pilotBranch = $pilot["Branch"]
  $pilotLabel = $pilot["Label"]
  $remoteExists = $false
  git -C $krakenOwner ls-remote --exit-code --heads origin $pilotBranch *> $null
  if ($LASTEXITCODE -eq 0) {
    $remoteExists = $true
    git -C $krakenOwner fetch origin "${pilotBranch}:refs/remotes/origin/${pilotBranch}"
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch remote $pilotLabel pilot branch before worktree setup." }
  } elseif ($LASTEXITCODE -ne 2) {
    throw "Could not verify remote $pilotLabel pilot branch before worktree setup."
  }
  if (-not (Test-Path $pilotPath)) {
    if ($remoteExists) {
      git -C $krakenOwner show-ref --verify --quiet "refs/heads/${pilotBranch}"
      if ($LASTEXITCODE -eq 0) {
        git -C $krakenOwner worktree add $pilotPath $pilotBranch
        if ($LASTEXITCODE -ne 0) { throw "$pilotLabel worktree reuse from existing local branch failed; inspect worktree list before dispatch" }
      } elseif ($LASTEXITCODE -eq 1) {
        git -C $krakenOwner worktree add -b $pilotBranch $pilotPath "origin/${pilotBranch}"
        if ($LASTEXITCODE -ne 0) { throw "$pilotLabel worktree creation from remote branch failed" }
      } else {
        throw "Could not inspect local $pilotLabel branch before worktree setup."
      }
    } else {
      git -C $krakenOwner worktree add -b $pilotBranch $pilotPath "origin/${pilotBaseBranch}"
      if ($LASTEXITCODE -ne 0) { throw "$pilotLabel worktree creation failed" }
    }
  }
  git -C $pilotPath rev-parse --is-inside-work-tree *> $null
  if ($LASTEXITCODE -ne 0) { throw "$pilotLabel pilot worktree is not a Git worktree" }
  $currentBranch = git -C $pilotPath branch --show-current
  if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $pilotBranch) { throw "$pilotLabel pilot worktree is not on $pilotBranch" }
  $dirty = git -C $pilotPath status --porcelain
  if (![string]::IsNullOrWhiteSpace($dirty)) { throw "$pilotLabel pilot worktree is dirty; preserve evidence, then clean/recreate it before dispatch" }
  $pilotHead = git -C $pilotPath rev-parse HEAD
  $baseHead = git -C $pilotPath rev-parse "origin/${pilotBaseBranch}"
  if ($remoteExists) {
    $remotePilotHead = git -C $pilotPath rev-parse "origin/${pilotBranch}"
    if ($remotePilotHead -ne $baseHead) {
      throw "$pilotLabel remote pilot branch already contains commits. Preserve evidence, then explicitly delete/reset it before a fresh dispatch."
    }
  }
  if ($pilotHead -ne $baseHead) {
    throw "$pilotLabel pilot worktree is not at origin/$pilotBaseBranch. Remove/recreate or intentionally reset it before dispatch."
  }
}
```

If either path already exists, the verification block must still pass before
dispatch. Do not run pilot implementation or scope checks from the owner
checkout unless that checkout is the active pilot worktree.

This playbook treats the package-spec shorthand "dev/main" as the non-rewrite
development base decision. Local Kraken evidence for this pilot showed `main`,
so the standalone package examples use `main`. The mini-phase is seeded from
`main`, but its anchor, child WorkPackages, and child PRs use the
non-production phase parent branch `feat/sympp-pilot-mini-phase` as their base
so the implemented WorkPackage base and PR base checks agree. If the operator
confirms a current Kraken `dev` branch is the safer non-production seed, record
that override once and replace the standalone checkout/base examples and the
mini-phase parent branch seed consistently with `dev` before creating pilot
work.

## Pilot Package Sequence

Use these concrete Symphony++ package IDs and branch names. If a selected candidate fails the criteria below, keep the package ID and choose the next eligible candidate; do not retarget the package to active rewrite work.

| Order | ID | Policy | Repo | Base | Branch | Candidate shape |
|---:|---|---|---|---|---|---|
| 1 | `KRAKEN-PILOT-QF-001` | `quick_fix` | Kraken | `main` | `feat/sympp-pilot-qf-doc-or-log-hygiene` | Low-risk docs, runbook, script, or test-selector hygiene |
| 2 | `KRAKEN-PILOT-HF-001` | `hotfix` | Kraken | `main` | `fix/sympp-pilot-synthetic-smoke-hygiene` | Hotfix-like, current-code defect with focused regression and PR |
| 3 | `KRAKEN-PILOT-MP-001` | phase ID/dashboard scope | Kraken + stack validation | `feat/sympp-pilot-mini-phase` seeded from `main` | `feat/sympp-pilot-mini-phase` | Two-child mini-phase only |
| 3-anchor | `KRAKEN-PILOT-MP-001-ANCHOR` | `investigation` WorkPackage | Kraken | `feat/sympp-pilot-mini-phase` | `feat/sympp-pilot-mini-phase` | Parent planning/progress anchor |
| 3a | `KRAKEN-PILOT-MP-001A` | `phase_child` WorkPackage | Kraken | `feat/sympp-pilot-mini-phase` | `feat/sympp-pilot-mini-doc-boundary` | Child A: docs/runbook boundary |
| 3b | `KRAKEN-PILOT-MP-001B` | `phase_child` WorkPackage | Kraken | `feat/sympp-pilot-mini-phase` | `feat/sympp-pilot-mini-focused-regression` | Child B: focused regression or scripts-only cleanup |

Do not use branches matching:

```text
feat/kraken-rework-*
feat/kraken-rewrite-*
feat/kraken-first-segment-runtime-*
feat/kraken-chimera-*
feat/kraken-audio-ingest-segment-*
```

Those names indicate active rewrite/rework or high-blast-radius runtime lanes in the local branch inventory.

## Candidate Selection

Select `KRAKEN-PILOT-QF-001` only if all are true:

- Diff is expected to stay inside docs, runbooks, scripts, or test files covered
  by the quick-fix `allowed_file_globs`.
- No production credentials, live provider calls, migrations, queue semantics, or runtime defaults are touched.
- Focused validation can run locally without Docker or external services.
- Expected review scope is small enough for a first Symphony++ worker to complete in one short PR.

Select `KRAKEN-PILOT-HF-001` only if all are true:

- The defect reproduces on the approved Kraken pilot base, usually `main`
  unless the operator recorded the pilot-wide `dev` override.
- The checkout starts from `origin/<approved-pilot-base-branch>`; the
  WorkPackage and PR base use that same branch, not an active rewrite branch.
- The branch is short-lived and reversible.
- A focused regression proves the current defect.
- The worker can run at least touched-file `ruff`/`pytest`; full `uv run pytest -n 7` is preferred when feasible.
- A human merge remains required after PR review and branch protection.

Select `KRAKEN-PILOT-MP-001` only if all are true:

- The parent phase has exactly two children.
- The children have disjoint write scopes.
- A human owner explicitly approves the phase parent branch
  `feat/sympp-pilot-mini-phase`, seeded from the approved non-rewrite base, as
  the architect grant scope for this pilot. If the deployment cannot record
  that approval, stop before creating the mini-phase.
- Neither child changes provider credentials, production deployment, broad queue ownership, or active rework branches.
- The parent branch receives child PRs only after child validation is green.
- Stack validation is dry-run/synthetic by default.

If no candidate satisfies these criteria, stop the pilot and record a blocker. Do not weaken the criteria to keep the pilot moving.

## Create Work Packages

Run package creation from the Symphony++ repo. Use a staging or pilot ledger
database, not production.

Create the request file first. Do not run `sympp.create_work` against the
unmodified example template, because package creation mints the one-time worker
secret immediately. Replace `<approved-pilot-base-branch>` with `main` unless
the operator recorded the pilot-wide `dev` override before creating any pilot
package.

Quick-fix request:

```yaml
id: KRAKEN-PILOT-QF-001
kind: quick_fix
repo: kraken
base_branch: <approved-pilot-base-branch>
branch_pattern: feat/sympp-pilot-qf-doc-or-log-hygiene
title: Kraken pilot quick fix
product_description: Prove Symphony++ on one low-risk Kraken quick fix.
engineering_scope: Docs, runbooks, scripts, or tests-only selector hygiene.
acceptance_criteria:
  - Candidate satisfies the quick-fix criteria in the playbook.
  - Focused local validation passes.
  - Required quick-fix review evidence is recorded.
policy_template: quick_fix
allowed_file_globs:
  - README.md
  - spec.md
  - conftest.py
  - docs/**
  - runbooks/**
  - scripts/**
  - tests/**
  - apps/**/tests/**
  - packages/**/tests/**
```

Then run:

```powershell
cd elixir
$env:SYMPP_PILOT_SECRET_HANDOFF_CMD = "<approved-secret-handoff-executable>"
$env:SYMPP_PILOT_LEDGER = "<pilot-ledger.sqlite3>"
$createOutput = mise exec -- mix sympp.create_work --database <pilot-ledger.sqlite3> --file <edited-quick-fix-request.yaml>
if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-QF-001 create_work failed" }
$createOutput | & $env:SYMPP_PILOT_SECRET_HANDOFF_CMD "KRAKEN-PILOT-QF-001"
if ($LASTEXITCODE -ne 0) {
  $created = $createOutput | ConvertFrom-Json
  $env:SYMPP_REVOKE_GRANT_ID = $created.worker_grant.id
  $env:SYMPP_CLEANUP_WORK_PACKAGE_ID = $created.work_package.id
  @'
alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
alias SymphonyElixir.SymphonyPlusPlus.Repo
{:ok, _started} = Application.ensure_all_started(:ecto_sql)
database = System.fetch_env!("SYMPP_PILOT_LEDGER") |> Path.expand()
repo_pid =
  case Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false) do
    {:ok, pid} -> pid
    {:error, {:already_started, pid}} -> pid
  end
Repo.put_dynamic_repo(repo_pid)
grant_id = System.fetch_env!("SYMPP_REVOKE_GRANT_ID")
work_package_id = System.fetch_env!("SYMPP_CLEANUP_WORK_PACKAGE_ID")
{:ok, _revoked} = AccessGrantService.revoke(Repo, grant_id)
Ecto.Adapters.SQL.query!(Repo, "DELETE FROM sympp_work_packages WHERE id = ?", [work_package_id])
'@ | Set-Content -Path .\tmp_revoke_standalone_grant.exs -Encoding utf8
  mise exec -- mix run .\tmp_revoke_standalone_grant.exs
  $revokeExit = $LASTEXITCODE
  Remove-Item .\tmp_revoke_standalone_grant.exs
  Remove-Item Env:\SYMPP_REVOKE_GRANT_ID
  Remove-Item Env:\SYMPP_CLEANUP_WORK_PACKAGE_ID
  Remove-Item Env:\SYMPP_PILOT_LEDGER
  if ($revokeExit -ne 0) { throw "KRAKEN-PILOT-QF-001 secret handoff failed and cleanup failed; record residual access/package-ID risk before continuing" }
  throw "KRAKEN-PILOT-QF-001 secret handoff failed; worker grant revoked and orphaned package removed; do not dispatch worker"
}
Remove-Item Env:\SYMPP_PILOT_LEDGER
```

The approved handoff wrapper must read the full create-work JSON from stdin,
store `worker_grant.secret` in the approved secret manager, and print only
redacted package and grant metadata. Do not run standalone `sympp.create_work`
in a mode that prints the raw worker secret to shell logs or transcripts.

Hotfix request:

```yaml
id: KRAKEN-PILOT-HF-001
kind: hotfix
repo: kraken
base_branch: <approved-pilot-base-branch>
branch_pattern: fix/sympp-pilot-synthetic-smoke-hygiene
title: Kraken pilot hotfix
product_description: Prove Symphony++ on one current-code Kraken hotfix-like defect.
engineering_scope: Narrow fix plus focused regression on the approved Kraken pilot base.
acceptance_criteria:
  - Defect is reproduced or proven on the approved pilot base.
  - Focused regression passes after the fix.
  - PR, review_t1, and review_t2 evidence are recorded.
policy_template: hotfix
allowed_file_globs:
  - README.md
  - spec.md
  - conftest.py
  - apps/**
  - apps/**/tests/**
  - packages/**
  - packages/**/tests/**
  - scripts/**
  - tests/**
  - docs/**
```

Then run:

```powershell
cd elixir
$env:SYMPP_PILOT_SECRET_HANDOFF_CMD = "<approved-secret-handoff-executable>"
$env:SYMPP_PILOT_LEDGER = "<pilot-ledger.sqlite3>"
$createOutput = mise exec -- mix sympp.create_work --database <pilot-ledger.sqlite3> --file <edited-hotfix-request.yaml>
if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-HF-001 create_work failed" }
$createOutput | & $env:SYMPP_PILOT_SECRET_HANDOFF_CMD "KRAKEN-PILOT-HF-001"
if ($LASTEXITCODE -ne 0) {
  $created = $createOutput | ConvertFrom-Json
  $env:SYMPP_REVOKE_GRANT_ID = $created.worker_grant.id
  $env:SYMPP_CLEANUP_WORK_PACKAGE_ID = $created.work_package.id
  @'
alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
alias SymphonyElixir.SymphonyPlusPlus.Repo
{:ok, _started} = Application.ensure_all_started(:ecto_sql)
database = System.fetch_env!("SYMPP_PILOT_LEDGER") |> Path.expand()
repo_pid =
  case Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false) do
    {:ok, pid} -> pid
    {:error, {:already_started, pid}} -> pid
  end
Repo.put_dynamic_repo(repo_pid)
grant_id = System.fetch_env!("SYMPP_REVOKE_GRANT_ID")
work_package_id = System.fetch_env!("SYMPP_CLEANUP_WORK_PACKAGE_ID")
{:ok, _revoked} = AccessGrantService.revoke(Repo, grant_id)
Ecto.Adapters.SQL.query!(Repo, "DELETE FROM sympp_work_packages WHERE id = ?", [work_package_id])
'@ | Set-Content -Path .\tmp_revoke_standalone_grant.exs -Encoding utf8
  mise exec -- mix run .\tmp_revoke_standalone_grant.exs
  $revokeExit = $LASTEXITCODE
  Remove-Item .\tmp_revoke_standalone_grant.exs
  Remove-Item Env:\SYMPP_REVOKE_GRANT_ID
  Remove-Item Env:\SYMPP_CLEANUP_WORK_PACKAGE_ID
  Remove-Item Env:\SYMPP_PILOT_LEDGER
  if ($revokeExit -ne 0) { throw "KRAKEN-PILOT-HF-001 secret handoff failed and cleanup failed; record residual access/package-ID risk before continuing" }
  throw "KRAKEN-PILOT-HF-001 secret handoff failed; worker grant revoked and orphaned package removed; do not dispatch worker"
}
Remove-Item Env:\SYMPP_PILOT_LEDGER
```

Use the same approved handoff contract as the quick-fix package: the wrapper
stores `worker_grant.secret` and emits only redacted metadata.

Before dispatching a standalone worker, retrieve only that worker's stored work
key through the same approved non-logging handoff path. The handoff wrapper
must write the secret to a fresh worker-session-specific environment file or
secret input channel outside the repository, not to stdout, planning files, PR
bodies, or review logs. Do not retrieve the quick-fix and hotfix secrets in one
batch. Retrieve each secret immediately before dispatching that worker, then
delete the session directory after `claim_work_key(...)` succeeds or on any
failure:

```powershell
$env:SYMPP_PILOT_SECRET_HANDOFF_CMD = "<approved-secret-handoff-executable>"

$qfSecretDir = Join-Path $env:TEMP ("kraken-pilot-qf-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $qfSecretDir | Out-Null
$qfSecretEnv = Join-Path $qfSecretDir "worker-secret.env"
try {
  & $env:SYMPP_PILOT_SECRET_HANDOFF_CMD "--write-env-file" "KRAKEN-PILOT-QF-001" $qfSecretEnv
  if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-QF-001 worker secret retrieval failed" }

  Write-Host "Pass $qfSecretEnv to only the KRAKEN-PILOT-QF-001 worker session."
  $qfClaimed = Read-Host "After the quick-fix worker confirms claim_work_key succeeded, type CLAIMED to delete the secret file"
  if ($qfClaimed -ne "CLAIMED") { throw "KRAKEN-PILOT-QF-001 worker claim was not confirmed" }
} catch {
  throw "KRAKEN-PILOT-QF-001 worker secret retrieval failed; do not dispatch worker"
} finally {
  if (Test-Path -LiteralPath $qfSecretDir) {
    Remove-Item -LiteralPath $qfSecretDir -Recurse -Force
  }
}
```

Use this separate hotfix block only immediately before dispatching
`KRAKEN-PILOT-HF-001`:

```powershell
$env:SYMPP_PILOT_SECRET_HANDOFF_CMD = "<approved-secret-handoff-executable>"
$hfSecretDir = Join-Path $env:TEMP ("kraken-pilot-hf-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $hfSecretDir | Out-Null
$hfSecretEnv = Join-Path $hfSecretDir "worker-secret.env"
try {
  & $env:SYMPP_PILOT_SECRET_HANDOFF_CMD "--write-env-file" "KRAKEN-PILOT-HF-001" $hfSecretEnv
  if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-HF-001 worker secret retrieval failed" }

  Write-Host "Pass $hfSecretEnv to only the KRAKEN-PILOT-HF-001 worker session."
  $hfClaimed = Read-Host "After the hotfix worker confirms claim_work_key succeeded, type CLAIMED to delete the secret file"
  if ($hfClaimed -ne "CLAIMED") { throw "KRAKEN-PILOT-HF-001 worker claim was not confirmed" }
} catch {
  throw "KRAKEN-PILOT-HF-001 worker secret retrieval failed; do not dispatch worker"
} finally {
  if (Test-Path -LiteralPath $hfSecretDir) {
    Remove-Item -LiteralPath $hfSecretDir -Recurse -Force
  }
}
```

Each environment file must be consumed only by the matching worker session and
must contain only the worker-key secret needed for that package. If dispatch is
not immediate, delete the directory and retrieve a new one later. If the
approved handoff path cannot retrieve the secret without printing it, record a
blocked pilot handoff finding instead of dispatching the standalone worker.

For standalone `quick_fix` and `hotfix` packages, `allowed_file_globs` is the
pilot's documented file-scope contract. Before either standalone package calls
`mark_ready`, the worker or operator must run the matching changed-file check
below from the Kraken worktree so scope failures are caught before readiness.
If any path is outside the allow-list, move the package to `blocked` and do not
mark it ready.

Quick-fix scope check:

```powershell
$KRAKEN_QF_WORKTREE = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-qf"
$KRAKEN_QF_BASE = "main" # Replace with "dev" only after recording the operator-approved dev override.
git -C $KRAKEN_QF_WORKTREE fetch origin "${KRAKEN_QF_BASE}:refs/remotes/origin/${KRAKEN_QF_BASE}"
if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-QF-001 scope check fetch failed" }
$currentBranch = git -C $KRAKEN_QF_WORKTREE branch --show-current
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne "feat/sympp-pilot-qf-doc-or-log-hygiene") {
  throw "KRAKEN-PILOT-QF-001 scope check is not on the active pilot branch"
}
$changedFiles = @(git -C $KRAKEN_QF_WORKTREE diff --name-only "origin/${KRAKEN_QF_BASE}...HEAD")
if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-QF-001 scope check diff failed" }
$allowedPathRegex = '^(README\.md$|spec\.md$|conftest\.py$|docs/|runbooks/|scripts/|tests/|apps/(.*/)?tests/|packages/(.*/)?tests/)'
$outOfScope = @($changedFiles | Where-Object { $_ -notmatch $allowedPathRegex })
if ($outOfScope.Count -gt 0) {
  $outOfScope | ForEach-Object { Write-Error "Out-of-scope quick-fix path: $_" }
  throw "KRAKEN-PILOT-QF-001 scope check failed"
}
```

Hotfix scope check:

```powershell
$KRAKEN_HF_WORKTREE = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-hf"
$KRAKEN_HF_BASE = "main" # Replace with "dev" only after recording the operator-approved dev override.
git -C $KRAKEN_HF_WORKTREE fetch origin "${KRAKEN_HF_BASE}:refs/remotes/origin/${KRAKEN_HF_BASE}"
if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-HF-001 scope check fetch failed" }
$currentBranch = git -C $KRAKEN_HF_WORKTREE branch --show-current
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne "fix/sympp-pilot-synthetic-smoke-hygiene") {
  throw "KRAKEN-PILOT-HF-001 scope check is not on the active pilot branch"
}
$changedFiles = @(git -C $KRAKEN_HF_WORKTREE diff --name-only "origin/${KRAKEN_HF_BASE}...HEAD")
if ($LASTEXITCODE -ne 0) { throw "KRAKEN-PILOT-HF-001 scope check diff failed" }
$allowedPathRegex = '^(README\.md$|spec\.md$|conftest\.py$|apps/|packages/|scripts/|tests/|docs/)'
$outOfScope = @($changedFiles | Where-Object { $_ -notmatch $allowedPathRegex })
if ($outOfScope.Count -gt 0) {
  $outOfScope | ForEach-Object { Write-Error "Out-of-scope hotfix path: $_" }
  throw "KRAKEN-PILOT-HF-001 scope check failed"
}
```

For the mini-phase, do not use standalone `sympp.create_work` for children.
Use architect delegation after the quick-fix and hotfix pilots are complete:

Before creating the phase architect grant, publish or verify the phase parent
branch `feat/sympp-pilot-mini-phase` from the approved non-rewrite seed branch
(`main` in the examples below). The phase anchor, child WorkPackages, and child
PRs must all use that phase parent branch as their base. If the dashboard/API or
approved operator process cannot record that checkpoint, stop the mini-phase and
record a blocker; do not silently switch the pilot onto the active Kraken
rewrite branch.

Publish or refresh the phase parent branch without switching the owner checkout:

```powershell
$krakenOwner = "C:\Code\nextide-saas-vod-kraken"
$phaseParentBranch = "feat/sympp-pilot-mini-phase"
$phaseSeedBranch = "main" # Replace with "dev" only after recording the operator-approved dev seed override.
$phaseParentResume = $false # Set to $true only for a same-pilot retry/rotation with preserved checkpoint evidence.
git -C $krakenOwner fetch origin "${phaseSeedBranch}:refs/remotes/origin/${phaseSeedBranch}"
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch origin/$phaseSeedBranch before phase parent publication." }
git -C $krakenOwner ls-remote --exit-code --heads origin $phaseParentBranch *> $null
$phaseRemoteCheckExit = $LASTEXITCODE
if ($phaseRemoteCheckExit -eq 0) {
  git -C $krakenOwner fetch origin "${phaseParentBranch}:refs/remotes/origin/${phaseParentBranch}"
  if ($LASTEXITCODE -ne 0) { throw "Existing phase parent branch could not be fetched." }
  $approvedSeedHead = git -C $krakenOwner rev-parse "origin/${phaseSeedBranch}"
  $phaseParentHead = git -C $krakenOwner rev-parse "origin/${phaseParentBranch}"
  if ($phaseParentHead -ne $approvedSeedHead) {
    if (!$phaseParentResume) {
      throw "Existing phase parent branch already contains commits. Preserve evidence, then explicitly delete/reset it before creating a fresh mini-phase, or set phaseParentResume=true only for a same-pilot retry/rotation."
    }
    git -C $krakenOwner merge-base --is-ancestor "origin/${phaseSeedBranch}" "origin/${phaseParentBranch}"
    if ($LASTEXITCODE -ne 0) {
      throw "Resume requested, but existing phase parent branch is not descended from origin/$phaseSeedBranch."
    }
  }
} elseif ($phaseRemoteCheckExit -eq 2) {
  git -C $krakenOwner push origin "origin/${phaseSeedBranch}:refs/heads/$phaseParentBranch"
  if ($LASTEXITCODE -ne 0) { throw "Failed to publish phase parent branch from origin/$phaseSeedBranch." }
  git -C $krakenOwner fetch origin "${phaseParentBranch}:refs/remotes/origin/${phaseParentBranch}"
  if ($LASTEXITCODE -ne 0) { throw "Failed to fetch newly published phase parent branch." }
  $approvedSeedHead = git -C $krakenOwner rev-parse "origin/${phaseSeedBranch}"
  $phaseParentHead = git -C $krakenOwner rev-parse "origin/${phaseParentBranch}"
  if ($phaseParentHead -ne $approvedSeedHead) {
    throw "Newly published phase parent branch does not match origin/$phaseSeedBranch."
  }
} else {
  throw "Could not verify remote phase parent branch existence."
}
```

1. Create phase container `KRAKEN-PILOT-MP-001` with title
   `Kraken Symphony++ pilot mini-phase`.
2. Create an anchor WorkPackage inside that phase through the Phase 7
   phase/anchor creation path. Do not use standalone `sympp.create_work` for
   this anchor because standalone create-work does not bind `phase_id`.
   Use an `investigation` anchor so the parent lane can close with findings and
   a recommendation artifact after the two child packages merge:

```yaml
id: KRAKEN-PILOT-MP-001-ANCHOR
kind: investigation
repo: kraken
base_branch: feat/sympp-pilot-mini-phase
phase_id: KRAKEN-PILOT-MP-001
branch_pattern: feat/sympp-pilot-mini-phase
title: Kraken pilot mini-phase anchor
policy_template: investigation
acceptance_criteria:
  - Exactly two child packages are created.
  - Child scopes remain disjoint.
  - Architect approval and merge artifacts are recorded.
allowed_file_globs:
  - README.md
  - spec.md
  - conftest.py
  - docs/**
  - runbooks/**
  - tests/**
  - apps/**/tests/**
  - packages/**/tests/**
  - scripts/**
```

The anchor `allowed_file_globs` list is the parent scope envelope for both
children. The anchor remains a coordination/evidence lane, not an
implementation lane, but the parent scope must be nonempty so child globs are
validated inside the pilot's intended docs, runbooks, tests, and scripts
boundary.

The current Symphony++ dashboard/API surface does not expose a write path for
creating the phase anchor or minting these owner-held grants. For this pilot,
use the local bootstrap script below; do not invent dashboard/API grant
creation steps. It creates the phase, phase-bound anchor package, owner-held
anchor worker grant, and architect grant, then prints grant IDs only. The
bootstrap is executable only when
`SYMPP_PILOT_SECRET_HANDOFF_CMD` points at an approved operator handoff wrapper.
That wrapper must support a non-secret `--preflight` check, then read a JSON
payload from stdin and store the one-time architect and anchor work keys in the
approved secret manager before the script continues. The wrapper must be atomic:
on a non-zero exit it must either store no entries or delete any partially
stored pilot entries before returning. If that handoff command is not available,
stop before running the bootstrap and document the mini-phase as blocked; do not
print raw work-key secrets into planning docs, PR bodies, logs, or reviews.
The fallback path also requires an approved checkpoint that the phase parent
branch was created from the approved non-rewrite seed before it mints the
architect grant. If the operator cannot provide real dashboard/API/change-control
text for that phase-parent checkpoint, stop and document the mini-phase as
blocked. The current grant model freezes `scope_repo` and `scope_base_branch`;
the anchor finding created below is the operator-visible audit provenance for
why the phase parent branch is allowed.

```powershell
$env:SYMPP_PILOT_LEDGER = "<pilot-ledger.sqlite3>"
$env:SYMPP_PILOT_SECRET_HANDOFF_CMD = "<approved-secret-handoff-executable>"
$env:SYMPP_PILOT_PHASE_SEED_BRANCH = "main"
$env:SYMPP_PILOT_PHASE_PARENT_CHECKPOINT_TEXT = "<approved checkpoint text authorizing KRAKEN-PILOT-MP-001 children against feat/sympp-pilot-mini-phase seeded from the approved Kraken branch in SYMPP_PILOT_PHASE_SEED_BRANCH>"
$env:SYMPP_PILOT_PHASE_PARENT_RESUME = "no" # Use "yes" only when retrying the same pilot with preserved checkpoint evidence.
$env:SYMPP_PILOT_PHASE_PARENT_CREATED_BY_BOOTSTRAP = "no"
if ([string]::IsNullOrWhiteSpace($env:SYMPP_PILOT_PHASE_PARENT_CHECKPOINT_TEXT) -or $env:SYMPP_PILOT_PHASE_PARENT_CHECKPOINT_TEXT -like "<*") {
  throw "Approved phase-parent checkpoint is required before fallback bootstrap"
}
if ($env:SYMPP_PILOT_PHASE_SEED_BRANCH -notin @("main", "dev")) {
  throw "Phase seed branch must be the recorded non-rewrite seed, usually main or an operator-approved dev override"
}
if ([string]::IsNullOrWhiteSpace($env:SYMPP_PILOT_SECRET_HANDOFF_CMD) -or $env:SYMPP_PILOT_SECRET_HANDOFF_CMD -like "<*") {
  throw "Approved secret handoff command is required before fallback bootstrap"
}
try {
  & $env:SYMPP_PILOT_SECRET_HANDOFF_CMD --preflight
  $handoffPreflightShellOk = $?
  $handoffPreflightExit = $LASTEXITCODE
} catch {
  throw "Approved secret handoff preflight could not be invoked; stop before publishing the phase parent branch. $($_.Exception.Message)"
}
if (!$handoffPreflightShellOk -or $handoffPreflightExit -ne 0) {
  throw "Approved secret handoff preflight failed; stop before publishing the phase parent branch."
}
$krakenOwner = "C:\Code\nextide-saas-vod-kraken"
$phaseParentBranch = "feat/sympp-pilot-mini-phase"
$env:SYMPP_PILOT_KRAKEN_OWNER = $krakenOwner
$env:SYMPP_PILOT_PHASE_PARENT_BRANCH = $phaseParentBranch
git -C $krakenOwner fetch origin "${env:SYMPP_PILOT_PHASE_SEED_BRANCH}:refs/remotes/origin/${env:SYMPP_PILOT_PHASE_SEED_BRANCH}"
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch approved phase seed before fallback bootstrap" }
git -C $krakenOwner ls-remote --exit-code --heads origin $phaseParentBranch *> $null
$phaseRemoteCheckExit = $LASTEXITCODE
if ($phaseRemoteCheckExit -eq 0) {
  git -C $krakenOwner fetch origin "${phaseParentBranch}:refs/remotes/origin/${phaseParentBranch}"
  if ($LASTEXITCODE -ne 0) { throw "Phase parent branch must fetch cleanly before fallback bootstrap" }
} elseif ($phaseRemoteCheckExit -eq 2) {
  git -C $krakenOwner push origin "origin/${env:SYMPP_PILOT_PHASE_SEED_BRANCH}:refs/heads/$phaseParentBranch"
  if ($LASTEXITCODE -ne 0) { throw "Failed to publish phase parent branch before fallback bootstrap" }
  $env:SYMPP_PILOT_PHASE_PARENT_CREATED_BY_BOOTSTRAP = "yes"
  git -C $krakenOwner fetch origin "${phaseParentBranch}:refs/remotes/origin/${phaseParentBranch}"
  if ($LASTEXITCODE -ne 0) { throw "Failed to fetch newly published phase parent branch before fallback bootstrap" }
} else {
  throw "Could not verify remote phase parent branch before fallback bootstrap"
}
$approvedSeedHead = git -C $krakenOwner rev-parse "origin/${env:SYMPP_PILOT_PHASE_SEED_BRANCH}"
$phaseParentHead = git -C $krakenOwner rev-parse "origin/${phaseParentBranch}"
if ($phaseParentHead -ne $approvedSeedHead) {
  if ($env:SYMPP_PILOT_PHASE_PARENT_RESUME -ne "yes") {
    throw "Phase parent branch already contains commits. Preserve evidence, then explicitly delete/reset it before minting a fresh architect grant, or set SYMPP_PILOT_PHASE_PARENT_RESUME=yes only for a same-pilot retry with checkpoint evidence."
  }
  git -C $krakenOwner merge-base --is-ancestor "origin/${env:SYMPP_PILOT_PHASE_SEED_BRANCH}" "origin/${phaseParentBranch}"
  if ($LASTEXITCODE -ne 0) {
    throw "Resume requested, but phase parent branch is not descended from origin/$($env:SYMPP_PILOT_PHASE_SEED_BRANCH). Stop before minting architect grant."
  }
}
Push-Location .\elixir
@'
alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
alias SymphonyElixir.SymphonyPlusPlus.Repo
alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

database = System.fetch_env!("SYMPP_PILOT_LEDGER") |> Path.expand()
handoff_cmd = System.fetch_env!("SYMPP_PILOT_SECRET_HANDOFF_CMD")
phase_parent_checkpoint_text = System.fetch_env!("SYMPP_PILOT_PHASE_PARENT_CHECKPOINT_TEXT")
phase_seed_branch = System.fetch_env!("SYMPP_PILOT_PHASE_SEED_BRANCH")
phase_parent_resume? = System.get_env("SYMPP_PILOT_PHASE_PARENT_RESUME") == "yes"
phase_parent_created_by_bootstrap? = System.get_env("SYMPP_PILOT_PHASE_PARENT_CREATED_BY_BOOTSTRAP") == "yes"
kraken_owner = System.fetch_env!("SYMPP_PILOT_KRAKEN_OWNER")
phase_parent_branch = System.fetch_env!("SYMPP_PILOT_PHASE_PARENT_BRANCH")

case System.cmd(handoff_cmd, ["--preflight"], stderr_to_stdout: true) do
  {_output, 0} -> :ok
  {_output, status} -> raise "approved secret handoff preflight failed with exit #{status}"
end

{:ok, repo_pid} = Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false)
Repo.put_dynamic_repo(repo_pid)
:ok = WorkPackageRepository.migrate(Repo)
:ok = PlanningRepository.migrate(Repo)
:ok = PhaseRepository.migrate(Repo)
:ok = AccessGrantRepository.migrate(Repo)

bootstrap_result =
  Repo.transaction(fn ->
    {:ok, {_phase, phase_created?}} =
      if phase_parent_resume? do
        case PhaseRepository.get(Repo, "KRAKEN-PILOT-MP-001") do
          {:ok, phase} ->
            {:ok, {phase, false}}

          {:error, _} ->
            with {:ok, phase} <- PhaseRepository.create(Repo, %{
              id: "KRAKEN-PILOT-MP-001",
              title: "Kraken Symphony++ pilot mini-phase",
              description: "Two-child Symphony++ pilot for Kraken."
            }) do
              {:ok, {phase, true}}
            end
        end
      else
        with {:ok, phase} <- PhaseRepository.create(Repo, %{
          id: "KRAKEN-PILOT-MP-001",
          title: "Kraken Symphony++ pilot mini-phase",
          description: "Two-child Symphony++ pilot for Kraken."
        }) do
          {:ok, {phase, true}}
        end
      end

    {:ok, {anchor, anchor_created?}} =
      if phase_parent_resume? do
        case WorkPackageRepository.get(Repo, "KRAKEN-PILOT-MP-001-ANCHOR") do
          {:ok, anchor} ->
            {:ok, {anchor, false}}

          {:error, _} ->
            with {:ok, anchor} <- WorkPackageRepository.create(Repo, %{
              id: "KRAKEN-PILOT-MP-001-ANCHOR",
              kind: "investigation",
              repo: "kraken",
              base_branch: "feat/sympp-pilot-mini-phase",
              branch_pattern: "feat/sympp-pilot-mini-phase",
              phase_id: "KRAKEN-PILOT-MP-001",
              title: "Kraken pilot mini-phase anchor",
              status: "ready_for_worker",
              policy_template: "investigation",
              product_description: "Coordinate exactly two child pilot packages.",
              engineering_scope: "Architect-only phase coordination; no runtime implementation.",
              acceptance_criteria: [
                "Exactly two child packages are created.",
                "Child scopes remain disjoint.",
                "Architect approval and merge artifacts are recorded."
              ],
              allowed_file_globs: [
                "README.md",
                "spec.md",
                "conftest.py",
                "docs/**",
                "runbooks/**",
                "tests/**",
                "apps/**/tests/**",
                "packages/**/tests/**",
                "scripts/**"
              ]
            }) do
              {:ok, {anchor, true}}
            end
        end
      else
        with {:ok, anchor} <- WorkPackageRepository.create(Repo, %{
          id: "KRAKEN-PILOT-MP-001-ANCHOR",
          kind: "investigation",
          repo: "kraken",
          base_branch: "feat/sympp-pilot-mini-phase",
          branch_pattern: "feat/sympp-pilot-mini-phase",
          phase_id: "KRAKEN-PILOT-MP-001",
          title: "Kraken pilot mini-phase anchor",
          status: "ready_for_worker",
          policy_template: "investigation",
          product_description: "Coordinate exactly two child pilot packages.",
          engineering_scope: "Architect-only phase coordination; no runtime implementation.",
          acceptance_criteria: [
            "Exactly two child packages are created.",
            "Child scopes remain disjoint.",
            "Architect approval and merge artifacts are recorded."
          ],
          allowed_file_globs: [
            "README.md",
            "spec.md",
            "conftest.py",
            "docs/**",
            "runbooks/**",
            "tests/**",
            "apps/**/tests/**",
            "packages/**/tests/**",
            "scripts/**"
          ]
        }) do
          {:ok, {anchor, true}}
        end
      end

    resumable_anchor_statuses = ["ready_for_worker", "claimed", "planning", "implementing"]
    if phase_parent_resume? and anchor.status not in resumable_anchor_statuses do
      raise "resume cannot mint fresh anchor/architect grants because #{anchor.id} is already #{anchor.status}; explicitly close/remove the pilot phase and anchor before bootstrapping again"
    end

    if anchor_created? do
      {:ok, _phase_parent_checkpoint_finding} =
        PlanningRepository.append_finding(Repo, %{
          work_package_id: anchor.id,
          title: "Approved phase-parent pilot checkpoint",
          body: phase_parent_checkpoint_text,
          severity: "info",
          idempotency_key: "kraken-pilot-phase-parent-checkpoint"
        })

    end

    if phase_parent_resume? do
      now = DateTime.utc_now(:microsecond)
      {:ok, anchor_grants} = AccessGrantRepository.list_for_work_package(Repo, anchor.id)
      {:ok, architect_grants} = AccessGrantRepository.list_for_phase(Repo, "KRAKEN-PILOT-MP-001")

      child_grants =
        ["KRAKEN-PILOT-MP-001A", "KRAKEN-PILOT-MP-001B"]
        |> Enum.flat_map(fn child_id ->
          case WorkPackageRepository.get(Repo, child_id) do
            {:ok, child} ->
              {:ok, grants} = AccessGrantRepository.list_for_work_package(Repo, child.id)
              grants

            {:error, _} ->
              []
          end
        end)

      live_grants =
        (anchor_grants ++ architect_grants ++ child_grants)
        |> Enum.filter(fn grant ->
          is_nil(grant.revoked_at) and DateTime.compare(grant.expires_at, now) == :gt
        end)

      if live_grants != [] do
        live_ids = Enum.map(live_grants, & &1.id) |> Enum.join(", ")
        raise "resume would create duplicate live grants; revoke or expire existing grants first: #{live_ids}"
      end
    end

    pilot_expires_at = DateTime.add(DateTime.utc_now(:microsecond), 259_200, :second)
    {:ok, anchor_worker} =
      AccessGrantService.mint_worker_grant(Repo, anchor.id,
        expires_at: pilot_expires_at,
        capabilities: [
          "worker:claim",
          "worker:lifecycle.transition",
          "read_task_plan",
          "append_finding",
          "append_progress",
          "request_scope_expansion",
          "update_task_plan",
          "mark_ready"
        ]
      )

    {:ok, minted} =
      AccessGrantService.mint_architect_grant(Repo, "KRAKEN-PILOT-MP-001",
        work_package_id: anchor.id,
        expires_at: pilot_expires_at,
        capabilities: [
          "read:phase",
          "create:child_work_package",
          "mint:child_worker_key",
          "revoke:child_worker_key",
          "read:child_progress",
          "read:child_findings",
          "approve:child_ready_state",
          "merge:child_into_phase"
        ]
      )

    if minted.grant.scope_repo != "kraken" or minted.grant.scope_base_branch != "feat/sympp-pilot-mini-phase" do
      raise "architect grant did not freeze the expected Kraken phase-parent scope"
    end

    %{
      phase_id: "KRAKEN-PILOT-MP-001",
      anchor_work_package_id: anchor.id,
      anchor_worker_grant_id: anchor_worker.grant.id,
      anchor_worker_key_secret: anchor_worker.work_key.secret,
      architect_work_key_secret: minted.work_key.secret,
      architect_grant_id: minted.grant.id,
      architect_scope_repo: minted.grant.scope_repo,
      architect_scope_base_branch: minted.grant.scope_base_branch,
      phase_parent_checkpoint: phase_parent_checkpoint_text,
      pilot_phase_parent_seed: phase_seed_branch,
      pilot_phase_parent_branch: phase_parent_branch,
      kraken_owner: kraken_owner,
      phase_parent_branch_created_by_bootstrap?: phase_parent_created_by_bootstrap?,
      phase_created?: phase_created?,
      anchor_created?: anchor_created?
    }
  end)

case bootstrap_result do
  {:ok, output} ->
    handoff_payload = Jason.encode!(output)

    case System.cmd(handoff_cmd, ["kraken-pilot-mini-phase"], input: handoff_payload, stderr_to_stdout: true) do
      {_output, 0} ->
        output
        |> Map.drop([:anchor_worker_key_secret, :architect_work_key_secret])
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      {_output, status} ->
        cleanup = fn label, fun ->
          try do
            {label, fun.()}
          rescue
            error -> {label, {:error, Exception.message(error)}}
          end
        end

        cleanup_results = [
          cleanup.(:revoke_anchor_worker_grant, fn -> AccessGrantService.revoke(Repo, output.anchor_worker_grant_id) end),
          cleanup.(:revoke_architect_grant, fn -> AccessGrantService.revoke(Repo, output.architect_grant_id) end),
          if(output.anchor_created?,
            do: cleanup.(:delete_anchor_package, fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM sympp_work_packages WHERE id = ?", [output.anchor_work_package_id]) end),
            else: {:preserve_existing_anchor_package, :ok}
          ),
          if(output.phase_created?,
            do: cleanup.(:delete_phase, fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM sympp_phases WHERE id = ?", [output.phase_id]) end),
            else: {:preserve_existing_phase, :ok}
          ),
          if(output.phase_parent_branch_created_by_bootstrap?,
            do: cleanup.(:delete_remote_phase_parent_branch, fn -> System.cmd("git", ["-C", output.kraken_owner, "push", "origin", ":refs/heads/#{output.pilot_phase_parent_branch}"]) end),
            else: {:preserve_existing_phase_parent_branch, :ok}
          )
        ]

        raise "approved secret handoff failed with exit #{status}; cleanup results: #{inspect(cleanup_results)}"
    end

  {:error, reason} -> raise "fallback bootstrap failed: #{inspect(reason)}"
end
'@ | Set-Content -Path .\tmp_kraken_pilot_phase_bootstrap.exs -Encoding utf8
mise exec -- mix run .\tmp_kraken_pilot_phase_bootstrap.exs
$bootstrapExit = $LASTEXITCODE
Remove-Item .\tmp_kraken_pilot_phase_bootstrap.exs
Pop-Location
Remove-Item Env:\SYMPP_PILOT_PHASE_PARENT_CHECKPOINT_TEXT
Remove-Item Env:\SYMPP_PILOT_PHASE_SEED_BRANCH
Remove-Item Env:\SYMPP_PILOT_PHASE_PARENT_RESUME
Remove-Item Env:\SYMPP_PILOT_PHASE_PARENT_CREATED_BY_BOOTSTRAP
Remove-Item Env:\SYMPP_PILOT_KRAKEN_OWNER
Remove-Item Env:\SYMPP_PILOT_PHASE_PARENT_BRANCH
if ($bootstrapExit -ne 0) { throw "Kraken pilot phase bootstrap failed with exit $bootstrapExit" }
```

Use 259,200 seconds, three days, for mini-phase pilot credentials. That window
covers two child packages with local validation and review wait time without
stranding child worker keys through the architect grant cap. At pilot closeout,
record a checkpoint to revoke or rotate the architect grant, anchor worker
grant, and any child worker grants before calling the pilot complete.

Use the printed `architect_grant_id` and `anchor_worker_grant_id`, and obtain
both work keys through the approved operator secret handoff path. Do not print
either secret into shell logs, planning files, PR bodies, or review text. If no
approved handoff exists, record the mini-phase as blocked rather than exposing
the secret.

   In the owner-held anchor worker MCP session, claim the anchor worker key.
   The anchor worker records parent planning/progress evidence only; it must
   not implement child work. On a fresh run, move the anchor out of
   `ready_for_worker` before the architect creates child packages. On an
   explicit same-pilot resume, first inspect the current anchor status and
   apply only the missing lifecycle transitions below; do not replay a
   transition whose `expected_status` is already in the past. The
   `claim_work_key` call below claims or reconnects the access grant for this
   MCP session; it does not move the WorkPackage status and does not require
   the WorkPackage to still be `ready_for_worker`. If reconnecting an
   already-claimed grant, use the same `claimed_by` value that originally
   claimed it; otherwise the MCP server rejects the rebind as
   `already_claimed`:

```text
claim_work_key(secret: <anchor_worker_key_secret>, claimed_by: "kraken-pilot-anchor-worker")
```

If the anchor status is `ready_for_worker`, call:

```json
{
  "expected_status": "ready_for_worker",
  "status": "claimed",
  "reason": "Anchor worker key claimed; parent coordination owner is active."
}
```

If the anchor status is now `claimed`, call:

```json
{
  "expected_status": "claimed",
  "status": "planning",
  "reason": "Anchor worker claimed; parent coordination plan is active."
}
```

If the anchor status is now `planning`, call:

```json
{
  "expected_status": "planning",
  "status": "implementing",
  "reason": "Anchor worker is holding parent coordination evidence while the architect creates and reviews children."
}
```

If the anchor is already `implementing`, skip the lifecycle calls above and
continue with parent planning/progress evidence. If the anchor is already
`reviewing`, `ci_waiting`, or `ready_for_human_merge`, stop the resume and
close or recreate the mini-phase; those states are past child orchestration.

   Then call `read_task_plan`. If the rendered plan already contains
   `anchor-coordinate` and `anchor-recommendation` from an earlier resume of
   this runbook, reuse those explicit node IDs and do not append duplicates.
   Otherwise append the owner-held anchor plan nodes with explicit IDs:

```text
update_task_plan(
  patch: {
    "nodes": [
      {
        "id": "anchor-coordinate",
        "title": "Coordinate Kraken pilot mini-phase",
        "body": "Create exactly two child packages, approve ready children, and record phase merge artifacts.",
        "status": "pending"
      },
      {
        "id": "anchor-recommendation",
        "title": "Record pilot recommendation",
        "body": "Append the integration finding and request_scope_expansion recommendation after child merge artifacts are recorded.",
        "status": "pending"
      }
    ]
  },
  expected_version: <current_task_plan_version_from_read_task_plan>
)
```

   In the architect MCP session, call:

```text
claim_work_key(secret: <architect_work_key_secret>, claimed_by: "kraken-pilot-architect")
```

   Do not call `create_child_work_package`, `mint_child_worker_key`,
   `approve_child_ready_state`, or `merge_child_into_phase` until this claim
   succeeds and `get_current_assignment()` shows `grant_role=architect`.
4. Call `create_child_work_package` for `KRAKEN-PILOT-MP-001A` with:

```json
{
  "package": {
    "id": "KRAKEN-PILOT-MP-001A",
    "kind": "phase_child",
    "policy_template": "phase_child",
    "title": "Kraken pilot mini-phase docs boundary",
    "product_description": "Prove a docs/runbooks-only Kraken child package inside a Symphony++ mini-phase.",
    "engineering_scope": "Update only Kraken docs or runbooks; do not change runtime code, tests, provider behavior, or active rewrite branches.",
    "base_branch": "feat/sympp-pilot-mini-phase",
    "branch_pattern": "feat/sympp-pilot-mini-doc-boundary",
    "allowed_file_globs": ["README.md", "spec.md", "docs/**", "runbooks/**"],
    "acceptance_criteria": [
      "Child stays inside docs/runbooks-only scope.",
      "Focused docs validation passes.",
      "Current-head attach_branch and attach_pr metadata are recorded.",
      "review_t1 and review_t2 evidence are recorded."
    ]
  }
}
```

5. Call `create_child_work_package` for `KRAKEN-PILOT-MP-001B` with:

```json
{
  "package": {
    "id": "KRAKEN-PILOT-MP-001B",
    "kind": "phase_child",
    "policy_template": "phase_child",
    "title": "Kraken pilot mini-phase focused regression",
    "product_description": "Prove a second disjoint Kraken child package with focused validation inside a Symphony++ mini-phase.",
    "engineering_scope": "Implement one focused regression test or narrow scripts-only cleanup outside Child A docs/runbooks scope.",
    "base_branch": "feat/sympp-pilot-mini-phase",
    "branch_pattern": "feat/sympp-pilot-mini-focused-regression",
    "allowed_file_globs": ["conftest.py", "tests/**", "apps/**/tests/**", "packages/**/tests/**", "scripts/**"],
    "acceptance_criteria": [
      "Child stays outside docs-only child scope.",
      "Focused regression or validation check passes.",
      "Current-head attach_branch and attach_pr metadata are recorded.",
      "review_t1 and review_t2 evidence are recorded."
    ]
  }
}
```

6. Before dispatching either child worker, publish or verify the non-production
   phase parent branch that child PRs will target. This step must happen before
   child workers open PRs; GitHub cannot create a PR against a missing base
   branch. Use a dedicated phase-parent worktree or the existing worktree that
   already owns `feat/sympp-pilot-mini-phase`:

```powershell
$krakenOwner = "C:\Code\nextide-saas-vod-kraken"
$phaseWorktree = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-phase"
$phaseSeedBranch = "main" # Replace with "dev" only after recording the operator-approved dev seed override.
$phaseParentResume = $false # Set to $true only for a same-pilot retry/rotation with preserved checkpoint evidence.
git -C $krakenOwner fetch origin "${phaseSeedBranch}:refs/remotes/origin/${phaseSeedBranch}"
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch origin/$phaseSeedBranch before phase branch setup." }

git -C $krakenOwner worktree list
# If `worktree list` already shows feat/sympp-pilot-mini-phase elsewhere,
# set $phaseWorktree to that existing path instead of creating a new worktree.
$phaseBranchExists = $false
git -C $krakenOwner ls-remote --exit-code --heads origin feat/sympp-pilot-mini-phase *> $null
$phaseRemoteCheckExit = $LASTEXITCODE
if ($phaseRemoteCheckExit -eq 0) {
  $phaseBranchExists = $true
  git -C $krakenOwner fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -ne 0) {
    throw "Existing phase parent branch could not be fetched. Stop before dispatching child workers."
  }
  $approvedSeedHead = git -C $krakenOwner rev-parse "origin/${phaseSeedBranch}"
  $phaseParentHead = git -C $krakenOwner rev-parse origin/feat/sympp-pilot-mini-phase
  if ($phaseParentHead -ne $approvedSeedHead) {
    if (!$phaseParentResume) {
      throw "Existing phase parent branch already contains commits. Preserve evidence, then explicitly delete/reset it before fresh child dispatch, or set phaseParentResume=true only for a same-pilot retry/rotation."
    }
    git -C $krakenOwner merge-base --is-ancestor "origin/${phaseSeedBranch}" origin/feat/sympp-pilot-mini-phase
    if ($LASTEXITCODE -ne 0) {
      throw "Resume requested, but existing phase parent branch is not descended from origin/$phaseSeedBranch. Stop before dispatching child workers."
    }
  }
} elseif ($phaseRemoteCheckExit -eq 2) {
  $phaseBranchExists = $false
} else {
  throw "Could not verify remote phase parent branch existence. Stop before dispatching child workers."
}

if (!(Test-Path $phaseWorktree)) {
  if ($phaseBranchExists) {
    git -C $krakenOwner show-ref --verify --quiet refs/heads/feat/sympp-pilot-mini-phase
    if ($LASTEXITCODE -eq 0) {
      git -C $krakenOwner worktree add $phaseWorktree feat/sympp-pilot-mini-phase
      if ($LASTEXITCODE -ne 0) {
        throw "Existing local phase parent branch could not be checked out in $phaseWorktree. Reuse the worktree that already owns it or remove the stale worktree before dispatch."
      }
    } else {
      git -C $krakenOwner worktree add -b feat/sympp-pilot-mini-phase $phaseWorktree origin/feat/sympp-pilot-mini-phase
      if ($LASTEXITCODE -ne 0) {
        throw "Existing remote phase parent branch was fetched but phase worktree creation failed. Stop before dispatching child workers."
      }
    }
  } else {
    git -C $krakenOwner worktree add -b feat/sympp-pilot-mini-phase $phaseWorktree "origin/${phaseSeedBranch}"
    if ($LASTEXITCODE -ne 0) {
      throw "Initial phase parent worktree creation failed. Stop before dispatching child workers."
    }
    git -C $phaseWorktree push origin HEAD:feat/sympp-pilot-mini-phase
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to publish initial phase parent branch. Stop before dispatching child workers."
    }
    git -C $phaseWorktree fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to fetch newly published phase parent branch. Stop before dispatching child workers."
    }
    $approvedSeedHead = git -C $phaseWorktree rev-parse "origin/${phaseSeedBranch}"
    $phaseParentHead = git -C $phaseWorktree rev-parse origin/feat/sympp-pilot-mini-phase
    if ($phaseParentHead -ne $approvedSeedHead) {
      throw "Newly published phase parent branch does not match origin/$phaseSeedBranch. Stop before dispatching child workers."
    }
  }
}

$currentBranch = git -C $phaseWorktree branch --show-current
if ($currentBranch -ne "feat/sympp-pilot-mini-phase") {
  throw "Expected phase parent worktree on feat/sympp-pilot-mini-phase before child PR creation."
}
$dirty = git -C $phaseWorktree status --porcelain
if (![string]::IsNullOrWhiteSpace($dirty)) {
  throw "$phaseWorktree has uncommitted changes. Stop before dispatching child workers."
}
if (!$phaseBranchExists) {
  $approvedSeedHead = git -C $phaseWorktree rev-parse "origin/${phaseSeedBranch}"
  $localPhaseHead = git -C $phaseWorktree rev-parse HEAD
  if ($localPhaseHead -ne $approvedSeedHead) {
    throw "Unpublished phase parent worktree is not at origin/$phaseSeedBranch. Stop before publishing child PR base."
  }
  git -C $phaseWorktree push origin HEAD:feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -ne 0) { throw "Failed to publish existing local phase parent branch before child PR creation." }
  $phaseBranchExists = $true
}
git -C $phaseWorktree fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
if ($LASTEXITCODE -ne 0) { throw "Failed to refresh phase parent branch before child PR creation." }
$localPhaseHead = git -C $phaseWorktree rev-parse HEAD
$remotePhaseHead = git -C $phaseWorktree rev-parse origin/feat/sympp-pilot-mini-phase
if ($localPhaseHead -ne $remotePhaseHead) {
  throw "$phaseWorktree HEAD does not match origin/feat/sympp-pilot-mini-phase. Stop before child PR creation."
}
```

7. Create or verify the implementation worktree for the child that is about to
   be dispatched. These worktrees start from the current phase parent branch;
   if a path already exists, it must be on the expected child branch, clean,
   and still at the current phase parent head before dispatch. For a sequential
   pilot, run this for Child A first, then after Child A is integrated and
   `feat/sympp-pilot-mini-phase` advances, rerun steps 6 and 7 for Child B
   before minting the Child B key. If Child B was prepared earlier and has no
   pushed branch yet, remove/recreate that disposable worktree from the updated
   phase parent instead of dispatching against the stale parent. If the pilot is
   intentionally parallel, run this for both children before either worker is
   dispatched and do not integrate either child until both reviews are complete:

```powershell
$krakenOwner = "C:\Code\nextide-saas-vod-kraken"
$phaseParentBranch = "feat/sympp-pilot-mini-phase"
$child = @{
  Label = "Child A"
  Path = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-child-a"
  Branch = "feat/sympp-pilot-mini-doc-boundary"
}
# For sequential Child B after Child A integration, rerun this same block with:
# $child = @{
#   Label = "Child B"
#   Path = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-child-b"
#   Branch = "feat/sympp-pilot-mini-focused-regression"
# }
git -C $krakenOwner fetch origin "${phaseParentBranch}:refs/remotes/origin/${phaseParentBranch}"
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch phase parent before child worktree setup." }
$phaseParentHead = git -C $krakenOwner rev-parse "origin/${phaseParentBranch}"
git -C $krakenOwner ls-remote --exit-code --heads origin $child.Branch *> $null
if ($LASTEXITCODE -eq 0) {
  throw "$($child.Label) remote branch $($child.Branch) already exists. Preserve evidence, then explicitly delete or rename the stale remote branch before dispatch."
} elseif ($LASTEXITCODE -ne 2) {
  throw "Could not verify $($child.Label) remote branch before child worktree setup."
}
if (!(Test-Path $child.Path)) {
  git -C $krakenOwner show-ref --verify --quiet "refs/heads/$($child.Branch)"
  if ($LASTEXITCODE -eq 0) {
    git -C $krakenOwner worktree add $child.Path $child.Branch
    if ($LASTEXITCODE -ne 0) { throw "$($child.Label) worktree reuse from existing local branch failed; inspect worktree list before dispatch." }
    $reusedChildHead = git -C $child.Path rev-parse HEAD
    if ($reusedChildHead -ne $phaseParentHead) {
      throw "$($child.Label) existing local branch is not at origin/${phaseParentBranch}. Reset/recreate intentionally before dispatch."
    }
  } elseif ($LASTEXITCODE -eq 1) {
    git -C $krakenOwner worktree add -b $child.Branch $child.Path "origin/${phaseParentBranch}"
    if ($LASTEXITCODE -ne 0) { throw "$($child.Label) worktree creation failed." }
  } else {
    throw "Could not inspect local $($child.Label) branch before child worktree setup."
  }
}
$currentBranch = git -C $child.Path branch --show-current
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $child.Branch) {
  throw "$($child.Label) worktree is not on $($child.Branch). Remove/recreate before dispatch."
}
$dirty = git -C $child.Path status --porcelain
if (![string]::IsNullOrWhiteSpace($dirty)) {
  throw "$($child.Label) worktree has uncommitted changes. Stop before dispatch."
}
$childHead = git -C $child.Path rev-parse HEAD
if ($childHead -ne $phaseParentHead) {
  throw "$($child.Label) worktree is stale. Remove/recreate it from origin/${phaseParentBranch} before dispatch."
}
```

8. Mint a child worker key only for the next child that is about to be
   dispatched. Do not mint both child keys up front: `mint_child_worker_key`
   inherits the architect grant expiry when no explicit expiry is supplied, and
   a sequential or review-heavy pilot can otherwise strand the second child
   before it starts. For first dispatch, step 7 must already have proven that
   no leftover remote child branch exists. Do not document or attempt a normal
   replacement-key reassignment after a child has already been claimed or
   started: the current `mint_child_worker_key` path is only usable before
   child work starts and rejects active claimed child grants. If a child worker
   is interrupted after claim, record the package as blocked, preserve branch/PR
   evidence, and ask the operator to choose an explicit recovery path: wait for
   the original worker, abandon/recreate the child package with a new pilot ID,
   or use an approved admin revocation/reassignment mechanism outside this
   pilot playbook. Use only the approved child-secret handoff wrapper. Do not
   paste a raw
   `mint_child_worker_key` call into a transcript or planning file, because the
   normal tool response contains the live one-time child worker secret. The
   wrapper must perform the MCP call, store the returned secret in the approved
   secret manager, and print only non-secret grant metadata before that child
   worker is dispatched. If the wrapper cannot confirm storage, do not dispatch
   the worker; record the live child grant as residual access risk until expiry
   or approved admin revocation and do not call `mark_ready` for the child. If
   the architect grant has too little remaining lifetime for the child
   implementation plus review window, rotate/recreate the grant through an
   approved operator path before minting the child key.

   Example Child A wrapper input, run only immediately before dispatching
   Child A:

```json
{
  "tool": "mint_child_worker_key",
  "work_package_id": "KRAKEN-PILOT-MP-001A",
  "template": {
    "capabilities": ["worker:claim", "worker:lifecycle.transition"]
  }
}
```

   Example Child B wrapper input, run only immediately before dispatching
   Child B:

```json
{
  "tool": "mint_child_worker_key",
  "work_package_id": "KRAKEN-PILOT-MP-001B",
  "template": {
    "capabilities": ["worker:claim", "worker:lifecycle.transition"]
  }
}
```

   Those are the only child worker grant capabilities currently accepted by the
   implementation. Do not add unsupported capability strings to the template;
   the current `mint_child_worker_key` implementation rejects them. After the
   child worker claims the key, the worker session exposes the
   assignment-scoped evidence and readiness tools used below.

9. Each child worker must move through the current worker lifecycle before
   implementation: `ready_for_worker -> claimed -> planning -> implementing`.
   Claiming a key authenticates the worker but does not change the package
   status. Immediately after `claim_work_key(...)` succeeds and
   `get_current_assignment()` shows the expected child package, call:

```json
{
  "expected_status": "ready_for_worker",
  "status": "claimed",
  "reason": "Child worker key claimed."
}
```

```json
{
  "expected_status": "claimed",
  "status": "planning",
  "reason": "Child scope and validation plan are being recorded."
}
```

   Then each child worker must create its task-plan nodes before
   implementation. `create_child_work_package` does not seed task-plan nodes.
   The worker must call `read_task_plan`, then append and later complete these
   nodes with the `update_task_plan` patch shape. The explicit node IDs below
   are the IDs used in the later completion patches.

For Child A:

```text
update_task_plan(
  patch: {
    "nodes": [
      {
        "id": "child-a-scope",
        "title": "Validate Child A docs/runbooks scope",
        "body": "Keep changes inside docs/** and runbooks/**, then record focused docs validation.",
        "status": "pending"
      },
      {
        "id": "child-a-review",
        "title": "Complete Child A review gates",
        "body": "Attach current branch/PR metadata and record review_t1 and review_t2 evidence for the same head.",
        "status": "pending"
      }
    ]
  },
  expected_version: <current_task_plan_version>
)
```

For Child B:

```text
update_task_plan(
  patch: {
    "nodes": [
      {
        "id": "child-b-scope",
        "title": "Validate Child B tests/scripts scope",
        "body": "Keep changes inside test or scripts globs, then record focused validation.",
        "status": "pending"
      },
      {
        "id": "child-b-review",
        "title": "Complete Child B review gates",
        "body": "Attach current branch/PR metadata and record review_t1 and review_t2 evidence for the same head.",
        "status": "pending"
      }
    ]
  },
  expected_version: <current_task_plan_version>
)
```

After the relevant child plan nodes are appended, move the child package into
implementation:

```json
{
  "expected_status": "planning",
  "status": "implementing",
  "reason": "Child implementation is starting from the recorded plan."
}
```

10. Each child worker should attach branch metadata, PR metadata, and a review
   package for the same current head before calling `mark_ready`. Child PRs
   must target `feat/sympp-pilot-mini-phase`, not `main`; direct child PR merge
   to `main` is outside the pilot. Current `mark_ready` for `phase_child`
   requires branch, PR, and review-package evidence before
   `ready_for_architect_merge`. `sync_pr` is required by this pilot playbook
   before child readiness evidence is accepted so the architect has current
   semantic PR state to inspect. If GitHub PR sync is unavailable, block the
   child package and record a progress blocker instead of substituting manual
   evidence; the manual checklist below is additional audit evidence, not a
   replacement for `sync_pr`. For Child A, call `attach_branch` with:

```json
{
  "branch": "feat/sympp-pilot-mini-doc-boundary",
  "head_sha": "<child-a-head-sha>"
}
```

Then call `attach_pr` with:

```json
{
  "url": "<child-a-pr-url>",
  "head_sha": "<child-a-head-sha>"
}
```

Then call `sync_pr` for the same current head:

```json
{
  "url": "<child-a-pr-url>",
  "head_sha": "<child-a-head-sha>",
  "metadata": {
    "head_sha": "<child-a-head-sha>",
    "base_branch": "feat/sympp-pilot-mini-phase",
    "reviewed_base_sha": "<child-a-reviewed-pr-base-sha>",
    "check_summary": {
      "conclusion": "success",
      "head_sha": "<child-a-head-sha>"
    },
    "review_state": {
      "state": "approved",
      "head_sha": "<child-a-head-sha>"
    },
    "merge_state": {
      "state": "clean",
      "base_branch": "feat/sympp-pilot-mini-phase"
    }
  }
}
```

Then call `submit_review_package` with:

```json
{
  "summary": "Child A validation and reviews are green for the current head.",
  "tests": ["<child-a-focused-validation-command>"],
  "artifacts": ["<child-a-review-artifact-or-log>"],
  "head_sha": "<child-a-head-sha>",
  "acceptance_criteria_met": true,
  "reviews": [
    {"lane": "review_t1", "verdict": "green"},
    {"lane": "review_t2", "verdict": "green"}
  ]
}
```

Then call `read_task_plan` again and use the refreshed post-append
`expected_version` before completing Child A's worker-created plan nodes:

```text
update_task_plan(
  patch: {
    "nodes": [
      {"id": "child-a-scope", "status": "done"},
      {"id": "child-a-review", "status": "done"}
    ]
  },
  expected_version: <post-append_task_plan_version_from_read_task_plan>
)
```

Then move from implementation to review, then to CI waiting before
`mark_ready`:

```json
{
  "expected_status": "implementing",
  "status": "reviewing",
  "reason": "Child A implementation is complete; collecting validation and review evidence."
}
```

```json
{
  "expected_status": "reviewing",
  "status": "ci_waiting",
  "reason": "Child A validation, branch, PR, and review evidence are current."
}
```

For Child B, call `attach_branch` with:

```json
{
  "branch": "feat/sympp-pilot-mini-focused-regression",
  "head_sha": "<child-b-head-sha>"
}
```

Then call `attach_pr` with:

```json
{
  "url": "<child-b-pr-url>",
  "head_sha": "<child-b-head-sha>"
}
```

Then call `sync_pr` for the same current head:

```json
{
  "url": "<child-b-pr-url>",
  "head_sha": "<child-b-head-sha>",
  "metadata": {
    "head_sha": "<child-b-head-sha>",
    "base_branch": "feat/sympp-pilot-mini-phase",
    "reviewed_base_sha": "<child-b-reviewed-pr-base-sha>",
    "check_summary": {
      "conclusion": "success",
      "head_sha": "<child-b-head-sha>"
    },
    "review_state": {
      "state": "approved",
      "head_sha": "<child-b-head-sha>"
    },
    "merge_state": {
      "state": "clean",
      "base_branch": "feat/sympp-pilot-mini-phase"
    }
  }
}
```

Then call `submit_review_package` with:

```json
{
  "summary": "Child B validation and reviews are green for the current head.",
  "tests": ["<child-b-focused-validation-command>"],
  "artifacts": ["<child-b-review-artifact-or-log>"],
  "head_sha": "<child-b-head-sha>",
  "acceptance_criteria_met": true,
  "reviews": [
    {"lane": "review_t1", "verdict": "green"},
    {"lane": "review_t2", "verdict": "green"}
  ]
}
```

Then call `read_task_plan` again and use the refreshed post-append
`expected_version` before completing Child B's worker-created plan nodes:

```text
update_task_plan(
  patch: {
    "nodes": [
      {"id": "child-b-scope", "status": "done"},
      {"id": "child-b-review", "status": "done"}
    ]
  },
  expected_version: <post-append_task_plan_version_from_read_task_plan>
)
```

Then move from implementation to review, then to CI waiting before
`mark_ready`:

```json
{
  "expected_status": "implementing",
  "status": "reviewing",
  "reason": "Child B implementation is complete; collecting validation and review evidence."
}
```

```json
{
  "expected_status": "reviewing",
  "status": "ci_waiting",
  "reason": "Child B validation, branch, PR, and review evidence are current."
}
```

11. After each child reaches `ready_for_architect_merge`, the architect must
   run this manual approval checklist before approving the child. Do not rely
   on child status alone: current `mark_ready` blocks missing branch, PR, and
   review-package evidence before `ready_for_architect_merge`, but the
   architect still has to verify the operator-visible payloads and the manual
   changed-file scope check before approving the child. If any check fails,
   withhold `approve_child_ready_state`; do not ask the already-ready child
   worker to append evidence or transition back to `blocked`, because current
   worker tools reject those mutations after `ready_for_architect_merge`.
   Record the rejection and required rework in the owner-held anchor package
   with `append_finding` / `append_progress`, then create or dispatch a new
   corrected child package/branch for the rework. Architect sessions do not
   have worker write tools.

Checklist. Use the dashboard/API artifact detail view, child PR page, and child
worker final output to inspect artifact payloads. The current architect MCP
read surface is not sufficient by itself because it exposes child status and
artifact counts, not every attached artifact payload. If the dashboard/API or
operator artifacts cannot show the required payloads, withhold
`approve_child_ready_state` and record a blocker instead of approving from
counts alone.

- Child branch exists on origin.
- Child PR exists and targets `feat/sympp-pilot-mini-phase`.
- Child PR head SHA, `attach_branch` SHA, `attach_pr` SHA, and
  `submit_review_package.head_sha` are the same commit.
- Reviewed PR base SHA is recorded from the PR page/API at the time the review
  package is submitted and matches `sync_pr.metadata.reviewed_base_sha`.
- Reviewed PR base SHA matches the current `origin/feat/sympp-pilot-mini-phase`
  head at approval time. If the phase parent advanced after the child's review,
  withhold approval and require the child to refresh onto the current phase
  parent, rerun validation/reviews, call `sync_pr` with the new
  `reviewed_base_sha`, and submit a fresh review package.
- `review_t1` and `review_t2` artifacts match that same commit.
- Changed files stay inside the child's intended globs.

Run this phase-parent freshness check for each child before approval. Replace
`<child-reviewed-pr-base-sha>` with that child's recorded
`sync_pr.metadata.reviewed_base_sha`:

```powershell
$krakenOwner = "C:\Code\nextide-saas-vod-kraken"
$phaseParentBranch = "feat/sympp-pilot-mini-phase"
$childReviewedBaseSha = "<child-reviewed-pr-base-sha>"
git -C $krakenOwner fetch origin "${phaseParentBranch}:refs/remotes/origin/${phaseParentBranch}"
if ($LASTEXITCODE -ne 0) { throw "Failed to refresh phase parent before child approval." }
$currentPhaseHead = git -C $krakenOwner rev-parse "origin/${phaseParentBranch}"
if ($childReviewedBaseSha -ne $currentPhaseHead) {
  throw "Child review base is stale; refresh child onto current phase parent, rerun validation/reviews, sync_pr, and submit a fresh review package."
}
```

Run the Child A changed-file scope check from the active Child A
implementation worktree:

```powershell
$KRAKEN_CHILD_A_WORKTREE = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-child-a"
$KRAKEN_CHILD_A_BRANCH = "feat/sympp-pilot-mini-doc-boundary"
$KRAKEN_CHILD_A_REVIEWED_BASE_SHA = "<child-a-reviewed-pr-base-sha>"
$KRAKEN_CHILD_A_REVIEWED_HEAD_SHA = "<child-a-head-sha>"
git -C $KRAKEN_CHILD_A_WORKTREE fetch origin "${KRAKEN_CHILD_A_BRANCH}:refs/remotes/origin/${KRAKEN_CHILD_A_BRANCH}"
if ($LASTEXITCODE -ne 0) { throw "Child A branch fetch failed" }
git -C $KRAKEN_CHILD_A_WORKTREE cat-file -e "$KRAKEN_CHILD_A_REVIEWED_BASE_SHA^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Child A reviewed base SHA is not present locally" }
git -C $KRAKEN_CHILD_A_WORKTREE cat-file -e "$KRAKEN_CHILD_A_REVIEWED_HEAD_SHA^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Child A reviewed head SHA is not present locally" }
$currentBranch = git -C $KRAKEN_CHILD_A_WORKTREE branch --show-current
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $KRAKEN_CHILD_A_BRANCH) {
  throw "Child A scope check is not on the active pilot branch"
}
$currentHead = git -C $KRAKEN_CHILD_A_WORKTREE rev-parse HEAD
if ($currentHead -ne $KRAKEN_CHILD_A_REVIEWED_HEAD_SHA) {
  throw "Child A worktree HEAD does not match reviewed head SHA"
}
git -C $KRAKEN_CHILD_A_WORKTREE merge-base --is-ancestor $KRAKEN_CHILD_A_REVIEWED_BASE_SHA $KRAKEN_CHILD_A_REVIEWED_HEAD_SHA
if ($LASTEXITCODE -ne 0) { throw "Child A reviewed base is not an ancestor of reviewed head" }
$changedFiles = @(git -C $KRAKEN_CHILD_A_WORKTREE diff --name-only $KRAKEN_CHILD_A_REVIEWED_BASE_SHA $KRAKEN_CHILD_A_REVIEWED_HEAD_SHA)
if ($LASTEXITCODE -ne 0) { throw "Child A scope check diff failed" }
$allowedPathRegex = '^(README\.md$|spec\.md$|docs/|runbooks/)'
$outOfScope = @($changedFiles | Where-Object { $_ -notmatch $allowedPathRegex })
if ($outOfScope.Count -gt 0) {
  $outOfScope | ForEach-Object { Write-Error "Out-of-scope Child A path: $_" }
  throw "Child A scope check failed"
}
```

Run the Child B changed-file scope check from the active Child B
implementation worktree:

```powershell
$KRAKEN_CHILD_B_WORKTREE = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-child-b"
$KRAKEN_CHILD_B_BRANCH = "feat/sympp-pilot-mini-focused-regression"
$KRAKEN_CHILD_B_REVIEWED_BASE_SHA = "<child-b-reviewed-pr-base-sha>"
$KRAKEN_CHILD_B_REVIEWED_HEAD_SHA = "<child-b-head-sha>"
git -C $KRAKEN_CHILD_B_WORKTREE fetch origin "${KRAKEN_CHILD_B_BRANCH}:refs/remotes/origin/${KRAKEN_CHILD_B_BRANCH}"
if ($LASTEXITCODE -ne 0) { throw "Child B branch fetch failed" }
git -C $KRAKEN_CHILD_B_WORKTREE cat-file -e "$KRAKEN_CHILD_B_REVIEWED_BASE_SHA^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Child B reviewed base SHA is not present locally" }
git -C $KRAKEN_CHILD_B_WORKTREE cat-file -e "$KRAKEN_CHILD_B_REVIEWED_HEAD_SHA^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Child B reviewed head SHA is not present locally" }
$currentBranch = git -C $KRAKEN_CHILD_B_WORKTREE branch --show-current
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $KRAKEN_CHILD_B_BRANCH) {
  throw "Child B scope check is not on the active pilot branch"
}
$currentHead = git -C $KRAKEN_CHILD_B_WORKTREE rev-parse HEAD
if ($currentHead -ne $KRAKEN_CHILD_B_REVIEWED_HEAD_SHA) {
  throw "Child B worktree HEAD does not match reviewed head SHA"
}
git -C $KRAKEN_CHILD_B_WORKTREE merge-base --is-ancestor $KRAKEN_CHILD_B_REVIEWED_BASE_SHA $KRAKEN_CHILD_B_REVIEWED_HEAD_SHA
if ($LASTEXITCODE -ne 0) { throw "Child B reviewed base is not an ancestor of reviewed head" }
$changedFiles = @(git -C $KRAKEN_CHILD_B_WORKTREE diff --name-only $KRAKEN_CHILD_B_REVIEWED_BASE_SHA $KRAKEN_CHILD_B_REVIEWED_HEAD_SHA)
if ($LASTEXITCODE -ne 0) { throw "Child B scope check diff failed" }
$allowedPathRegex = '^(conftest\.py$|tests/|apps/(.*/)?tests/|packages/(.*/)?tests/|scripts/)'
$outOfScope = @($changedFiles | Where-Object { $_ -notmatch $allowedPathRegex })
if ($outOfScope.Count -gt 0) {
  $outOfScope | ForEach-Object { Write-Error "Out-of-scope Child B path: $_" }
  throw "Child B scope check failed"
}
```

Only after the checklist passes, approve each child with
`approve_child_ready_state`:

```json
{
  "work_package_id": "KRAKEN-PILOT-MP-001A",
  "rationale": "Child A has current-head branch, PR, validation, review_t1, and review_t2 evidence.",
  "request_id": "kraken-pilot-mp-001a-approve"
}
```

```json
{
  "work_package_id": "KRAKEN-PILOT-MP-001B",
  "rationale": "Child B has current-head branch, PR, validation, review_t1, and review_t2 evidence.",
  "request_id": "kraken-pilot-mp-001b-approve"
}
```
12. Integrate each approved child branch into the non-production phase parent
   branch before
   recording the Symphony++ phase merge artifact. Do not merge protected
   branches, production branches, or `main` during the pilot. Use the exact
   child `head_sha` value from that child's attached branch/PR and review
   package evidence at the time `approve_child_ready_state` was called; do not
   use moving branch tips. In a sequential pilot, run this once for Child A,
   record Child A's merge artifact, then prepare/review Child B against the
   advanced phase parent and run this again for Child B:

```powershell
$krakenOwner = "C:\Code\nextide-saas-vod-kraken"
$phaseSeedBranch = "main" # Replace with "dev" only after recording the operator-approved dev seed override.
$childLabel = "Child A"
$childWorkPackageId = "KRAKEN-PILOT-MP-001A"
$childBranch = "feat/sympp-pilot-mini-doc-boundary"
$childReviewedBaseSha = "<KRAKEN-PILOT-MP-001A-reviewed-base-sha>"
$childReviewedHead = "<KRAKEN-PILOT-MP-001A-approved-head-sha>"
# For sequential Child B, rerun this block with:
# $childLabel = "Child B"
# $childWorkPackageId = "KRAKEN-PILOT-MP-001B"
# $childBranch = "feat/sympp-pilot-mini-focused-regression"
# $childReviewedBaseSha = "<KRAKEN-PILOT-MP-001B-reviewed-base-sha>"
# $childReviewedHead = "<KRAKEN-PILOT-MP-001B-approved-head-sha>"
git -C $krakenOwner fetch origin "${phaseSeedBranch}:refs/remotes/origin/${phaseSeedBranch}"
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch origin/$phaseSeedBranch before merging $childLabel." }
git -C $krakenOwner fetch origin "${childBranch}:refs/remotes/origin/${childBranch}"
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch origin/$childBranch before merging $childLabel." }
$phaseParentRemoteExistsForMerge = $false
git -C $krakenOwner ls-remote --exit-code --heads origin feat/sympp-pilot-mini-phase *> $null
if ($LASTEXITCODE -eq 0) {
  $phaseParentRemoteExistsForMerge = $true
  git -C $krakenOwner fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -ne 0) { throw "Failed to refresh origin/feat/sympp-pilot-mini-phase before merging $childLabel." }
} elseif ($LASTEXITCODE -ne 2) {
  throw "Could not verify remote phase parent branch before merging $childLabel."
}
git -C $krakenOwner cat-file -e "$childReviewedHead^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Approved $childLabel SHA is not present locally. Stop before merging child branch." }
git -C $krakenOwner merge-base --is-ancestor $childReviewedHead "origin/${childBranch}"
if ($LASTEXITCODE -ne 0) { throw "Approved $childLabel SHA is not reachable from origin/$childBranch. Stop before merging child branch." }

# Use the worktree that owns the phase parent branch. If none exists, create one.
git -C $krakenOwner worktree list
$phaseWorktree = "C:\Code\nextide-saas-vod-kraken-sympp-pilot-phase"
# If `worktree list` already shows feat/sympp-pilot-mini-phase elsewhere,
# set $phaseWorktree to that existing path instead of creating a new worktree.
$phaseBranchExists = $false
git -C $krakenOwner ls-remote --exit-code --heads origin feat/sympp-pilot-mini-phase *> $null
$phaseRemoteCheckExit = $LASTEXITCODE
if ($phaseRemoteCheckExit -eq 0) {
  $phaseBranchExists = $true
  git -C $krakenOwner fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -ne 0) {
    throw "Existing phase parent branch could not be fetched. Stop before creating a phase worktree."
  }
} elseif ($phaseRemoteCheckExit -eq 2) {
  $phaseBranchExists = $false
} else {
  throw "Could not verify remote phase parent branch existence. Stop before creating a phase worktree."
}
if (!(Test-Path $phaseWorktree)) {
  if ($phaseBranchExists) {
    git -C $krakenOwner show-ref --verify --quiet refs/heads/feat/sympp-pilot-mini-phase
    if ($LASTEXITCODE -eq 0) {
      git -C $krakenOwner worktree add $phaseWorktree feat/sympp-pilot-mini-phase
      if ($LASTEXITCODE -ne 0) {
        throw "Existing local phase parent branch could not be checked out in $phaseWorktree. Reuse the worktree that already owns it or remove the stale worktree before merging child branches."
      }
    } else {
      git -C $krakenOwner worktree add -b feat/sympp-pilot-mini-phase $phaseWorktree origin/feat/sympp-pilot-mini-phase
      if ($LASTEXITCODE -ne 0) {
        throw "Existing remote phase parent branch was fetched but phase worktree creation failed. Stop before merging child branches."
      }
    }
  }
}
if (!(Test-Path $phaseWorktree) -and !$phaseBranchExists) {
  git -C $krakenOwner worktree add -b feat/sympp-pilot-mini-phase $phaseWorktree "origin/${phaseSeedBranch}"
}
if (!(Test-Path $phaseWorktree)) {
  throw "No phase parent worktree available. Stop before merging child branches."
}
git -C $phaseWorktree rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  throw "$phaseWorktree exists but is not a Git worktree. Stop before merging child branches."
}
$worktreeRoot = git -C $phaseWorktree rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($worktreeRoot)) {
  throw "$phaseWorktree is not a usable Git worktree. Stop before merging child branches."
}
$currentBranch = git -C $phaseWorktree branch --show-current
if ($currentBranch -ne "feat/sympp-pilot-mini-phase") {
  throw "Expected feat/sympp-pilot-mini-phase, got $currentBranch. Stop before merging child branches."
}
$dirty = git -C $phaseWorktree status --porcelain
if (![string]::IsNullOrWhiteSpace($dirty)) {
  throw "$phaseWorktree has uncommitted changes. Stop before merging child branches."
}
$localPhaseHead = git -C $phaseWorktree rev-parse HEAD
if ($phaseBranchExists) {
  git -C $phaseWorktree fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch existing phase parent branch. Stop before merging child branches."
  }
  $remotePhaseHead = git -C $phaseWorktree rev-parse origin/feat/sympp-pilot-mini-phase
  if ($localPhaseHead -ne $remotePhaseHead) {
    throw "$phaseWorktree HEAD does not match origin/feat/sympp-pilot-mini-phase. Stop before merging child branches."
  }
  if ($childReviewedBaseSha -ne $remotePhaseHead) {
    throw "$childLabel review base is stale for the current phase parent. Refresh child, rerun validation/reviews, sync_pr, and submit a fresh review package before merging."
  }
} else {
  $approvedSeedHead = git -C $phaseWorktree rev-parse "origin/${phaseSeedBranch}"
  if ($localPhaseHead -ne $approvedSeedHead) {
    throw "No remote phase parent branch exists and $phaseWorktree HEAD is not origin/$phaseSeedBranch. Stop before merging child branches."
  }
  if ($childReviewedBaseSha -ne $localPhaseHead) {
    throw "$childLabel review base does not match unpublished phase parent. Stop before merging child branch."
  }
  git -C $phaseWorktree push origin HEAD:feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to publish initial phase parent branch. Stop before merging child branches."
  }
  git -C $phaseWorktree fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch newly published phase parent branch. Stop before merging child branches."
  }
}
$preIntegrationHead = git -C $phaseWorktree rev-parse HEAD
git -C $phaseWorktree merge --no-ff --no-edit $childReviewedHead
if ($LASTEXITCODE -ne 0) {
  git -C $phaseWorktree merge --abort 2>$null
  throw "$childLabel merge conflict; move that child back to blocked before retrying."
}
$childMergeHead = git -C $phaseWorktree rev-parse HEAD
git -C $phaseWorktree push origin HEAD:feat/sympp-pilot-mini-phase
if ($LASTEXITCODE -ne 0) {
  git -C $phaseWorktree fetch origin feat/sympp-pilot-mini-phase:refs/remotes/origin/feat/sympp-pilot-mini-phase
  if ($LASTEXITCODE -eq 0) {
    $remoteAfterFailedPush = git -C $phaseWorktree rev-parse origin/feat/sympp-pilot-mini-phase
    if ($remoteAfterFailedPush -eq $childMergeHead) {
      Write-Host "Phase parent push returned non-zero, but remote branch contains the integrated head; continue to merge_child_into_phase."
    } else {
      git -C $phaseWorktree reset --hard $preIntegrationHead
      throw "Phase parent push failed and remote did not advance; parent branch reset; move $childLabel back to blocked before retrying."
    }
  } else {
    git -C $phaseWorktree reset --hard $preIntegrationHead
    throw "Phase parent push failed and remote state could not be verified; parent branch reset; do not block $childLabel until remote state is manually reconciled."
  }
}
```

   If either merge conflicts or the phase parent push fails, stop the
   mini-phase, record the blocker, and do not call `merge_child_into_phase`
   until the integration is resolved and the phase parent branch is pushed. If
   the command resets the phase parent branch back to the pre-integration head
   before throwing so the child is not half-recorded. If the remote already
   contains `$childMergeHead`, do not block the child; continue to
   `merge_child_into_phase` with that integrated head. Use the child worker
   session that owns the affected child for merge-conflict or proven
   no-remote-advance recovery.
   Symphony++ allows the child worker to move its own phase child from
   `merging_into_phase` back to `blocked` for merge-blocker recovery, even
   though other `merging_into_phase` transitions are architect-controlled. Move
   every affected child still in `merging_into_phase` back to `blocked` only
   after the remote phase branch is known not to contain the integrated head:

```json
{
  "expected_status": "merging_into_phase",
  "status": "blocked",
  "reason": "Phase parent branch merge or push failed; parent branch integration must be resolved before merge_child_into_phase."
}
```

13. After the parent branch contains the child changes, call
    `merge_child_into_phase` for each child so Symphony++ records the local
    phase merge artifact against the integrated parent head. In the sequential
    pilot path, call this after each child integration, then continue to the
    next child. Use a commit-specific URL as `uri`, and use `$childMergeHead`
    from the integration command:

```json
{
  "work_package_id": "<child-work-package-id>",
  "merge_artifact": {
    "status": "merged_into_phase",
    "uri": "https://github.com/<owner>/<kraken-repo>/commit/<child-merge-head-sha>",
    "summary": "Merged <child-work-package-id> into the non-production phase parent branch.",
    "commit_sha": "<child-merge-head-sha>"
  }
}
```

14. Close the investigation anchor package with the owner-held anchor worker
    grant. This parent lane records coordination findings only; it must not be
    used for child implementation. Reuse the anchor worker MCP session claimed
    before child creation. If that pre-claimed anchor worker session and
    lifecycle evidence are missing, stop and mark the mini-phase blocked or
    restart from the pre-child-creation anchor lifecycle step; do not continue
    to `mark_ready` from a late claim. Then record:

```text
append_finding(
  title: "Kraken mini-phase pilot integration summary",
  body: "Both child packages reached ready_for_architect_merge, were integrated into the non-production phase parent branch, and have merge_child_into_phase artifacts.",
  idempotency_key: "kraken-pilot-mini-phase-integration-summary"
)
```

Then record the investigation recommendation artifact:

```text
request_scope_expansion(
  summary: "Kraken pilot recommendation",
  idempotency_key: "kraken-pilot-mini-phase-recommendation",
  body: "Mini-phase pilot complete. Do not migrate the active Kraken rewrite until the human pilot report accepts the quick-fix, hotfix, and mini-phase metrics."
)
```

Then call `read_task_plan`, use the refreshed task-plan version, and complete
the two explicit anchor plan nodes before readiness:

```text
update_task_plan(
  patch: {
    "nodes": [
      {"id": "anchor-coordinate", "status": "done"},
      {"id": "anchor-recommendation", "status": "done"}
    ]
  },
  expected_version: <current_task_plan_version_from_read_task_plan>
)
```

Then move the anchor package from `implementing` to `ci_waiting` through normal
lifecycle transitions and call `mark_ready`. The expected terminal state for
the anchor is `ready_for_human_merge`; no production merge or active rewrite
migration is authorized by that state.

```json
{
  "expected_status": "implementing",
  "status": "reviewing",
  "reason": "Mini-phase child integration and parent recommendation evidence are complete."
}
```

```json
{
  "expected_status": "reviewing",
  "status": "ci_waiting",
  "reason": "Anchor evidence is complete and ready for human pilot review."
}
```

## Operator Prompts

Use this worker prompt for `KRAKEN-PILOT-QF-001`:

```text
You are assigned KRAKEN-PILOT-QF-001, a Symphony++ pilot quick-fix package for Kraken.

Goal: complete one low-risk Kraken quick fix without touching active rewrite/rework branches.

Repo/worktree: C:\Code\nextide-saas-vod-kraken-sympp-pilot-qf
Checkout ref: origin/<approved-pilot-base-branch>
WorkPackage / PR base: <approved-pilot-base-branch>
Branch: feat/sympp-pilot-qf-doc-or-log-hygiene

Constraints:
- Use `main` for `<approved-pilot-base-branch>` unless the operator recorded
  the pilot-wide `dev` override before creating any pilot package.
- Do not use feat/kraken-rework-* or feat/kraken-rewrite-* branches.
- Do not create live GitHub/Linear/provider state unless the operator explicitly approves.
- Keep the diff inside the package allow-list: docs, runbooks, scripts, or test files.
- Keep planning/progress/findings in Symphony++ virtual files.
- Do not commit raw secrets or environment values.

Before editing:
1. Claim the worker grant: `claim_work_key(secret: <quick-fix-worker-secret>, claimed_by: "kraken-pilot-qf-worker")`.
2. Confirm `get_current_assignment()` shows `work_package_id=KRAKEN-PILOT-QF-001`.
3. Call `set_status(expected_status: "ready_for_worker", status: "claimed", reason: "Quick-fix worker key claimed.")`.
4. Call `set_status(expected_status: "claimed", status: "planning", reason: "Quick-fix candidate and validation plan are being confirmed.")`.
5. Call `read_task_plan`, then append worker-owned plan nodes with explicit IDs: `update_task_plan(patch: {"nodes": [{"id": "qf-candidate", "title": "Confirm quick-fix candidate", "body": "Record the selected low-risk candidate, base branch, and scope rationale.", "status": "pending"}, {"id": "qf-review", "title": "Complete quick-fix validation and review", "body": "Attach current-head branch, validation, and review evidence before mark_ready.", "status": "pending"}]}, expected_version: <current_task_plan_version_from_read_task_plan>)`.
6. Confirm the repo branch and base.
7. Record the exact candidate selected and why it satisfies quick-fix criteria.
8. Stop if the candidate touches runtime queue semantics, provider credentials, migrations, or active rewrite work.
9. Call `set_status(expected_status: "planning", status: "implementing", reason: "Quick-fix implementation is starting from the recorded plan.")`.

Before ready:
1. Run focused local validation.
2. Attach branch metadata for the current head.
3. Record focused validation evidence after the branch attachment with status `tests_passed`.
4. Record review_t1 evidence after the branch attachment with status `review_t1_green`.
5. Run the quick-fix changed-file scope check from the playbook and block instead of readying if any path is outside scope.
6. Call `read_task_plan`, then complete the worker-owned plan nodes with `update_task_plan(patch: {"nodes": [{"id": "qf-candidate", "status": "done"}, {"id": "qf-review", "status": "done"}]}, expected_version: <current_task_plan_version_from_read_task_plan>)`.
7. Call `set_status(expected_status: "implementing", status: "reviewing", reason: "Quick-fix implementation is complete; collecting validation and review evidence.")`.
8. Call `set_status(expected_status: "reviewing", status: "ci_waiting", reason: "Quick-fix evidence is current.")`.
9. Mark ready only after evidence is current, plan nodes are complete, and the package is in `ci_waiting`.

Final output: changed files, validation commands, review evidence, and remaining risk.
```

Use this worker prompt for `KRAKEN-PILOT-HF-001`:

```text
You are assigned KRAKEN-PILOT-HF-001, a Symphony++ pilot hotfix package for Kraken.

Goal: fix one current-code, hotfix-like defect on the approved Kraken pilot base with a narrow PR.

Repo/worktree: C:\Code\nextide-saas-vod-kraken-sympp-pilot-hf
Checkout ref: origin/<approved-pilot-base-branch>
WorkPackage / PR base: <approved-pilot-base-branch>
Branch: fix/sympp-pilot-synthetic-smoke-hygiene

Constraints:
- Use `main` for `<approved-pilot-base-branch>` unless the operator recorded
  the pilot-wide `dev` override before creating any pilot package.
- Reproduce or prove the defect on the approved current base before fixing.
- Do not use active rewrite/rework branches.
- Add the focused regression at the owning test layer.
- Human merge only. Do not auto-merge.
- Do not run live credentialed validation unless explicitly approved.

Required evidence:
- `claim_work_key(secret: <hotfix-worker-secret>, claimed_by: "kraken-pilot-hotfix-worker")` succeeds before any assignment-scoped MCP call.
- `get_current_assignment()` shows `work_package_id=KRAKEN-PILOT-HF-001`.
- `set_status(expected_status: "ready_for_worker", status: "claimed", reason: "Hotfix worker key claimed.")` recorded immediately after assignment verification.
- `set_status(expected_status: "claimed", status: "planning", reason: "Hotfix candidate and validation plan are being confirmed.")` recorded before implementation.
- Worker-owned plan nodes appended with explicit IDs before implementation: `update_task_plan(patch: {"nodes": [{"id": "hf-reproduce", "title": "Reproduce or prove hotfix candidate", "body": "Record the current-code defect proof and focused regression plan.", "status": "pending"}, {"id": "hf-review", "title": "Complete hotfix validation and review", "body": "Attach current-head branch, PR, validation, and review evidence before mark_ready.", "status": "pending"}]}, expected_version: <current_task_plan_version_from_read_task_plan>)`.
- `set_status(expected_status: "planning", status: "implementing", reason: "Hotfix implementation is starting from the recorded plan.")` recorded before edits.
- Candidate selection note.
- Focused regression before/after or equivalent current-code proof.
- Touched-file ruff/pytest at minimum.
- PR URL.
- `attach_branch` recorded with branch `fix/sympp-pilot-synthetic-smoke-hygiene` and the current head SHA.
- `attach_pr` recorded with the PR URL and the same current head SHA.
- `sync_pr` recorded with the PR URL, the same current head SHA, and metadata
  showing the PR base is `<approved-pilot-base-branch>` plus current semantic
  PR state for that head, such as `check_summary.conclusion=success`,
  `review_state.state=approved`, and `merge_state.state=clean`.
- review_t1 and review_t2 evidence.
- Current-head review package attached before ready:
  `submit_review_package(summary: "Hotfix validation and reviews are green for the current head.", tests: ["<hotfix-focused-regression-command>", "uv run ruff format --check <touched-files>", "uv run ruff check <touched-files>", "uv run pytest <focused-test-selector>"], artifacts: ["<review_t1-artifact>", "<review_t2-artifact>", "<pr-url-or-ci-log>"], head_sha: "<hotfix-head-sha>", acceptance_criteria_met: true, reviews: [{"lane": "review_t1", "verdict": "green"}, {"lane": "review_t2", "verdict": "green"}])`.
- Hotfix changed-file scope check passed from the playbook.
- `read_task_plan` used to refresh the task-plan version.
- Worker-owned plan nodes completed with `update_task_plan(patch: {"nodes": [{"id": "hf-reproduce", "status": "done"}, {"id": "hf-review", "status": "done"}]}, expected_version: <current_task_plan_version_from_read_task_plan>)`.
- `set_status(expected_status: "implementing", status: "reviewing", reason: "Hotfix implementation is complete; collecting validation and review evidence.")` recorded before CI waiting.
- `set_status(expected_status: "reviewing", status: "ci_waiting", reason: "Hotfix evidence is current.")` recorded before `mark_ready`.

Final output: PR URL, head SHA, changed files, tests, review evidence, and rollback note.
```

Use this architect prompt for `KRAKEN-PILOT-MP-001`:

```text
You are assigned KRAKEN-PILOT-MP-001, the Symphony++ Kraken mini-phase pilot.

Goal: coordinate exactly two child packages, then stop. This is not the active Kraken rewrite migration.

Parent branch: feat/sympp-pilot-mini-phase
Child A branch: feat/sympp-pilot-mini-doc-boundary
Child B branch: feat/sympp-pilot-mini-focused-regression

Before architect actions:
- Claim the architect grant: `claim_work_key(secret: <architect_work_key_secret>, claimed_by: "kraken-pilot-architect")`.
- Confirm `get_current_assignment()` shows `grant_role=architect`, `phase_id=KRAKEN-PILOT-MP-001`, and `work_package_id=KRAKEN-PILOT-MP-001-ANCHOR`.

Constraints:
- Create exactly two children.
- Keep child write scopes disjoint.
- Do not create or migrate feat/kraken-rework-* or feat/kraken-rewrite-* work.
- Do not approve automated production merge.
- Require child validation and review evidence before integrating into the parent branch.
- Use stack synthetic validation only when needed and only from nextide-saas-vod-stack.

Stop conditions:
- A child needs production credentials or live provider calls.
- A reviewer asks to broaden into the active rewrite.
- A child cannot prove current-code behavior.
- Child write scopes overlap.

Final output: child package summary, parent branch head, child PRs, validation matrix, dashboard observations, and rollback readiness.
```

## Dashboard Expectations

During the pilot, standalone packages should move through these states:

```text
ready_for_worker -> claimed -> planning -> implementing -> reviewing -> ci_waiting -> ready_for_human_merge
```

Phase-child packages should move through architect readiness instead:

```text
ready_for_worker -> claimed -> planning -> implementing -> reviewing -> ci_waiting -> ready_for_architect_merge -> merging_into_phase -> merged_into_phase
```

Expected details:

- WorkPackage ID, kind, repo, base branch, and branch are visible.
- Active worker run is visible after claim.
- Virtual task plan, findings, and progress render without requiring local scratch files.
- Branch and PR metadata are attached for hotfix and phase-child work.
- Review-suite status stays distinct from GitHub and human readiness.
- Human merge remains a separate readiness indicator.
- Any blocker appears with reason and resolution history.

The pilot is not green if the dashboard collapses agent, review, GitHub, architect, and human readiness into one undifferentiated boolean.

## Validation Matrix

Minimum evidence by package:

| Package | Required validation |
|---|---|
| `KRAKEN-PILOT-QF-001` | Focused docs/path/test command relevant to the diff, plus `review_t1` green |
| `KRAKEN-PILOT-HF-001` | Focused regression, touched-file `uv run ruff format --check`, touched-file `uv run ruff check`, touched-file `uv run pytest`, PR, `sync_pr`, `review_t1`, `review_t2` |
| `KRAKEN-PILOT-MP-001A` | Child-specific focused validation, `sync_pr`, `review_t1`, `review_t2`, `ready_for_architect_merge`, and architect-recorded manual branch/PR/head/scope checklist |
| `KRAKEN-PILOT-MP-001B` | Child-specific focused validation, `sync_pr`, `review_t1`, `review_t2`, `ready_for_architect_merge`, and architect-recorded manual branch/PR/head/scope checklist |
| `KRAKEN-PILOT-MP-001-ANCHOR` in phase `KRAKEN-PILOT-MP-001` | Parent integration summary, child evidence links, and no unresolved blockers |

Optional stack validation, only when relevant:

```powershell
cd C:\Code\nextide-saas-vod-stack
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-vod-validation.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-synthetic-stack-e2e.ps1 -ResetStack -DispatchMode rush -MaxSegments 5
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-synthetic-stack-e2e.ps1 -ResetStack -DispatchMode batch
```

Run live strict only with explicit human approval:

```powershell
cd C:\Code\nextide-saas-vod-stack
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-live-stack-e2e.ps1 -WaitForWorkflow -StrictAudit
```

## Success Metrics

The pilot succeeds only if all are true:

- Three pilot shapes complete: quick fix, hotfix-like PR, and two-child mini-phase.
- Zero pilot packages touch active rewrite/rework branches.
- Zero automated production merges occur.
- 100 percent of pilot package branch names and base branches match this playbook or an explicitly recorded operator override.
- 100 percent of hotfix and phase-child PRs have current-head branch/PR metadata and review evidence.
- 100 percent of phase-child approvals include dashboard/runbook artifacts for
  the manual architect checks: branch exists, PR targets the phase parent, PR
  head matches branch/review evidence, and changed files stay inside the child
  intended globs.
- 100 percent of packages have current virtual task plan, findings, and progress visible in the dashboard.
- Quick-fix cycle time from claim to ready is recorded.
- Hotfix cycle time from claim to ready is recorded.
- Mini-phase parent cycle time and child wait time are recorded.
- All blockers are resolved or explicitly abandoned with reason.
- A human can identify rollback commands and package state from the runbook and dashboard without reading agent transcripts.

Residual future automation: automatic phase-child changed-file, PR metadata,
and current-head review package gates are not currently enforced by policy.
Treat the manual architect approval checklist as pilot evidence only, not as a
product-complete P7 enforcement feature.

## Rollback Plan

Package rollback:

1. Record the rollback blocker in dashboard/progress. If the package is still
   active, move it to `blocked` through the worker MCP session, dashboard/API,
   or approved operator admin path before cleanup; if the pilot should stop
   permanently, mark it `abandoned` with the reason after evidence is preserved.
2. Revoke every live grant created for the pilot package or phase through the
   dashboard/API or an approved operator admin path: standalone worker grants,
   the mini-phase anchor worker grant, the mini-phase architect grant, and both
   child worker grants. If the current deployment exposes no executable
   revocation control for one of these grant types, record the live grant ID as
   residual access risk and do not call rollback complete until the grant
   expires or an operator revokes it through an approved admin path.
3. Reassign with a new grant only if the issue is worker-local and the package
   remains in scope.
4. Preserve branch, PR, review, grant-revocation, and progress evidence.

Branch rollback:

Main-owner worktree:

```powershell
cd C:\Code\nextide-saas-vod-kraken
git fetch origin --prune
$pilotBaseBranch = "main" # Replace with "dev" only after recording the operator-approved dev override.
git switch $pilotBaseBranch
git worktree list
# For any listed disposable worktree still on <pilot-branch>, first preserve
# needed evidence, then force-remove it so branch deletion is not blocked by a
# dirty pilot worktree.
git worktree remove --force <pilot-worktree>
git branch -D <pilot-branch>
```

Non-owner worktree:

```powershell
cd <pilot-worktree>
git fetch origin --prune
$pilotBaseBranch = "main" # Replace with "dev" only after recording the operator-approved dev override.
git switch --detach "origin/${pilotBaseBranch}"
git branch -D <pilot-branch>
```

Use the owner worktree for any local approved-base checkout. In non-owner
worktrees, detach at `origin/<approved-pilot-base-branch>` or switch to another
safe non-pilot branch before deleting the local pilot branch. If the non-owner
worktree is dirty and the rollback decision is to discard it, preserve the
required evidence first and then run this from the owner checkout before local
branch deletion:

```powershell
git -C C:\Code\nextide-saas-vod-kraken worktree remove --force <pilot-worktree>
```

PR rollback:

1. Close the PR without merge.
2. Comment with package ID, reason, and validation state.
3. Delete the remote feature branch only after the operator confirms no evidence still needs to be inspected.

Remote branch deletion:

```powershell
cd C:\Code\nextide-saas-vod-kraken
git fetch origin --prune
git ls-remote --exit-code --heads origin <pilot-branch>
git push origin --delete <pilot-branch>
```

Run remote deletion only after PR rollback is recorded and all pilot worktrees
using the branch have been closed, removed, or detached.

Runtime rollback:

1. If synthetic stack state was created and the wrapper did not already clean
   it up, use the runner's emitted compose project and compose-file arguments
   for teardown. Do not use the default project name against an isolated
   synthetic run:

```powershell
cd C:\Code\nextide-saas-vod-stack
docker compose <runner-emitted-compose-args> down -v --remove-orphans
```

When the runner was not kept up, prefer rerunning the same wrapper without
`-KeepStackUp` or using the cleanup command printed by the runner log.

2. If manual local stack rows remain, reset local stack state:

```powershell
cd C:\Code\nextide-saas-vod-stack
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/reset-local-stack-state.ps1 -StartAfter
```

3. Do not delete production or shared remote data as part of this pilot.

Symphony++ rollback:

1. Keep the pilot ledger snapshot.
2. Export package timeline and review artifacts.
3. Record the failed success metric.
4. Stop before creating new Kraken packages until the operator decides whether to adjust the playbook or abandon the pilot.

## Completion Report

At the end of the pilot, produce this summary:

```text
Pilot result: pass|fail|abandoned
Ledger: <pilot-ledger>
Packages completed: <ids>
Branches: <branch -> head SHA>
PRs: <url list>
Review evidence: <T1/T2/GitHub refs>
Dashboard gaps: <none or list>
Validation commands: <commands and results>
Rollback tested: yes|no
Remaining risks: <none or list>
Decision: do|do not migrate the next Kraken rewrite slice into Symphony++
```
