# Hotfix Runbook

Use this for standalone hotfix packages that need a bounded PR and current
review evidence. For role context, start with
`../docs/12_OPERATOR_TRAINING.md`.

## Create The Package

1. From the repository root, create scratch space if needed:
   `New-Item -ItemType Directory -Force scratch`.
2. Copy `implementation_docs_symphplusplus/templates/create_work_package.hotfix.example.yaml` to an edited
   request file such as `scratch/hotfix-request.yaml`.
3. Edit repo, base branch, branch pattern, owned paths, acceptance criteria,
   test plan, review-suite requirement, and stop conditions.
4. From `elixir/`, create the package:

```powershell
Set-Location elixir
mise exec -- mix sympp.create_work --file ../scratch/hotfix-request.yaml --claimed-by <stable-worker-id>
```

5. Confirm command output returns only non-secret handoff metadata. It must not
   print raw claim secrets, bearer tokens, or secret-bearing URLs.

## Dispatch The Worker

Send the worker:

- WorkPackage id, base branch, target branch convention, and PR title format.
- Private handoff target and stable `claimed_by` identity.
- Package scope, owned files, acceptance criteria, and stop conditions.
- Validation target and required review lanes.
- Reminder to use the `symphony-plus-plus` plugin or repo-local skill with MCP
  private-store bootstrap.

Do not send the raw secret in chat, prompts, command lines, files, PR bodies,
review text, or durable logs.

## Review And Merge

1. Watch claim, plan, findings, progress, blockers, branch, PR, tests, and
   review evidence in Symphony++ state.
2. Require the worker to attach PR URL and current head SHA before readiness.
3. Confirm review evidence applies to the current PR head.
4. Check changed files against the package scope.
5. Use `../review/REVIEWER_CHECKLIST.md` and
   `../docs/11_RELEASE_VALIDATION.md` before merge.
6. Record skipped validation as blocked with exact blocker and owner.
7. Human merge only after branch protection and hotfix gates pass.

## Quick Fix

For a quick fix, use the quick-fix template instead:

```powershell
New-Item -ItemType Directory -Force scratch
Copy-Item implementation_docs_symphplusplus/templates/create_work_package.quick_fix.example.yaml scratch/quick-fix-request.yaml
# Edit scratch/quick-fix-request.yaml before running create-work.
Set-Location elixir
mise exec -- mix sympp.create_work --file ../scratch/quick-fix-request.yaml --claimed-by <stable-worker-id>
```

Quick-fix packages still need truthful acceptance and review evidence, but may
use their package policy instead of hotfix-specific gates.

## Investigation

For an investigation, use the investigation template:

```powershell
New-Item -ItemType Directory -Force scratch
Copy-Item implementation_docs_symphplusplus/templates/create_work_package.investigation.example.yaml scratch/investigation-request.yaml
# Edit scratch/investigation-request.yaml before running create-work.
Set-Location elixir
mise exec -- mix sympp.create_work --file ../scratch/investigation-request.yaml --claimed-by <stable-worker-id>
```

The investigation policy does not require a PR unless the package says so. It
requires findings plus the canonical `recommendation.md` artifact recorded
through `request_scope_expansion`; stored legacy recommendation events do not
satisfy readiness unless that canonical artifact already exists.
