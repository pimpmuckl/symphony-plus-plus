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

Example shape for an already-bound or non-secret local smoke test:

```toml
[mcp_servers.symphony_plus_plus]
command = "mise"
args = ["exec", "--", "mix", "sympp.mcp", "--mode", "stdio", "--database", "<ledger-path>"]
cwd = "<repo>/elixir"
```

## Private Store Bootstrap

For first-use worker dispatch, prefer a private-store wrapper that reads the
one-time secret from the local OS/user store, injects it only into the MCP child
process environment, and starts `sympp.mcp` with both the environment variable
name and the stable worker identity.

Windows Credential Manager example:

```toml
[mcp_servers.symphony_plus_plus]
command = "powershell"
args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<repo>/scripts/sympp-worker-secret.ps1", "run-mcp", "-Target", "<handoff-target>", "-Database", "<ledger-path>", "-ClaimedBy", "<stable-worker-id>"]
cwd = "<repo>"
```

Non-Windows `local-private-file` fallback example:

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
