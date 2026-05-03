# Symphony++ MCP Wiring

The skill assumes the worker session has access to the Symphony++ MCP server
from this repository's Elixir implementation.

## Server Command

Run the server from `elixir/`:

```bash
mise exec -- mix sympp.mcp --mode stdio
```

Use `--database <path>` when the worker must connect to a specific Symphony++
SQLite ledger instead of the default repo database.

## Codex MCP Dependency

Configure Codex to start the MCP server as a stdio MCP dependency for the worker
session. The command should run from the repository's `elixir/` directory and
should not embed raw work-key secrets or bearer tokens.

Example shape:

```toml
[mcp_servers.symphony_plus_plus]
command = "mise"
args = ["exec", "--", "mix", "sympp.mcp", "--mode", "stdio", "--database", "<ledger-path>"]
cwd = "<repo>/elixir"
```

If the operator uses an environment-backed secret handoff, pass only the
environment variable name through MCP server configuration and keep the raw
secret out of files, logs, PR bodies, and prompts.

## Worker Claim

Workers still need to call `claim_work_key(secret, claimed_by)` after MCP
initialize. A configured `state_key` only preserves initialized handshake
continuity for stateless transports; it does not restore worker authorization.
