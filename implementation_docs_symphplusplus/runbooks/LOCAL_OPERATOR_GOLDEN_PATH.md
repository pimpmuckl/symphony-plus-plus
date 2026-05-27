# Local Operator Golden Path

Use this when a human wants to start using Symphony++ locally today: open the
cockpit, capture a WorkRequest, hand it to an architect, dispatch approved
slices, and track workers through review and merge evidence.

This is a current-behavior runbook. The cockpit and MCP tools do not spawn
Codex agents for you, generate product questions automatically, slice work
automatically, or create Linear state.

## Before You Start

For a first local checkout, do the setup once:

- Follow `../../elixir/README.md` for Elixir runtime prerequisites before
  running `mix sympp.cockpit`.
- Follow `../../plugins/symphony-plus-plus/README.md` to install and enable the
  default `symphony-plus-plus` Codex plugin for MCP-free planning skills.
- For WorkRequest architect or WorkPackage worker sessions, also make the
  opt-in `symphony-plus-plus-mcp` plugin/config available in that dedicated
  MCP-enabled session before launch. Do not rely on the default plugin alone
  for the `symphony-plus-plus-mcp:*` skills, and do not enable the MCP plugin
  for generic review or unrelated Codex sessions.

During V2.1 feature-branch work, do not refresh or sync the installed
user-local plugin cache. Keep repo skill/docs changes in source control and
adopt them locally only at final feature-branch cutover. After that cutover,
reload Codex and start a new session; existing sessions may keep the old skill
and MCP registration list.

If the default Symphony++ skill is visible but the `symphony_plus_plus` MCP
tools are missing, run the activation doctor from the repository root:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

The normal repair for `solo_ready_mcp_companion_not_enabled` is to enable
the companion only in the dedicated S++ MCP config/Codex home:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
```

The enable command validates the installed companion cache and manifest, writes
only `[plugins."symphony-plus-plus-mcp@symphony-plus-plus"] enabled = true`, and keeps
a timestamped `config.toml.sympp-backup-*` before changing an existing config.
It refuses the default `~/.codex` home. Then restart or reload that dedicated
session. Do not add the MCP companion to generic worker, `worker_smart`,
review-suite, or `codex review` configs.
The doctor checks cache, config, and the local HTTP daemon; it cannot inspect
the tool list already registered inside an open Codex model session. Treat
session restart/reload as part of the repair after enablement or cache changes.
Verify the daemon against the checkout before blaming Codex plugin visibility:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

`stale_or_unverified_daemon` or `stale_daemon_source_revision_mismatch` means
the cockpit HTTP daemon is not proving it is the current checkout; restart
`mix sympp.cockpit` from this checkout and rerun the smoke.
The Codex app MCP settings list may show only explicitly configured MCP servers
and may not list plugin-scoped MCP servers from an enabled opt-in plugin. Use
the doctor plus `smoke-sympp-mcp-http.ps1` as the repeatable proof, then verify
tool availability in a newly started dedicated MCP-enabled session.

For normal operator use, omit `--database`. Cockpit, MCP, Solo Session,
create-work, and planned-slice dispatch all use the same durable local ledger.
The preferred home is `$HOME/.agents/splusplus/symphony_plus_plus.sqlite3` on
POSIX-style shells and
`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows; if
home is unavailable, Symphony++ falls back under a temp/relative
`.agents/splusplus` root. Use `--database` or `SYMPP_DATABASE` only for
isolated tests, manual experiments, or demo ledgers. Pre-production ledgers
under the earlier `~/.symphony_plus_plus` default are not auto-migrated; pass
that path with `--database` only when you need to inspect old dogfood state.
`sympp.health` reports this distinction under `ledger.identity`: normal omitted
configuration uses `source: "default"`, explicit SQLite overrides use
`source: "explicit"`, and default-home ledgers set `default_home: true` with a
safe display path.

## Optional Demo Ledger

For cockpit exploration, screenshots, or visual QA, create a deterministic
synthetic ledger instead of relying on an untracked local database artifact:

```powershell
Set-Location elixir
$demoLedger = "C:\path\to\sympp-demo.sqlite3"
mix sympp.demo_ledger --database $demoLedger
```

The task creates and migrates the SQLite ledger, then seeds non-secret demo
WorkRequests, planned slices, WorkPackages with planning evidence and a blocker,
structured WorkRequest and package-guidance decision prompts, and Solo Sessions
with representative entries. It fails if the target database already exists.
Use a demo-only path; do not point `--force` at a ledger that contains real
local operator state. To intentionally replace a local demo ledger, pass
`--force`:

```powershell
mix sympp.demo_ledger --database $demoLedger --force
```

Start the cockpit with the same `$demoLedger` path printed by the generator.

## Start The Cockpit

From the repository root, start the local operator cockpit:

```powershell
Set-Location elixir
mix sympp.cockpit
```

The task binds to `127.0.0.1:4057` by default, prints
`http://127.0.0.1:4057/sympp/board`, serves MCP at
`http://127.0.0.1:4057/mcp`, and runs until interrupted. Open the printed URL
in your browser. Use `--port 0` only when you intentionally want a dynamic port
for manual testing.

In a second shell from the repository root, prove the local HTTP MCP daemon
before troubleshooting Codex app plugin visibility:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1
```

The smoke sends `initialize`, normalizes the returned `Mcp-Session-Id` to a
single header value, follows with `tools/list`, and verifies the script's
current generic unbound expectations: `sympp.health`, the `solo_*` tools,
`claim_work_key`, and statically discoverable architect schemas such as
`read_work_request` and `list_guidance_requests`. `claim_private_handoff` is
part of the generic unbound refresh surface, and `claim_local_assignment` is
part of the trusted local HTTP refresh surface, but the current smoke script
does not yet assert them directly. Worker-only mutation tools remain absent
until claim. The health smoke also verifies that
`ledger.identity` is present and complete enough to identify default or
explicit SQLite ledgers without exposing credential-bearing configuration. For a
non-default or dynamic cockpit port, pass the printed MCP URL:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -Url http://127.0.0.1:<port>/mcp
.\scripts\smoke-sympp-mcp-http.ps1 -Json
```

A passing smoke proves the cockpit/MCP daemon is serving the HTTP MCP contract.
It does not prove that an already-open Codex app session loaded or enabled the
opt-in `symphony-plus-plus-mcp` plugin; reload/start that dedicated session
after fixing plugin config or cache state. Focused `claim_local_assignment`
contract coverage currently lives in
`elixir/test/symphony_elixir/symphony_plus_plus/codex_skill_package_test.exs`;
the generic daemon smoke is not first-claim validation until a dedicated
trusted local HTTP claim smoke lands.

For legacy/recovery validation of a package whose private handoff has already
placed a work key in a local secret store, read that secret into a short-lived
environment variable inside your shell and run the bound smoke by variable
name:

```powershell
$env:SYMPP_WORK_KEY_SECRET = Get-Content -LiteralPath "<private-secret-file>" -Raw
.\scripts\smoke-sympp-mcp-http.ps1 `
  -Bound `
  -WorkKeySecretEnv SYMPP_WORK_KEY_SECRET `
  -ClaimedBy <stable-worker-id>
Remove-Item Env:\SYMPP_WORK_KEY_SECRET -ErrorAction SilentlyContinue
```

The bound smoke covers the legacy secret-proof path. Normal V2.1 workers claim
with `claim_local_assignment` instead of `claim_work_key`.

After a WorkPackage worker claims with `claim_local_assignment`, the same local
HTTP `Mcp-Session-Id` remains bound for scoped follow-up tools and resources.
Treat claimed-session ids as sensitive local continuity material:
do not paste, log, or commit them. If the grant is revoked, expired, or no
longer matches the live ledger scope, protected MCP calls fail closed instead
of continuing from cached state.

## Create A WorkRequest

Use a WorkRequest when the human goal still needs clarification, decisions, or
slice planning before workers start.

1. Open `/sympp/work-requests`.
2. Choose `New WorkRequest`.
3. Enter the project or repo and the target base branch.
4. Pick the work type: `feature`, `bugfix`, `hotfix`, `refactor`,
   `investigation`, `docs`, or `review`.
5. Pick the desired dispatch shape:
   `single_package`, `architect_led_feature_branch`, `direct_main_fix`,
   `investigation_first`, or `review_only`.
6. Add the human description and constraints:
   allowed paths, forbidden paths, compatibility stance, validation
   expectations, dependencies or notes, and stop conditions.
7. Use Advanced JSON only for uncommon constraint keys or complex shapes.
8. Create the request, then mark the draft ready for clarification.

Do not assume backward compatibility. If the product docs or the human request
do not state the compatibility stance, make it a clarification item before
slicing.

## Hand It To An Architect

For WorkRequests in `ready_for_clarification`, `clarifying`,
`human_info_needed`, `ready_for_slicing`, or `sliced`, use the WorkRequest
detail page to prepare the architect handoff.

The handoff creates or reuses the WorkRequest-scoped phase and architect anchor
package, mints an unclaimed architect grant, and stores the secret through
private handoff. The browser shows non-secret grant metadata, redacted private
handoff metadata, and a safe prompt for the architect skill. It must not show
raw work-key secrets, secret hashes, or full secret-retrieval commands.

Start a Codex architect agent in an opt-in Symphony++ MCP-enabled session and
tell it to use:

```text
symphony-plus-plus-mcp:symphony-architect
```

Also provide the redacted architect handoff/bootstrap metadata emitted by the
handoff panel so the architect's Symphony++ MCP session can connect to the
scoped WorkRequest and phase. Pass or reference only the non-secret metadata
and private-store command/config path; never paste raw work keys, secrets,
secret hashes, or full secret-retrieval commands into prompts, docs, or logs.

The architect reads the WorkRequest through scoped MCP tools, asks and records
product questions, records decisions and assumptions, authors planned slices,
approves slices that are ready, and dispatches only approved slices. If the
architect starts without a bound/scoped MCP session and cannot
`read_work_request`, it must stop and report the setup blocker instead of
inventing request state. If MCP is unavailable, the architect records the
blocker and falls back only to the dashboard or an operator-approved artifact.

## Dispatch Workers

Approved planned slices become WorkPackages only when someone explicitly
dispatches them. Dispatch is available through the local-operator dashboard,
the planned-slice dispatch CLI, or a phase-scoped architect MCP session with
dispatch capability.

Dashboard dispatch creates a WorkPackage, worker grant, and non-secret
`worker_bootstrap` payload for the ledger-backed local claim path. It records
the stable worker identity `local-operator-worker` and shows only
WorkPackage/linkage and claim metadata. It does not spawn Codex agents, prepare
worktrees, record worktree scope, or call Linear.

Before launching a worker, prepare and record the package worktree through
`prepare_work_package_worktree` or the equivalent operator worktree flow. Keep
the exact `branch` and `worktree_path` values from that step, and pair them
with the stable local MCP `caller_id` for the worker session/launcher. The
prepare tool does not return `caller_id`; reuse the same caller id for
reconnects because changing it for the same local owner is rejected before the
live-grant authority check. If no worktree is recorded, do not launch the
worker; the ledger-backed claim must fail closed with `worktree_scope_required`.

Give each worker:

- The WorkPackage id, target branch, base branch, owned paths, acceptance
  criteria, required validation, review profiles, and stop conditions.
- The non-secret ledger claim metadata for `claim_local_assignment`, including
  repo/base/work_package_id/work_request_id when present.
- The prepared worker `branch` and `worktree_path`, plus the stable local MCP
  `caller_id` used for claim/reclaim.
- The stable `claimed_by` identity for that package.
- The instruction to use `symphony-plus-plus:symphony-worker` plus
  `symphony-plus-plus-mcp:symphony-work-package`.
- The explicit requirement to launch the worker in an opt-in Symphony++
  MCP-enabled session before using that skill.
- The instruction to ask the architect first for product, architecture,
  dependency, or slice-boundary ambiguity.

Workers claim through `claim_local_assignment` first, then update MCP-backed
planning instead of local markdown planning files. They read the current
assignment, update task plan/findings/progress through MCP, attach branch and
PR evidence, run validation and review, and mark ready only after package gates
pass. Replaying the same claim heartbeats the lease; stale leases can be
reclaimed with audit evidence, while paused leases, same local owner claims that
change `caller_id`, or active other owners are operator/architect blockers.

## Track And Merge

Use the cockpit to watch WorkRequests, WorkPackages, blockers, progress,
branch/PR state, validation, and review evidence.

When a worker raises guidance:

- Ordinary open guidance is architect-owned.
- `human_info_needed` means the architect escalated an item that needs human
  input. Answer it from the local cockpit; the answer records
  `local-operator` attribution and resolves the matching readiness blocker.
- If the architect provided a structured decision prompt, pick one option or
  use the freeform redirect path. The saved answer uses the selected option's
  durable answer text plus any note you add.

Merge only after the PR and WorkPackage evidence are current for the final
head:

- Acceptance criteria are satisfied or explicitly blocked with owner.
- Validation commands and results are recorded.
- Required review-suite lanes are complete.
- PR URL and current head SHA are attached.
- Changed files match package scope.
- Branch protection and human review requirements pass.

Symphony++ readiness is not a permission bypass. It records package evidence;
GitHub branch protection and human merge control still decide the actual merge.

## Solo Session Alternative

Use Solo Session mode for ordinary single-agent work that needs durable local
planning but does not need WorkRequests, WorkPackages, architect handoff,
worker dispatch, Linear state, or merge-readiness gates.

Use the plugin skill:

```text
symphony-plus-plus:symphony-solo-session
```

Or run the CLI directly from `elixir/`:

```powershell
mix sympp.solo attach `
  --repo <repo> `
  --base-branch <branch> `
  --workspace-path <absolute-workspace-path> `
  --caller-id <stable-local-caller-id> `
  --title "<short task title>"
```

Append `task_plan`, `finding`, `progress`, `blocker`, `decision`, and
`validation_note` entries as the work changes. Treat the Solo Session ledger as
the durable planning replacement for ad hoc local `task_plan.md`,
`findings.md`, and `progress.md` files in normal single-agent lanes.

Solo Session mode does not slice work, dispatch workers, mint grants, create
PRs, create WorkRequests, create WorkPackages, or write Linear state.

## Which Skill Do I Use?

| Situation | Skill |
| --- | --- |
| WorkRequest-led planning, clarification, decisions, slicing, dispatch, or package guidance routing | `symphony-plus-plus-mcp:symphony-architect` |
| One assigned WorkPackage with MCP-backed planning and readiness evidence | `symphony-plus-plus:symphony-worker` plus `symphony-plus-plus-mcp:symphony-work-package` |
| One normal local agent session that only needs durable planning memory | `symphony-plus-plus:symphony-solo-session` |

## Legacy Handoff Defaults

Private-file or Credential Manager handoff remains available for
explicit legacy/recovery. It is not the normal V2.1 worker dispatch path after
ledger-backed `claim_local_assignment`.

Explicit `windows-credential-manager` mode remains available when the operator
selects it and the host Credential Manager can write credentials. It is not the
default local dogfood path and may fail on hosts where WCM is unavailable.

## What Not To Do

- Do not paste raw work keys, worker secrets, bearer tokens, GitHub tokens,
  Linear tokens, MCP auth tokens, secret hashes, or private handoff payloads
  into prompts, files, PR bodies, review text, logs, or command output.
- Do not enable the Symphony++ MCP server globally for all generic workers.
  Use a dedicated S++ MCP session and the package's ledger claim metadata.
- Do not edit or refresh user-local plugin/cache paths during feature-branch
  work; do that only at final feature-branch cutover.
- Do not treat the cockpit as a permission bypass. Worker and architect writes
  still require scoped grants and MCP permissions.
- Do not dispatch unapproved planned slices.
- Do not assume backward compatibility unless the product docs or recorded
  WorkRequest decisions say so.
- Do not treat dashboard dispatch as agent spawning. Start the architect and
  worker Codex sessions yourself with the correct skill.
