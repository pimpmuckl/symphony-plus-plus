# Symphony++ Codex Plugin

This plugin exposes the `symphony-work-package` skill and a generic
`symphony_plus_plus` MCP server entry as a local Codex plugin. The canonical
source for the runtime remains this repository; the plugin cache under
`~/.codex/plugins/cache/...` is generated install state.

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

Restart or reload Codex so the refreshed skill and MCP server list is loaded.

## Plugin MCP Entry

The plugin manifest declares `mcpServers: "./.mcp.json"`. That file registers a
generic installable `symphony_plus_plus` stdio MCP entry for Codex plugin UI and
capability discovery.

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
