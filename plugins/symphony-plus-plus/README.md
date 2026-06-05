# Symphony++ Codex Plugin

This plugin exposes Symphony++ MCP-free planning skills as a local Codex
plugin: Solo Session memory, the baseline worker playbook, and the lightweight
coordinator playbook. The default plugin package is physically MCP-free: it
must not ship a root `.mcp.json` and its manifest is skill-only. The sibling
`symphony-plus-plus-mcp` package owns the bundled MCP startup file and the full
MCP-mode skill set for dedicated S++ workflows. The canonical source for the runtime remains this
repository; the plugin cache under `~/.codex/plugins/cache/...` is generated
install state.

## Install

Point a Codex marketplace entry at this directory:

```json
{
  "name": "symphony-plus-plus",
  "source": {
    "source": "local",
    "path": "./plugins/symphony-plus-plus"
  },
  "policy": {
    "installation": "AVAILABLE",
    "authentication": "ON_USE"
  },
  "category": "Coding"
}
```

The committed repo marketplace at `.agents/plugins/marketplace.json` uses the
repo-root-relative source path `./plugins/symphony-plus-plus` for the default
skill-only plugin and also exposes the opt-in MCP companion at
`./plugins/symphony-plus-plus-mcp`.

Then enable the plugin with the active marketplace name:

```toml
[plugins."symphony-plus-plus@symphony-plus-plus"]
enabled = true
```

After changing plugin-facing files, refresh the local plugin cache from the
repository root:

```powershell
.\scripts\refresh-local-plugin.ps1
```

By default this refreshes every Symphony++ package present in the repo
marketplace, including the default `symphony-plus-plus` plugin and the opt-in
`symphony-plus-plus-mcp` companion. Pass `-PluginName symphony-plus-plus` or
`-PluginName symphony-plus-plus-mcp` only when intentionally refreshing one
package.

To prove the installed cache entries are package-complete, MCP-free by default,
and MCP-enabled only for the opt-in companion, run:

```powershell
.\scripts\refresh-local-plugin.ps1 -ValidateInstalledCache
```

Restart or reload Codex so the refreshed skill list and manifest metadata are
loaded. Existing Codex sessions can continue using already-loaded plugin
metadata.

The refresh script writes the GitHub-marketplace-shaped manifest-version cache
directory, for example
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/<version>`, and prunes the
older generated `local` cache root when it carries the script's
`.sympp-source-root` marker after the versioned cache has been written and, when
requested, validated. Unmarked `local` directories stop refresh with a manual
cleanup message instead of being deleted or silently ignored. Because the default package must be
MCP-inert even if a host scans cache-root `.mcp.json` files directly, refresh
also repairs generated default-cache entries in place by removing stale root
`.mcp.json` files and stripping stale manifest `mcpServers` declarations. It
also prunes removed managed package entries, including stale skill directories
inside refreshed versioned cache roots. It does not delete superseded version
directories. Cleanup is scoped to generated
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/*` cache entries;
manual scratch directories without generated-entry markers are left alone.
If an existing cache parent, cache directory, or child path is a junction or
symlink, refresh stops with a manual cleanup message instead of recursively
deleting or copying through the link.

## MCP Lifecycle And Explicit Use

The default `symphony-plus-plus` plugin is intentionally skill-only: its
manifest does not declare `mcpServers`. Do not add a bundled generic MCP server
to this default plugin. Current Codex host behavior can eagerly start
plugin-bundled MCP servers for generic sessions, review-suite lanes, and
`codex review` calls whenever the plugin is enabled; that creates needless S++
Elixir process churn when the session does not explicitly need S++ tools.
The default manifest points at `skills-default/`, which exposes only MCP-free
base skills: Solo Session, worker, and coordinator. The default package
intentionally does not ship a root `skills/` directory, so Codex hosts that scan
package folders directly cannot surface the MCP-dependent WorkPackage or
architect skills from the default plugin. Those skills ship only in the sibling
opt-in MCP plugin.

The default plugin source and refreshed default cache must not contain root
`.mcp.json`. Planned-slice WorkPackage workers should use the ledger-backed
`claim_local_assignment` metadata emitted by Symphony++ dispatch. Dedicated
plugin-based S++ MCP sessions can install the sibling
`plugins/symphony-plus-plus-mcp` package in an explicit Codex config or
alternate Codex home. Do not enable that opt-in MCP plugin in a generic/global
config unless every session on that config should start S++ MCP.

The preferred MCP runtime shape is a singleton local HTTP daemon, not one
stdio Elixir tree per Codex session. A dogfood snapshot on Windows with the
local cockpit already running showed the unbound `tools/list` response at about
2.6 KB, roughly 650 token-equivalent by a simple chars/4 estimate, and local
initialize plus `tools/list` handshakes averaging about 19 ms across ten
samples, with the warm samples around 8-14 ms after one cold 105 ms sample. On
the Chocolatey Elixir install, the singleton listener appeared as a tiny parent
`erl.exe` launcher around 2 MB plus one real `erl.exe` VM around 25 MB working
set. That is small enough for dedicated S++ sessions; the remaining product
choice is tool visibility in generic sessions, not daemon CPU churn.

Repo validation proves only the plugin package contract:

- `.codex-plugin/plugin.json` does not declare `mcpServers`, and root
  `.mcp.json` is absent, so enabling the default plugin does not ask Codex to
  start S++ MCP in generic/review sessions.
- `plugins/symphony-plus-plus-mcp/.mcp.json` defines a command-backed generic
  `symphony_plus_plus` launcher using a documented direct server map, not a
  nested `mcpServers` object, for explicit opt-in use. The launcher starts
  fresh managed backend/dashboard processes on Codex startup, reuses the
  recorded managed runtime only while another Codex bridge lease is alive, and
  bridges Codex stdio MCP traffic into the backend HTTP `/mcp` endpoint.
  Existing local listeners require explicit `SYMPP_BACKEND_URL` or
  `SYMPP_DASHBOARD_ORIGIN` configuration to be reused as operator-owned
  external processes.
- `scripts/refresh-local-plugin.ps1` removes stale managed default-cache
  `.mcp.json` files, strips stale manifest `mcpServers` from generated default
  cache entries, prunes removed managed skill directories, and writes a
  non-secret `.sympp-source-root` hint for local developer cache refreshes.
- `scripts/refresh-local-plugin.ps1 -ValidateInstalledCache` validates the
  installed cache copies, confirms the default manifest remains skill-only,
  confirms default cache roots do not contain `.mcp.json`, checks the opt-in
  `symphony_plus_plus` command-backed launcher entry, and validates the Solo
  Session wrapper from each cache root.
- `plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1 -Doctor`
  compares installed cache fingerprints with the inferred source checkout so a
  same-version stale cache reports an explicit refresh action instead of a
  shape-only ready result.
- `scripts/start-sympp-mcp.cmd -ValidateOnly` can resolve the checkout and
  launch through `pwsh.exe` or Windows PowerShell. Installed marketplace
  launchers discover the full marketplace source clone automatically; they do
  not require operators to set `SYMPP_REPO_ROOT`.
- `scripts/sympp-solo.ps1 -ValidateOnly` can resolve the checkout and validate
  the launcher without writing ledger state or requiring a source build.

Plugin skill visibility, explicit MCP configuration, global MCP settings
visibility, and current-session tool availability are separate states. Skill
visibility proves Codex loaded the skill directory. The default plugin should
stop there. An MCP configuration proves a session was intentionally given a
server dependency.
On Windows, when a plugin manifest does declare a generic S++ `mcpServers`
entry, current Codex host behavior can start a plugin stdio process for
each Codex app session, `codex exec`, `codex review`, resumed session, review
lane, or subagent that loads the enabled plugin. The opt-in companion keeps
that behavior scoped to dedicated S++ configs; a typical launcher tree is:

```text
cmd.exe /d /s /c scripts\start-sympp-mcp.cmd
  (background, logged) mix sympp.cockpit --port <actual-backend-port> ...
  (background, logged) npm run dev -- --port <actual-dashboard-port>
```

That per-session startup is host-managed by a plugin `mcpServers` declaration.
The foreground process bridges stdio MCP to the backend HTTP `/mcp`, records a
local bridge lease while Codex is connected, and removes that lease when stdin
closes. The normal lifecycle is deliberately simple: fresh managed servers on
Codex startup, reuse only while at least one Codex bridge lease is alive, and
shutdown after the last bridge exits. Backend and frontend output is redirected
to the log paths recorded in the runtime file. When the last bridge lease exits,
the launcher stops only the managed backend/frontend PIDs it previously
recorded, including managed PIDs superseded by a newer backend/dashboard plan,
and whose command lines still match Symphony++; externally configured
`SYMPP_BACKEND_URL` or `SYMPP_DASHBOARD_ORIGIN` processes remain operator-owned.

For non-destructive lifecycle forensics, run the installed diagnostic from the
plugin root:

```powershell
.\scripts\diagnose-mcp-lifecycle.ps1
.\scripts\diagnose-mcp-lifecycle.ps1 -Doctor
.\scripts\diagnose-mcp-lifecycle.ps1 -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -RepoRoot C:\Code\symphony-plus-plus -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -SkipProcessScan -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
.\scripts\diagnose-mcp-lifecycle.ps1 -SelfTest
```

The diagnostic reports installed cache versions, manifest lifecycle status,
root `.mcp.json` presence/shape, source-root hints, whether the plugin is
enabled in Codex config, whether a global `[mcp_servers.symphony_plus_plus]`
entry exists, whether opt-in cache `.mcp.json` defines the expected
`symphony_plus_plus` command-backed launcher, and focused live process counts for
`start-sympp-mcp.ps1`,
`mix.bat sympp.mcp`, and `erl.exe sympp.mcp`.
By default it scans every `symphony-plus-plus` marketplace cache under the
Codex home; pass `-MarketplaceName` to narrow cache and config checks to one
marketplace. Default cache entries that still declare `mcpServers` or still
contain a root `.mcp.json` are reported as
`incompatible_default_plugin_bundles_mcp`, and missing manifests are reported as
`missing_manifest`.
Use it to distinguish stale installed caches, explicit MCP sessions, and
host-managed eager startup from duplicated marketplace entries. If the default
skill-only plugin is refreshed and a fresh Codex host still starts S++ MCP for
generic or review sessions, file a product issue for lazy or opt-in-only plugin
MCP startup with the diagnostic JSON attached as evidence.
Use `-Doctor` when the operator symptom is "I see the Symphony++ skill but no
`symphony_plus_plus` MCP tools." The doctor adds a readiness summary that
separates default Solo Session readiness from WorkRequest MCP readiness. The
common healthy-default/missing-tools state is
`solo_ready_mcp_companion_not_enabled`: the skill-only
`symphony-plus-plus@<marketplace>` plugin is enabled, the
`symphony-plus-plus-mcp@<marketplace>` companion is installed, but that
companion is not enabled for the current Codex config/session. The next action
is to run the explicit enable command against the dedicated S++ MCP Codex home:

```powershell
.\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
```

That command validates the installed companion cache and manifest, writes only
the `[plugins."symphony-plus-plus-mcp@<marketplace>"] enabled = true` table in
the selected `config.toml`, and creates a timestamped
`config.toml.sympp-backup-*` backup before changing an existing config. It does
not write `[mcp_servers.*]`, generic worker profiles, review-suite config, or
unrelated plugin entries. It refuses the default `~/.codex` home; pass the
dedicated Codex home used only for S++ MCP sessions. After it succeeds, restart
or reload that dedicated session and keep generic workers, review-suite lanes,
and `codex review` on the clean skill-only default.
The doctor verifies source/cache/config plus local HTTP daemon readiness. It
cannot inspect the tool list already registered inside an open Codex model
session, so after config/cache changes the final repair step is always to
restart or reload the dedicated MCP-enabled session and verify the tools there.
When source-only repair commands are needed, the doctor emits absolute commands
against the supplied `-RepoRoot`, the current source checkout, the Codex
marketplace source clone, or a single usable `.sympp-source-root` hint from the
selected activation package caches. If no source checkout can be inferred, it
omits the broken command and tells the operator to rerun with
`-RepoRoot <path-to-symphony-plus-plus-checkout>`.
If more than one Symphony++ marketplace cache is installed and no
`-MarketplaceName` is supplied, the doctor does not emit package-specific repair
commands; rerun it with the intended marketplace. If it reports
`global_footgun_present`, remove or relocate the top-level
`[mcp_servers.symphony_plus_plus]` entry into a dedicated S++ config instead of
leaving it in generic worker/review configs.
Live process counts are scoped to `-RepoRoot` when supplied. Without
`-RepoRoot`, the diagnostic uses installed-cache `.sympp-source-root` hints only
from current usable cache entries: `local` and the source manifest-version
directory. Those current entries may be opt-in MCP caches or stale default
bundled-MCP caches, but any cache used for process scope must have a valid
`symphony_plus_plus` entry and point at one checkout. Fresh MCP-free default
caches do not provide implicit process scope. Superseded version directories,
missing manifests, malformed manifests, and broken MCP entries are reported but
do not provide implicit process scope. If no valid scope is available, or if
usable current caches point at multiple checkouts, the scoped process scan is
skipped instead of reporting machine-wide processes for the selected Codex home.
When `-RepoRoot` supplies an explicit checkout scope, unmatched
`start-sympp-mcp.ps1` launchers are reported separately as unattributed so a
wrapper stuck before `mix` starts is visible without assigning it to another
checkout. The diagnostic rejects `-RepoRoot` values that do not resolve to a
checkout with `elixir/mix.exs`.
The live count includes the default direct `mix.bat` path and the opt-in
`mise exec -- mix` launcher path.
Use `-SkipProcessScan` when the operator or test only needs cache, config, and
readiness output and does not need a live `Win32_Process` inventory. Diagnostic
JSON sets `process_scan_performed` so skipped scans are explicit even though
live count fields remain numeric.
Malformed installed cache JSON is reported on the affected cache entry instead
of aborting the whole diagnostic.
On non-Windows hosts, the diagnostic still reports cache/config state and marks
the Windows process scan as unsupported.
The diagnostic truncates and redacts common secret-bearing command-line forms,
including bearer headers and `--token` or `--api-key` flag values; run
`-SelfTest` after editing that sanitizer.
The installed-cache validation proves the skill-only default package is
physically MCP-free and the opt-in MCP package still carries the explicit MCP
file and wrappers. It does not prove that an already-running Codex host has
reloaded plugin metadata. After refreshing the cache, reload Codex and open a
new session before treating old generic S++ MCP startup as a current package
failure. Do not work around missing explicit MCP tools by adding a global
`[mcp_servers]` entry to generic worker config.

### Default Planning And Opt-In MCP

Symphony++ remains the default durable planning substrate for real agents
without requiring default MCP startup. Ordinary implementation workers should
use `symphony-plus-plus:symphony-worker`, and ordinary parent agents should use
`symphony-plus-plus:symphony-coordinator`. Both can attach
`symphony-plus-plus:symphony-solo-session` plus `scripts/sympp-solo.ps1` for
task plans, findings, progress, blockers, decisions, validation notes, and
local ledger reads. That path is available from the default skill-only plugin
and does not require Codex to start or register the `symphony_plus_plus` MCP
server.

Heavy WorkPackage and architect orchestration still needs explicit MCP tools.
In dedicated MCP homes, the opt-in companion plugin starts fresh managed local
servers automatically when Codex starts and reuses them only while another
Codex bridge lease is alive. For manual operation, start the local
cockpit/daemon:

```powershell
cd elixir
mix sympp.cockpit --dashboard-origin http://127.0.0.1:19999
```

By default it prints `http://127.0.0.1:19999/sympp/board` without opening a
browser and serves MCP at `http://127.0.0.1:19998/mcp`, backed by the shared
local Symphony++ default ledger, preferring
`$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`
(`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows) and
falling back under a temp/relative `.agents/splusplus` root if home is
unavailable. Pass `--open-dashboard` only for a deliberate browser launch, and
pass `--database <ledger.sqlite3>` only for isolation. Codex must load an MCP server
configuration before the model session starts for the tools to be registered in
that session. The
sibling `plugins/symphony-plus-plus-mcp` plugin is the bundled opt-in package
for dedicated configs and owns the command-backed launcher for that local HTTP
daemon and dashboard.

Before debugging Codex plugin visibility, verify the daemon itself from the
source repository checkout root. This helper is not copied into installed
plugin cache directories:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

Use `-Url http://127.0.0.1:<port>/mcp` for a non-default cockpit port and
`-Json` for structured output. Passing this smoke means the local HTTP MCP
daemon initialized, preserved the returned `Mcp-Session-Id`, reported the same
source revision as the checkout, and advertised the expected generic tools.
Codex app plugin enabling/visibility is a separate startup/config step. If the
smoke reports `stale_or_unverified_daemon` or
`stale_daemon_source_revision_mismatch`, an old manual cockpit may still own
the port. Dedicated plugin launchers avoid untracked local listeners for
automatic reuse and pick a fallback port when the default is occupied. Set
`SYMPP_BACKEND_URL` or `SYMPP_DASHBOARD_ORIGIN` only when you intentionally want
to reuse an operator-owned external process.
If this smoke passes but a Codex session still lacks S++ MCP tools, run:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

The expected repair is config/session activation, not daemon debugging. Enable
the companion only in the dedicated S++ MCP config:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
```

Then start a new/reloaded session so Codex registers the plugin MCP server
before the model starts.

Example explicit TOML for an opt-in S++ session:

```toml
[mcp_servers.symphony_plus_plus]
command = "cmd.exe"
args = ["/d", "/s", "/c", "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.cmd"]
cwd = "<repo>"
```

Once Codex supports profile-scoped MCP, the preferred product shape is a
`sympp-agent` profile that contains the same explicit server config and is used
only for S++ architect or worker launches, for example
`codex --profile sympp-agent -C <worktree> ...`. The default plugin should
remain skill/docs/lightweight so `codex review`, review-suite lanes, generic
workers, and unrelated `codex exec` calls do not start S++ MCP merely because
the plugin is installed.

The Windows desktop app currently has no proven per-thread S++ profile picker.
`codex app --help` exposes a workspace path and `-c` config overrides, while
`--profile` is only a global CLI option before the `app` subcommand. Even when
the launcher accepts that global flag, current Codex profile schema does not
support profile-scoped MCP servers, so do not design the user-visible app
cockpit around `codex --profile sympp-agent app <path>` as the mechanism for
registering S++ MCP tools in one visible desktop thread. The app-thread UX
should keep the default skill-only plugin and use Solo Session skill/CLI
planning; heavy S++ MCP orchestration should happen in a managed architect or
worker subprocess/app-server session launched with explicit top-level MCP
configuration before session start.

That managed subprocess is the supported replacement for app-visible
WorkPackage and architect execution when the desktop host cannot attach MCP
tools to one already-open thread. The visible cockpit thread records durable
planning state through Solo Session CLI entries, then launches or hands off to a
dedicated Codex CLI/app-server session whose startup config includes the
top-level `mcp_servers.symphony_plus_plus` entry or enables the sibling
`symphony-plus-plus-mcp` plugin in that dedicated config. The same
`symphony-work-package` and `symphony-architect` skills are usable in that
managed session because the tools are registered before the session starts.
Do not invoke those MCP-dependent skills from a generic visible app thread that
does not already show S++ MCP tools; use the Solo/cockpit handoff path instead.

The explicit MCP reference entry runs
`plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.cmd` through `cmd.exe`.
That wrapper prefers `pwsh.exe` and falls back to Windows PowerShell so hosts do
not need a hard-coded PowerShell executable in Codex MCP config.
When the plugin is executed from this source checkout, the wrapper can infer the
repository root. When it runs from an installed plugin cache, the wrapper uses
the Codex marketplace source clone first and falls back to non-secret
`.sympp-source-root` hints from current S++ cache entries. Refresh the local
cache with `scripts/refresh-local-plugin.ps1` if the cache fingerprint, source
clone, or hints are stale. Set `SYMPP_REPO_ROOT` only as a temporary override to the
Symphony++ source checkout containing `elixir/mix.exs`; it is not the
caller/task repository root. Set `SYMPP_DATABASE` only when the MCP server
should use a specific SQLite ledger instead of the runtime default.

The wrapper defaults to running `mix` directly from `PATH`, so the explicit MCP
path does not require `mise trust` when `mix` resolves to a real
Elixir executable. If `mix` resolves to a mise shim, validation fails with
guidance to set `SYMPP_MIX` to a non-mise Mix executable or opt into
`SYMPP_LAUNCHER=mise` after trusting the checkout's mise config.

Static plugin files must not contain raw worker secrets, private-store handoff
targets, bearer tokens, or one-off operator-local secret material.

## Solo Session Use

Normal single-agent Codex work can use the plugin-installed
`symphony-plus-plus:symphony-solo-session` skill for lightweight local planning
memory without WorkRequest, WorkPackage, Linear, architect handoff, or worker
dispatch semantics.

That skill uses `scripts/sympp-solo.ps1`, which resolves the Symphony++ checkout
from source or installed cache and passes commands through to `mix sympp.solo`
from the resolved `elixir/` directory. Use it to attach a local Solo Session,
append `task_plan`, `finding`, `progress`, `blocker`, `decision`, and
`validation_note` entries, read the ledger, and pause, resume, complete, or
archive the session.
The Solo caller repository identity comes from the CLI arguments `--repo` and
`--workspace-path`; `SYMPP_REPO_ROOT` only locates the Symphony++ source
checkout used to run the wrapper.

The generic `symphony_plus_plus` MCP server also advertises first-slice Solo
tools for unbound sessions: `solo_attach`, `solo_append`, `solo_show`,
`solo_list`, and `solo_update_status`. Bound worker or architect WorkPackage
sessions do not advertise those tools, and direct calls from bound sessions are
rejected before mutation. `solo_show` returns the latest 50 entries plus
count/truncation metadata, while `solo_update_status` reuses the Solo lifecycle
service for pause, resume, complete, and archive transitions. Use the CLI
wrapper when the host has not loaded the MCP entry or full ledger history is
required.

When neither `--database` nor `SYMPP_DATABASE` is supplied, the wrapper lets
`mix sympp.solo` use the shared local Symphony++ default ledger, matching
cockpit and WorkRequest/WorkPackage CLI defaults in the preferred
`$HOME/.agents/splusplus/` home or the existing fallback root.
The wrapper resolves relative database overrides against the caller workspace
and restores the original current directory after invoking Mix.

Solo Session planning is explicitly separate from WorkPackage orchestration.
Use this default package for non-MCP Solo, worker, and coordinator sessions.
Use `symphony-plus-plus-mcp:symphony-worker` plus
`symphony-plus-plus-mcp:symphony-work-package` for the preferred packaged MCP
WorkPackage path. Downstream repos that copy only the repo-local
`symphony-work-package` skill should pair it with
`symphony-plus-plus:symphony-worker` and an explicit S++ MCP session. Use
`symphony-plus-plus-mcp:symphony-architect` for WorkRequest-led orchestration.
Solo Session entries must not include raw secrets, tokens, worker handoff
payloads, WorkKeys, or private grant material.
Solo entry bodies are human-facing Markdown; titles, statuses, repo names, and
other compact labels remain plain text.

## Worker And Coordinator Use

The default plugin owns the MCP-free worker and coordinator playbooks:

- `symphony-plus-plus:symphony-worker` for bounded implementation,
  investigation, docs, hotfix, validation, review, and PR readiness.
- `symphony-plus-plus:symphony-coordinator` for ordinary non-MCP parent agents
  that scout, slice, dispatch, supervise, and integrate one or more workers.

WorkPackage workers also use the opt-in MCP plugin together with the
Symphony++ local HTTP daemon. The operator creates a WorkPackage, the
create-work command stores the one-time secret in a private local handoff store,
and the worker receives only non-secret handoff metadata plus a stable
`claimed_by` identity.
Human-facing WorkRequest descriptions, comments, findings, progress bodies,
blocker notes, guidance context, and decision rationale/scope-impact text are
Markdown. Identifiers, titles, statuses, branch names, PR metadata, and badges
remain plain text.

The MCP WorkPackage skill then instructs the worker to load the current
assignment, read MCP-backed planning resources, update plan/findings/progress
through MCP, attach branch/PR/review evidence, and mark ready only after package
gates pass. Do not paste raw worker secrets into prompts, command lines, PR
bodies, review text, or durable logs.

Plugin install is not a substitute for a per-worker claim. Planned-slice worker
package dispatch should use the emitted ledger-backed
`claim_local_assignment` bootstrap plus the prepared branch, worktree path,
caller id, and stable `claimed_by` identity for exactly one WorkPackage.
`mix sympp.create_work` and `run-mcp` private-store bootstrap remain
legacy/recovery paths only.

Worker-secret bootstrap metadata is emitted by `mix sympp.create_work` after it
stores the one-time secret in a private local store. In `auto` mode, local
private-file handoff is the default local operator path on every host, including
Windows. Windows generated commands use `scripts/sympp-worker-secret.ps1`; other
hosts use `scripts/sympp-worker-secret.sh` to read the private file and start
the MCP child process without printing the secret. Explicit
`windows-credential-manager` mode remains available when the host Credential
Manager can write credentials.

## Architect Use

Architect agents use the plugin-installed
`symphony-plus-plus-mcp:symphony-architect` skill before worker dispatch. That skill
is for WorkRequest-led orchestration: read current WorkRequest or architect
package context, ask and record product clarification, record decisions and
assumptions, author/approve planned slices, dispatch approved slices, route
package guidance, and stop instead of inventing product behavior.
For higher-impact human choices, architects should include the existing
`decision_prompt` structure so the cockpit can show a TL;DR, details, bounded
options, tradeoffs, and the freeform redirect path. Plain questions remain
appropriate for simple missing facts.

Use `symphony-plus-plus-mcp:symphony-architect` when assigned a Symphony++
WorkRequest, product-tree planning lane, an architect WorkPackage, phase, or
feature orchestration. Dispatch worker prompts for MCP WorkPackages should name
the packaged MCP pair, `symphony-plus-plus-mcp:symphony-worker` and
`symphony-plus-plus-mcp:symphony-work-package`, or the repo-local fallback pair,
`symphony-plus-plus:symphony-worker` and copied `symphony-work-package`.

The architect skill expects the same secret hygiene as worker flow. It may
route workers to private-store handoff metadata, but static plugin docs and
prompts must not include raw work keys, bearer tokens, MCP auth tokens, GitHub
tokens, Linear tokens, private-store payloads, or full secret-bearing commands.
