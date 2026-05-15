# Symphony++ Codex Plugin

This plugin exposes Symphony++ Codex skills, Solo Session planning helpers, and
a generic `symphony_plus_plus` MCP server entry as a local Codex plugin. The
canonical source for the runtime remains this repository; the plugin cache
under `~/.codex/plugins/cache/...` is generated install state.

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
repo-root-relative source path `./plugins/symphony-plus-plus`.

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

To prove the installed cache entry is package-complete and the MCP wrapper can
start from the cache path, run:

```powershell
.\scripts\refresh-local-plugin.ps1 -ValidateInstalledCache
```

Restart or reload Codex so the refreshed skill and MCP server list is loaded.
Existing Codex sessions may continue to show only the already-loaded skill list;
start a new session after reload before treating missing `symphony_plus_plus`
MCP tools as a packaging failure.

The refresh script overlays both install cache shapes Codex may consult:
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/local` and the
manifest-version directory, for example
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/0.1.0`. It overwrites
the known plugin package entries in place instead of deleting active cache roots,
so unrelated stale files may remain. Older cache directories are ignored; the
fix for stale cache state is current-version cache parity plus a Codex
reload/new session, not cache garbage collection.
If an existing cache parent, cache directory, or child path is a junction or
symlink, refresh stops with a manual cleanup message instead of recursively
deleting or copying through the link.

## Plugin MCP Entry

The plugin manifest declares `mcpServers: "./.mcp.json"`. That file registers a
generic installable `symphony_plus_plus` stdio MCP entry for Codex plugin UI and
capability discovery.

Repo validation proves only the plugin package contract:

- `.codex-plugin/plugin.json` points `mcpServers` at `./.mcp.json`.
- `.mcp.json` defines a generic `symphony_plus_plus` stdio server.
- `scripts/refresh-local-plugin.ps1` copies `.mcp.json` into the installed
  `local` and manifest-version caches, and writes a non-secret
  `.sympp-source-root` hint.
- `scripts/refresh-local-plugin.ps1 -ValidateInstalledCache` validates the
  installed cache copies, resolves the manifest `mcpServers` pointer, checks
  the generic `symphony_plus_plus` entry, and runs the wrapper with
  `-ValidateOnly` from each cache root. It also validates the Solo Session
  wrapper from each cache root.
- `scripts/start-sympp-mcp.ps1 -ValidateOnly` can resolve the checkout and
  launcher.
- `scripts/sympp-solo.ps1 -ValidateOnly` can resolve the checkout and validate
  the launcher without writing ledger state or requiring a source build.

Plugin skill visibility, MCP server registration, and current-session tool
availability are separate states. Skill visibility proves Codex loaded the skill
directory. MCP server registration proves the plugin manifest and installed
`.mcp.json` advertise a startable server. Current-session tool availability
requires the Codex host to load that MCP registration for the active session.
The installed-cache validation proves the package and wrapper; it does not prove
that an already-running Codex host has hot-loaded plugin MCP discovery. If the
installed-cache validation passes but the plugin detail UI still lists only
skills, reload Codex and open a new session. If a fresh host still omits
`symphony_plus_plus`, treat it as a Codex host/plugin-UI discovery issue with
the package evidence above; do not work around it by adding a global
`[mcp_servers]` entry to generic worker config.

The generic entry runs `plugins/symphony-plus-plus/scripts/start-sympp-mcp.ps1`
through `pwsh`, the cross-platform PowerShell executable. Hosts that use the
generic plugin MCP entry need `pwsh` on `PATH`.
When the plugin is executed from this source checkout, the wrapper can infer the
repository root. When it runs from an installed plugin cache, set
`SYMPP_REPO_ROOT` to a Symphony++ checkout or refresh the local cache with
`scripts/refresh-local-plugin.ps1`, which writes a non-secret source-root hint
for the wrapper. Set `SYMPP_DATABASE` when the MCP server should use a specific
SQLite ledger instead of the runtime default.

The wrapper defaults to running `mix` directly from `PATH`, so the generic
plugin MCP path does not require `mise trust` when `mix` resolves to a real
Elixir executable. If `mix` resolves to a mise shim, validation fails with
guidance to set `SYMPP_MIX` to a non-mise Mix executable or opt into
`SYMPP_LAUNCHER=mise` after trusting the checkout's mise config.

Static plugin files must not contain raw worker secrets, private-store handoff
targets, bearer tokens, or one-off operator-local secret material.

## Solo Session Use

Normal single-agent Codex work can use the plugin-installed
`symphony-plus-plus:symphony-solo-session` skill for lightweight local planning
memory without WorkRequest, WorkPackage, MCP, Linear, architect handoff, or
worker dispatch semantics.

That skill uses `scripts/sympp-solo.ps1`, which resolves the Symphony++ checkout
from source or installed cache and passes commands through to `mix sympp.solo`
from the resolved `elixir/` directory. Use it to attach a local Solo Session,
append `task_plan`, `finding`, `progress`, `blocker`, `decision`, and
`validation_note` entries, read the ledger, and pause, resume, complete, or
archive the session.

When neither `--database` nor `SYMPP_DATABASE` is supplied, the wrapper derives
the caller workspace from the original current directory and passes
`<caller-workspace>/.sympp/solo-sessions.sqlite3` to `mix sympp.solo`. The
wrapper resolves relative database paths against the caller workspace and
restores the original current directory after invoking Mix.

Solo Session planning is explicitly separate from WorkPackage orchestration.
Use `symphony-plus-plus:symphony-work-package` for assigned WorkPackages or
WorkKeys, and `symphony-plus-plus:symphony-architect` for WorkRequest-led
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

The generic plugin MCP install is not a substitute for a per-worker private
handoff. Worker package dispatch should still use the `run-mcp` command emitted
by `mix sympp.create_work` or planned-slice dispatch, because that command
connects the MCP process to the private worker-secret store and stable
`claimed_by` identity for exactly one WorkPackage.

Worker-secret bootstrap metadata is emitted by `mix sympp.create_work` after it
stores the one-time secret in a private local store. On Windows, generated
commands use `scripts/sympp-worker-secret.ps1` for Windows Credential Manager.
`local-private-file` is a non-Windows fallback and uses
`scripts/sympp-worker-secret.sh` to read the private file and start the MCP child
process without printing the secret.

## Architect Use

Architect agents use the plugin-installed
`symphony-plus-plus:symphony-architect` skill before worker dispatch. That skill
is for WorkRequest-led orchestration: read current WorkRequest or architect
package context, ask and record product clarification, record decisions and
assumptions, author/approve planned slices, dispatch approved slices, route
package guidance, and stop instead of inventing product behavior.

Use `symphony-plus-plus:symphony-architect` when assigned a Symphony++
WorkRequest, an architect WorkPackage, phase or feature orchestration, or v2
WorkRequest-led planning. Use `symphony-plus-plus:symphony-work-package` only
for the implementing worker that owns one bounded WorkPackage after dispatch.

The architect skill expects the same secret hygiene as worker flow. It may
route workers to private-store handoff metadata, but static plugin docs and
prompts must not include raw work keys, bearer tokens, MCP auth tokens, GitHub
tokens, Linear tokens, private-store payloads, or full secret-bearing commands.
