# Symphony++ MCP Wiring

The skill assumes the worker session has access to the Symphony++ MCP server
from this repository's Elixir implementation.

## Plugin And MCP Boundary

The installable Codex plugin is skill-only by default. Its
`plugins/symphony-plus-plus/.codex-plugin/plugin.json` manifest must not declare
`mcpServers`; generic Codex sessions, review-suite lanes, and `codex review`
calls should not start Symphony++ MCP merely because the plugin is enabled.

The default package must not include `plugins/symphony-plus-plus/.mcp.json` at
all. The sibling `plugins/symphony-plus-plus-mcp` opt-in package owns the
bundled root `.mcp.json` that uses the documented direct server-map shape.
Dedicated S++ workflows can copy or reference that package's generic
`symphony_plus_plus` HTTP server when they explicitly need it.

MCP discovery is loaded by the Codex host, not by the skill text in an
already-running thread. After refreshing the local plugin cache, restart or
reload Codex and open a new session before treating stale skill metadata as a
repo packaging failure. ValidateInstalledCache checks the packaged HTTP URL and
wrapper files only; it does not prove that the current session has hot-loaded new MCP tools. Use
`scripts/refresh-local-plugin.ps1 -ValidateInstalledCache` to prove the
installed default cache copies keep the manifest skill-only and physically omit
root `.mcp.json`, while the opt-in MCP package contains the
`symphony_plus_plus` server entry for `http://127.0.0.1:4057/mcp`.
The repo refresh script updates both the `local` cache and the manifest-version
cache so a refreshed default install has a skill-only manifest and no root
`.mcp.json`. It also repairs generated stale default cache entries in place by
removing root `.mcp.json` and stale manifest `mcpServers` startup artifacts;
reload Codex and open a new session after refresh.

Skill visibility, explicit MCP configuration, global MCP settings visibility,
and current-session tool availability are distinct. A visible skill proves
Codex loaded the skill directory. Explicit MCP configuration proves a worker
session was intentionally given a server dependency. That server may not appear
as a global MCP settings entry. Current-session tools appear only after the host
loads the MCP configuration for that session.

Start one local cockpit/daemon before launching the dedicated Codex session
that enables the opt-in MCP plugin:

```bash
mix sympp.cockpit --database <ledger-path>
```

By default it binds `127.0.0.1:4057`, prints
`http://127.0.0.1:4057/sympp/board`, and serves MCP at
`http://127.0.0.1:4057/mcp`. Pass `--port 0` for dynamic-port manual tests, or
`--port <n>` for a different explicit port. The bundled opt-in plugin targets
the stable default URL; if you use another port, configure that session
explicitly.

Starting the legacy stdio process from a shell does not register tools with an
already-running model session. S++ MCP opt-in should use a one-session top-level
MCP config, a dedicated alternate Codex config selected before launch, the
sibling `plugins/symphony-plus-plus-mcp` opt-in plugin, or a dedicated S++
agent config file. Do not add S++ MCP to generic worker, reviewer, or
review-suite configs.

The Windows desktop app has no proven per-visible-thread S++ profile picker.
App cockpit threads should use the default skill-only plugin plus Solo Session
CLI planning. When the cockpit needs heavy S++ orchestration, launch a managed
architect or worker subprocess/app-server session with explicit top-level MCP
configuration or the sibling opt-in MCP plugin before that session starts.
That managed subprocess is the supported replacement for app-visible
WorkPackage and architect execution until the desktop host can attach MCP tools
to one already-open thread. Do not invoke this MCP-dependent skill from a
generic visible app thread that does not already show S++ MCP tools; use the
Solo/cockpit handoff path instead.

The opt-in MCP package reference is intentionally generic. It should not embed raw work-key secrets or bearer tokens, private-store handoff targets, or operator-local secret material. The repo-local refresh script writes a
non-secret source-root hint into installed caches for the Solo wrapper and
legacy stdio fallback scripts, but the bundled MCP target itself is the local
HTTP daemon URL.

Plugin installation is not worker package dispatch. First-use worker sessions
should use the create-work-generated `run-mcp` private-store handoff command so
the MCP child process receives the secret only through its environment and
claims exactly one WorkPackage with the configured `claimed_by` identity.

## Local HTTP Server

Run the local daemon from `elixir/`:

```bash
mix sympp.cockpit --database <ledger-path>
```

Use `--database <path>` when the daemon must connect to a specific Symphony++
SQLite ledger instead of the default repo database.

## Codex MCP Dependency

Configure Codex to connect to the local daemon as a Streamable HTTP MCP
dependency for the worker session. The bundled opt-in plugin uses this shape:

```toml
[mcp_servers.symphony_plus_plus]
url = "http://127.0.0.1:4057/mcp"
```

## Private Store Bootstrap

For explicit stdio fallback/dev bootstrap, prefer a private-store wrapper that reads the
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
