# Symphony++ MCP Wiring

The skill assumes the worker session has access to the Symphony++ MCP server
from this repository's Elixir implementation.

## Plugin MCP Entry

The installable Codex plugin exposes a generic `symphony_plus_plus` MCP server
entry through `plugins/symphony-plus-plus/.codex-plugin/plugin.json` and
`plugins/symphony-plus-plus/.mcp.json`. This makes the plugin UI show an MCP
capability in addition to the WorkPackage skill.

Plugin MCP discovery is loaded by the Codex host, not by the skill text in an
already-running thread. After refreshing the local plugin cache, restart or
reload Codex and open a new session before treating missing `symphony_plus_plus`
tools as a repo packaging failure. ValidateOnly checks the wrapper and launcher
only; it does not prove that the current session has hot-loaded new MCP tools.
Use `scripts/refresh-local-plugin.ps1 -ValidateInstalledCache` to prove the
installed cache copies resolve the manifest `mcpServers` pointer, contain the
generic `symphony_plus_plus` server entry, and start the wrapper with
`-ValidateOnly` from the cache root.
The repo refresh script updates both the `local` cache and the manifest-version
cache so a refreshed install has both the manifest `mcpServers` pointer and the
referenced `.mcp.json`. Older cache directories are ignored; reload Codex and
open a new session after refresh.

Skill visibility, MCP server registration, and current-session tool
availability are distinct. A visible skill proves Codex loaded the skill
directory. MCP registration proves the plugin manifest and installed `.mcp.json`
advertise the server. Current-session tools appear only after the host loads
that registration for the session.

The static plugin MCP entry is intentionally generic. It must not embed raw
work-key secrets, bearer tokens, private-store handoff targets, or
operator-local secret material. It may use non-secret environment variables
such as `SYMPP_REPO_ROOT` and `SYMPP_DATABASE` so the wrapper can find the
runtime checkout and optional ledger. The repo-local refresh script also writes
a non-secret source-root hint into the installed cache so the generic entry can
start from generated local install state. The generic entry uses `pwsh`, so
hosts that enable it need PowerShell 7 on `PATH`. Its wrapper runs `mix`
directly by default and rejects mise shims in direct mode; `mise` is opt-in
with `SYMPP_LAUNCHER=mise`.

Generic plugin MCP install is not the same as worker package dispatch. First-use
worker sessions should still use the create-work-generated `run-mcp`
private-store handoff command so the MCP child process receives the secret only
through its environment and claims exactly one WorkPackage with the configured
`claimed_by` identity.

## Server Command

Run the server from `elixir/`:

```bash
mix sympp.mcp --mode stdio
```

If an operator wants mise-managed tools for a hand-written local command, they
can still run `mise exec -- mix ...` after trusting the checkout's mise config.

Use `--database <path>` when the worker must connect to a specific Symphony++
SQLite ledger instead of the default repo database.

## Codex MCP Dependency

Configure Codex to start the MCP server as a stdio MCP dependency for the worker
session. The command should run from the repository's `elixir/` directory and
should not embed raw work-key secrets or bearer tokens.

Example shape for an already-bound or non-secret local smoke test:

```toml
[mcp_servers.symphony_plus_plus]
command = "mix"
args = ["sympp.mcp", "--mode", "stdio", "--database", "<ledger-path>"]
cwd = "<repo>/elixir"
```

## Private Store Bootstrap

For first-use worker dispatch, prefer a private-store wrapper that reads the
one-time secret from the local OS/user store, injects it only into the MCP child
process environment, and starts `sympp.mcp` with both the environment variable
name and the stable worker identity.

Windows local private-file example:

```toml
[mcp_servers.symphony_plus_plus]
command = "powershell"
args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<repo>/scripts/sympp-worker-secret.ps1", "run-mcp-local-file", "-SecretFile", "<secret-file>", "-Database", "<ledger-path>", "-ClaimedBy", "<stable-worker-id>"]
cwd = "<repo>"
```

Windows Credential Manager opt-in example:

```toml
[mcp_servers.symphony_plus_plus]
command = "powershell"
args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<repo>/scripts/sympp-worker-secret.ps1", "run-mcp", "-Target", "<handoff-target>", "-Database", "<ledger-path>", "-ClaimedBy", "<stable-worker-id>"]
cwd = "<repo>"
```

Non-Windows local private-file example:

```toml
[mcp_servers.symphony_plus_plus]
command = "sh"
args = ["<repo>/scripts/sympp-worker-secret.sh", "run-mcp-local-file", "--path", "<secret-file>", "--database", "<ledger-path>", "--claimed-by", "<stable-worker-id>"]
cwd = "<repo>"
```

The wrapper does not print the secret. It sets `SYMPP_WORK_KEY_SECRET` only for
the MCP child process, and `sympp.mcp` claims or reconnects the grant with
`--work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by <stable-worker-id>`.

## Worker Claim

Workers should start from `get_current_assignment()` after MCP initialize. If
the session is not bound, stop and ask the operator to repair the private-store
handoff. A configured `state_key` only preserves initialized handshake
continuity for stateless transports; it does not restore worker authorization.
