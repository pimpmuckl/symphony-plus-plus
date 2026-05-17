# Symphony++ Codex Plugin

This plugin exposes Symphony++ Codex skills and Solo Session planning helpers
as a local Codex plugin. Explicit `symphony_plus_plus` MCP reference assets
remain in the package for dedicated S++ workflows, but the default plugin
manifest is skill-only. The canonical source for the runtime remains this
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
[plugins."symphony-plus-plus@jonat-local"]
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

To prove the installed cache entry is package-complete, skill-only by default,
and still carries valid explicit MCP wrapper assets, run:

```powershell
.\scripts\refresh-local-plugin.ps1 -ValidateInstalledCache
```

Restart or reload Codex so the refreshed skill list and manifest metadata are
loaded. Existing Codex sessions can continue using already-loaded plugin
metadata.

The refresh script overlays both install cache shapes Codex may consult:
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/local` and the
manifest-version directory, for example
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/0.1.2`. It overwrites
the known plugin package entries in place instead of deleting active cache roots,
so unrelated stale files may remain. Older cache directories are ignored; the
fix for stale cache state is current-version cache parity plus a Codex
reload/new session, not cache garbage collection.
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
The default manifest points at `skills-default/`, which exposes only the
MCP-free Solo Session skill. MCP-dependent WorkPackage and architect skills
ship in the sibling opt-in MCP plugin.

The repo keeps `.mcp.json` and `scripts/start-sympp-mcp.ps1` as explicit MCP
reference assets for dedicated S++ workflows, but they are not advertised by
the default skill plugin. WorkPackage workers should use the scoped `run-mcp`
command emitted by Symphony++ dispatch. Dedicated plugin-based S++ MCP sessions
can install the sibling `plugins/symphony-plus-plus-mcp` package in an explicit
Codex config or alternate Codex home. Do not enable that opt-in MCP plugin in a
generic/global config unless every session on that config should start S++ MCP.

Repo validation proves only the plugin package contract:

- `.codex-plugin/plugin.json` does not declare `mcpServers`, so enabling the
  default plugin does not ask Codex to start S++ MCP in generic/review sessions.
- `.mcp.json` defines a generic `symphony_plus_plus` stdio server using a
  documented direct server map, not a nested `mcpServers` object, for explicit
  opt-in use.
- `scripts/refresh-local-plugin.ps1` copies `.mcp.json` into the installed
  `local` and manifest-version caches, and writes a non-secret
  `.sympp-source-root` hint.
- `scripts/refresh-local-plugin.ps1 -ValidateInstalledCache` validates the
  installed cache copies, confirms the default manifest remains skill-only,
  checks the reference `symphony_plus_plus` entry, and runs the wrapper with
  `-ValidateOnly` from each cache root. It also validates the Solo Session
  wrapper from each cache root.
- `scripts/start-sympp-mcp.ps1 -ValidateOnly` can resolve the checkout and
  launcher.
- `scripts/sympp-solo.ps1 -ValidateOnly` can resolve the checkout and validate
  the launcher without writing ledger state or requiring a source build.

Plugin skill visibility, explicit MCP configuration, global MCP settings
visibility, and current-session tool availability are separate states. Skill
visibility proves Codex loaded the skill directory. The default plugin should
stop there. An MCP configuration proves a session was intentionally given a
server dependency.
On Windows, when a plugin manifest does declare a generic S++ `mcpServers`
entry, current Codex host behavior can start a separate stdio process tree for
each Codex app session, `codex exec`, `codex review`, resumed session, review
lane, or subagent that loads the enabled plugin. A typical generic plugin tree
is:

```text
pwsh -NoProfile -Command ... scripts/start-sympp-mcp.ps1
  cmd.exe /c ... mix.bat sympp.mcp --mode stdio --repo-root <repo>
    erl.exe ... mix sympp.mcp --mode stdio ...
      erl.exe ... mix sympp.mcp --mode stdio ...
```

That per-session startup is host-managed by a plugin `mcpServers` declaration;
the Symphony++ launcher does not call `taskkill`, `Stop-Process`, or global
Codex cleanup. Windows `SUCCESS: The process with PID ... has been terminated.`
lines during turn/session cleanup are therefore expected to come from the Codex
host terminating stdio servers it started, not from Symphony++ scripts.

For non-destructive lifecycle forensics, run the installed diagnostic from the
plugin root:

```powershell
.\scripts\diagnose-mcp-lifecycle.ps1
.\scripts\diagnose-mcp-lifecycle.ps1 -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName jonat-local -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -RepoRoot C:\Code\symphony-plus-plus -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -SelfTest
```

The diagnostic reports installed cache versions, manifest lifecycle status,
`.mcp.json` shape, source-root hints, whether the plugin is enabled in Codex
config, whether a global `[mcp_servers.symphony_plus_plus]` entry exists,
whether cache `.mcp.json` defines the expected `symphony_plus_plus` stdio
server, and focused live process counts for `start-sympp-mcp.ps1`,
`mix.bat sympp.mcp`, and `erl.exe sympp.mcp`.
By default it scans every `symphony-plus-plus` marketplace cache under the
Codex home; pass `-MarketplaceName` to narrow cache and config checks to one
marketplace. Cache manifests that still declare `mcpServers` are reported as
`incompatible_default_plugin_bundles_mcp`, and missing manifests are reported as
`missing_manifest`.
Use it to distinguish stale installed caches, explicit MCP sessions, and
host-managed eager startup from duplicated marketplace entries. If the default
skill-only plugin is refreshed and a fresh Codex host still starts S++ MCP for
generic or review sessions, file a product issue for lazy or opt-in-only plugin
MCP startup with the diagnostic JSON attached as evidence.
Live process counts are scoped to `-RepoRoot` when supplied. Without
`-RepoRoot`, the diagnostic uses installed-cache `.sympp-source-root` hints only
from current usable cache entries: `local` and the source manifest-version
directory. Those current entries may be skill-only or stale bundled-MCP caches,
but their reference `.mcp.json` server must be valid, and they must point at one
checkout. Superseded version directories, missing manifests, malformed
manifests, and broken reference MCP entries are reported but do not provide
implicit process scope. If no valid scope is available, or if usable current
caches point at multiple checkouts, the scoped process scan is skipped instead
of reporting machine-wide processes for the selected Codex home.
When `-RepoRoot` supplies an explicit checkout scope, unmatched
`start-sympp-mcp.ps1` launchers are reported separately as unattributed so a
wrapper stuck before `mix` starts is visible without assigning it to another
checkout. The diagnostic rejects `-RepoRoot` values that do not resolve to a
checkout with `elixir/mix.exs`.
The live count includes the default direct `mix.bat` path and the opt-in
`mise exec -- mix` launcher path.
Malformed installed cache JSON is reported on the affected cache entry instead
of aborting the whole diagnostic.
On non-Windows hosts, the diagnostic still reports cache/config state and marks
the Windows process scan as unsupported.
The diagnostic truncates and redacts common secret-bearing command-line forms,
including bearer headers and `--token` or `--api-key` flag values; run
`-SelfTest` after editing that sanitizer.
The installed-cache validation proves the skill-only default package, explicit
MCP reference file, and wrappers. It does not prove that an already-running
Codex host has reloaded plugin metadata. After refreshing the cache, reload
Codex and open a new session before treating old generic S++ MCP startup as a
current package failure. Do not work around missing explicit MCP tools by adding
a global `[mcp_servers]` entry to generic worker config.

### Default Planning And Opt-In MCP

Symphony++ remains the default durable planning substrate for real agents
without requiring default MCP startup. Ordinary implementation and architecture
sessions should use the plugin-installed
`symphony-plus-plus:symphony-solo-session` skill plus
`scripts/sympp-solo.ps1` for task plans, findings, progress, blockers,
decisions, validation notes, and local ledger reads. That path is available
from the default skill-only plugin and does not require Codex to start or
register the `symphony_plus_plus` MCP server.

Heavy WorkPackage and architect orchestration still needs explicit MCP tools.
Starting `scripts/start-sympp-mcp.ps1` from a shell is not enough: Codex must
load an MCP server configuration before the model session starts for the tools
to be registered in that session. Current local Codex validation recognizes
top-level `mcp_servers.symphony_plus_plus` configuration and `-c
mcp_servers...` startup overrides, but it does not recognize a nested
`[profiles."sympp-agent".mcp_servers.symphony_plus_plus]` entry. Until Codex
supports profile-scoped MCP servers, use an explicit one-session top-level MCP
config, a dedicated alternate Codex config selected before launch, or a
dedicated S++ agent config file for S++ roles. The sibling
`plugins/symphony-plus-plus-mcp` plugin is the bundled opt-in package for that
dedicated config path. Do not add S++ MCP to generic worker or reviewer configs.

Example explicit Windows TOML for an opt-in S++ session:

```toml
[mcp_servers.symphony_plus_plus]
command = "pwsh"
args = [
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  "plugins/symphony-plus-plus/scripts/start-sympp-mcp.ps1",
]
cwd = "C:\\Code\\symphony-plus-plus"
startup_timeout_sec = 30

[mcp_servers.symphony_plus_plus.env]
SYMPP_DATABASE = "C:\\Code\\symphony-plus-plus\\.sympp\\mcp.sqlite3"
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
`plugins/symphony-plus-plus/scripts/start-sympp-mcp.ps1` through `pwsh`, the
cross-platform PowerShell executable. Hosts that use that explicit entry need
`pwsh` on `PATH`.
When the plugin is executed from this source checkout, the wrapper can infer the
repository root. When it runs from an installed plugin cache, set
`SYMPP_REPO_ROOT` to a Symphony++ checkout or refresh the local cache with
`scripts/refresh-local-plugin.ps1`, which writes a non-secret source-root hint
for the wrapper. Set `SYMPP_DATABASE` when the MCP server should use a specific
SQLite ledger instead of the runtime default.

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

The generic `symphony_plus_plus` MCP server also advertises first-slice Solo
tools for unbound sessions: `solo_attach`, `solo_append`, `solo_show`,
`solo_list`, and `solo_update_status`. Bound worker or architect WorkPackage
sessions do not advertise those tools, and direct calls from bound sessions are
rejected before mutation. `solo_show` returns the latest 50 entries plus
count/truncation metadata, while `solo_update_status` reuses the Solo lifecycle
service for pause, resume, complete, and archive transitions. Use the CLI
wrapper when the host has not loaded the MCP entry or full ledger history is
required.

When neither `--database` nor `SYMPP_DATABASE` is supplied, the wrapper derives
the caller workspace from the original current directory and passes
`<caller-workspace>/.sympp/solo-sessions.sqlite3` to `mix sympp.solo`. The
wrapper resolves relative database paths against the caller workspace and
restores the original current directory after invoking Mix.

Solo Session planning is explicitly separate from WorkPackage orchestration.
Use `symphony-plus-plus-mcp:symphony-work-package` for assigned WorkPackages or
WorkKeys, and `symphony-plus-plus-mcp:symphony-architect` for WorkRequest-led
orchestration. Solo Session entries must not include raw secrets, tokens,
worker handoff payloads, WorkKeys, or private grant material.

## Worker Use

Workers use the plugin together with the Symphony++ MCP stdio server. The
operator creates a WorkPackage, the create-work command stores the one-time
secret in a private local handoff store, and the worker receives only
non-secret handoff metadata plus a stable `claimed_by` identity.

The skill then instructs the worker to load the current assignment, read the
MCP-backed planning resources, update plan/findings/progress through MCP,
attach branch/PR/review evidence, and mark ready only after package gates pass.
Do not paste raw worker secrets into prompts, command lines, PR bodies, review
text, or durable logs.

Plugin install is not a substitute for a per-worker private handoff. Worker
package dispatch should still use the `run-mcp` command emitted
by `mix sympp.create_work` or planned-slice dispatch, because that command
connects the MCP process to the private worker-secret store and stable
`claimed_by` identity for exactly one WorkPackage.

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
WorkRequest, an architect WorkPackage, phase or feature orchestration, or v2
WorkRequest-led planning. Use `symphony-plus-plus-mcp:symphony-work-package` only
for the implementing worker that owns one bounded WorkPackage after dispatch.

The architect skill expects the same secret hygiene as worker flow. It may
route workers to private-store handoff metadata, but static plugin docs and
prompts must not include raw work keys, bearer tokens, MCP auth tokens, GitHub
tokens, Linear tokens, private-store payloads, or full secret-bearing commands.
