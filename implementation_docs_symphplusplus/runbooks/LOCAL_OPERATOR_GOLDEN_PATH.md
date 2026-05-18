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
  default `symphony-plus-plus` Codex plugin for Solo Session planning.
- For WorkRequest architect or WorkPackage worker sessions, also make the
  opt-in `symphony-plus-plus-mcp` plugin/config available in that dedicated
  MCP-enabled session before launch. Do not rely on the default plugin alone
  for the `symphony-plus-plus-mcp:*` skills, and do not enable the MCP plugin
  for generic review or unrelated Codex sessions.

If you are developing the local plugin or skills, refresh the installed plugin
cache from the repository root:

```powershell
.\scripts\refresh-local-plugin.ps1 -ValidateInstalledCache
```

Then reload Codex and start a new session. Existing sessions may keep the old
skill and MCP registration list.

If the default Symphony++ skill is visible but the `symphony_plus_plus` MCP
tools are missing, run the activation doctor from the repository root:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName jonat-local -Doctor
```

The normal repair for `solo_ready_mcp_companion_not_enabled` is to enable
the companion only in the dedicated S++ MCP config/Codex home:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName jonat-local -EnableMcpCompanion
```

The enable command validates the installed companion cache and manifest, writes
only `[plugins."symphony-plus-plus-mcp@jonat-local"] enabled = true`, and keeps
a timestamped `config.toml.sympp-backup-*` before changing an existing config.
It refuses the default `~/.codex` home. Then restart or reload that dedicated
session. Do not add the MCP companion to generic worker, `worker_smart`,
review-suite, or `codex review` configs.
The doctor checks cache, config, and the local HTTP daemon; it cannot inspect
the tool list already registered inside an open Codex model session. Treat
session restart/reload as part of the repair after enablement or cache changes.

For normal operator use, keep one durable SQLite ledger path handy:

```powershell
$ledger = "C:\path\to\sympp-local.sqlite3"
```

Use the same explicit ledger path for the cockpit, planned-slice dispatch, MCP
handoffs, and Solo Session commands that should see the same local state.

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
mix sympp.cockpit --database $ledger
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
single header value, follows with `tools/list`, and verifies the generic
unbound tool surface including `sympp.health`, the `solo_*` tools, and
`claim_work_key`. For a non-default or dynamic cockpit port, pass the printed
MCP URL:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -Url http://127.0.0.1:<port>/mcp
.\scripts\smoke-sympp-mcp-http.ps1 -Json
```

A passing smoke proves the cockpit/MCP daemon is serving the HTTP MCP contract.
It does not prove that an already-open Codex app session loaded or enabled the
opt-in `symphony-plus-plus-mcp` plugin; reload/start that dedicated session
after fixing plugin config or cache state.

For a worker package whose private handoff has already placed the work key in a
local secret store, read that secret into a short-lived environment variable
inside your shell and run the bound smoke by variable name:

```powershell
$env:SYMPP_WORK_KEY_SECRET = Get-Content -LiteralPath "<private-secret-file>" -Raw
.\scripts\smoke-sympp-mcp-http.ps1 `
  -Bound `
  -WorkKeySecretEnv SYMPP_WORK_KEY_SECRET `
  -ClaimedBy <stable-worker-id>
Remove-Item Env:\SYMPP_WORK_KEY_SECRET -ErrorAction SilentlyContinue
```

The bound smoke claims the session, confirms the bound worker tool surface no
longer exposes Solo tools, verifies assignment/resource continuity, and redacts
the claimed `Mcp-Session-Id` and raw work key from text and JSON output. Use
`-SkipUnboundTools` only when you intentionally want to skip the pre-claim
unbound surface check.

After a WorkPackage worker or WorkRequest architect claims its work key, the
same local HTTP `Mcp-Session-Id` remains bound for scoped follow-up tools and
resources. Treat claimed-session ids as sensitive local continuity material:
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

Dashboard dispatch creates a WorkPackage, worker grant, and private worker
secret handoff. It records the stable worker identity `local-operator-worker`
and shows only non-secret WorkPackage, linkage, and handoff metadata. It does
not spawn Codex agents and does not call Linear.

Give each worker:

- The WorkPackage id, target branch, base branch, owned paths, acceptance
  criteria, required validation, review lanes, and stop conditions.
- The non-secret private-store handoff metadata or generated MCP bootstrap
  shape.
- The stable `claimed_by` identity for that package.
- The instruction to use `symphony-plus-plus-mcp:symphony-work-package`.
- The explicit requirement to launch the worker in an opt-in Symphony++
  MCP-enabled session before using that skill.
- The instruction to ask the architect first for product, architecture,
  dependency, or slice-boundary ambiguity.

Workers update MCP-backed planning, not local markdown planning files. They
read the current assignment, update task plan/findings/progress through MCP,
attach branch and PR evidence, run validation and review, and mark ready only
after package gates pass.

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
  --database <solo-ledger.sqlite3> `
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
| One assigned WorkPackage or WorkKey with MCP-backed planning and readiness evidence | `symphony-plus-plus-mcp:symphony-work-package` |
| One normal local agent session that only needs durable planning memory | `symphony-plus-plus:symphony-solo-session` |

## Handoff Defaults

The current local/private handoff default is local private-file storage,
including on Windows. In `auto` mode, generated Windows commands use the
PowerShell helper to read the private file and inject the secret only into the
MCP child process.

Explicit `windows-credential-manager` mode remains available when the operator
selects it and the host Credential Manager can write credentials. It is not the
default local dogfood path and may fail on hosts where WCM is unavailable.

## What Not To Do

- Do not paste raw work keys, worker secrets, bearer tokens, GitHub tokens,
  Linear tokens, MCP auth tokens, secret hashes, or private handoff payloads
  into prompts, files, PR bodies, review text, logs, or command output.
- Do not enable the Symphony++ MCP server globally for all generic workers.
  Use the private-store MCP bootstrap emitted for the specific WorkPackage.
- Do not treat the cockpit as a permission bypass. Worker and architect writes
  still require scoped grants and MCP permissions.
- Do not dispatch unapproved planned slices.
- Do not assume backward compatibility unless the product docs or recorded
  WorkRequest decisions say so.
- Do not treat dashboard dispatch as agent spawning. Start the architect and
  worker Codex sessions yourself with the correct skill.
