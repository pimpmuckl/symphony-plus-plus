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
already-running thread. During feature-branch development, do not refresh or
sync user-local plugin caches just to test repo skill edits; local
cache/plugin adoption happens only at final feature-branch cutover. After that
cutover, restart or reload Codex and open a new session before treating stale
skill metadata as a repo packaging failure.

Skill visibility, explicit MCP configuration, global MCP settings visibility,
and current-session tool availability are distinct. A visible skill proves
Codex loaded the skill directory. Explicit MCP configuration proves a worker
session was intentionally given a server dependency. That server may not appear
as a global MCP settings entry. Current-session tools appear only after the host
loads the MCP configuration for that session.

Start one local cockpit/daemon before launching the dedicated Codex session
that enables the opt-in MCP plugin:

```bash
mix sympp.cockpit
```

By default it binds `127.0.0.1:4057`, prints
`http://127.0.0.1:4057/sympp/board`, and serves MCP at
`http://127.0.0.1:4057/mcp`, backed by the default local ledger. The preferred
home is
`$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`
(`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows);
if that home is unavailable, Symphony++ falls back under a temp/relative
`.agents/splusplus` root. Pass
`--port 0` for dynamic-port manual tests, or `--port <n>` for a different
explicit port. The bundled opt-in plugin targets the stable default URL; if you
use another port, configure that session explicitly.

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

The opt-in MCP package reference is intentionally generic. It should not embed
raw work-key secrets or bearer tokens, private-store handoff targets, or
operator-local secret material. Repo-local refresh scripts update installed
caches only during final cutover or explicit manual cache maintenance; they
write a non-secret source-root hint for the Solo wrapper and legacy stdio
fallback scripts. The bundled MCP target itself is the local HTTP daemon URL.
Do not refresh user-local plugin caches as part of normal feature-branch
worker dispatch.

Plugin installation is not worker package dispatch. Normal V2.1 worker dispatch
emits a `worker_bootstrap` payload with `type: ledger_claim`, `mode:
local_assignment`, and `claim.tool: claim_local_assignment`. The worker uses
that ledger-backed claim plus local runtime `branch`, `worktree_path`, and
`caller_id` values to bind exactly one WorkPackage. Do not ask for private
handoff metadata or a raw work key unless the assignment is explicitly marked
legacy/recovery.

## Local HTTP Server

Run the local daemon from `elixir/`:

```bash
mix sympp.cockpit
```

Use `--database <path>` only when the daemon must connect to a specific
isolated Symphony++ SQLite ledger instead of the default local ledger.

## Codex MCP Dependency

Configure Codex to connect to the local daemon as a Streamable HTTP MCP
dependency for the worker session. The bundled opt-in plugin uses this shape:

```toml
[mcp_servers.symphony_plus_plus]
url = "http://127.0.0.1:4057/mcp"
```

This URL-only shape is enough only when the Codex host owns a persistent MCP
session and preserves the returned `Mcp-Session-Id`/state key across
`initialize`, `tools/list`, claim, and follow-up calls. Stateless one-shot URL
probes may prove health, but they are not normal worker-claim sessions and
must not be expected to advertise or authorize `claim_local_assignment`.

## Legacy/Recovery Bootstrap

For explicit stdio fallback/dev recovery, prefer a private-store wrapper that
reads the one-time secret from the local OS/user store, injects it only into
the MCP child process environment, and starts `sympp.mcp` with both the
environment variable name and the stable worker identity. This path exists for
legacy recovery until final cutover; it is not the normal ledger-backed worker
claim path.

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

For one-shot diagnostics, do not run the long-lived stdio server under a parent
that waits for exit before draining stdout. Claimed architect/worker
`tools/list` responses can be large enough to fill the pipe. Use the spooling
mode instead: `run-mcp-local-file-once -InputFile <jsonl> -OutputFile <jsonl>`
on Windows, or `run-mcp-local-file-once --input-file <jsonl> --output-file
<jsonl>` on non-Windows. Caller-supplied output/error files must not already
exist. The secret still stays in the child process environment only, and the
wrapper prints only a small JSON summary.

## Worker Claim

Workers start by calling `claim_local_assignment` in the dedicated local HTTP
MCP session that preserves `Mcp-Session-Id`/state-key continuity. Pass the
dispatch-provided claim fields and local runtime `branch`, `worktree_path`,
`caller_id`, and `claimed_by` when needed. Then call
`get_current_assignment()` and read package context.

Replaying the same claim heartbeats the current claim lease. If the prior lease
is stale, the server may reclaim it and records audit evidence. If the lease is
paused, the worktree scope mismatches, or another active owner still has
authority, stop and ask the architect/operator to repair that state. A
configured `state_key` only preserves initialized handshake continuity for
stateless transports; it does not restore worker authorization by itself.
