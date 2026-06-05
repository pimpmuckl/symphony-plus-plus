# Symphony++ MCP Opt-In Plugin

This package is the explicit MCP-backed companion to the default
`symphony-plus-plus` Codex plugin. It is the complete MCP-mode plugin for
dedicated Symphony++ WorkRequest and WorkPackage sessions.

Use the default plugin for generic sessions, review-suite lanes, `codex review`,
visible desktop cockpit threads, and MCP-free planning. Use this opt-in
plugin only in a dedicated Codex config, alternate Codex home, managed
app-server session, or worker/architect subprocess where starting
`symphony_plus_plus` MCP before session startup is intentional. In MCP mode,
this package provides the full skill set under the `symphony-plus-plus-mcp:`
prefix: Solo Session, worker, coordinator, WorkPackage, and architect.

Do not enable this plugin in the normal global Codex config unless every
generic Codex session on that config should start Symphony++ MCP. Current Codex
host behavior can eagerly start plugin-bundled MCP servers for each enabled
plugin session.

This plugin intentionally bundles:

- `mcpServers: "./.mcp.json"` for a command-backed `symphony_plus_plus`
  launcher. On first Codex bridge startup it starts fresh managed local backend
  and dashboard processes, using `127.0.0.1:19998` and `127.0.0.1:19999` when
  available and safe fallback ports when another process owns the defaults.
  While another Codex bridge lease is active, later bridge processes reuse the
  recorded managed runtime. The launcher installs dashboard npm dependencies
  into the selected source tree when Vite is missing, then bridges Codex stdio
  MCP traffic into the backend HTTP `/mcp` endpoint.
- The same `assets/splusplus-logo.png` icon used by the default Symphony++ plugin.
- The MCP-mode Solo Session, worker, coordinator, architect, and WorkPackage skills.
- The local MCP launcher plus the Solo wrapper script needed after marketplace/cache packaging.
  The launcher discovers the full Codex marketplace source clone automatically,
  so normal marketplace installs do not require users to set `SYMPP_REPO_ROOT`.

The default `symphony-plus-plus` plugin must remain skill-only and should stay
enabled broadly for non-MCP work. Dedicated MCP homes should enable this
companion plugin instead of the default plugin so the session has the full MCP
skill set and the `symphony_plus_plus` tool namespace from one package. Do not
enable both packages in the same Codex home unless you intentionally want both
skill prefixes visible. Codex starts this companion as a quiet stdio process;
background backend/frontend logs are redirected under the local runtime log
directory instead of streaming through every MCP call.

## Activation

Enable this package only in the config/Codex home used for dedicated
Symphony++ WorkRequest or WorkPackage sessions:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
```

The command validates that the installed companion package carries the expected
command-backed MCP manifest, creates a timestamped backup before changing an existing
`config.toml`, refuses the default `~/.codex` home, and writes only the
companion plugin table:

```toml
[plugins."symphony-plus-plus-mcp@symphony-plus-plus"]
enabled = true
```

Then restart or reload that dedicated Codex session. Plugin MCP tools are
registered at session startup; an already-open session that only loaded
`symphony-plus-plus@symphony-plus-plus` can show the default Solo skill while still
having no `symphony_plus_plus` MCP tool namespace.

From the repository root, the activation doctor explains the current state and
next action:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

The doctor checks cache, config, and the command-backed launcher shape. It
cannot inspect tools already registered inside an open Codex model session; if
the doctor is healthy but tools are still absent, restart or reload the
dedicated MCP-enabled session.

Keep this companion out of generic worker, `worker_smart`, review-suite, and
`codex review` configs so ordinary review and execution sessions stay MCP-clean.

When the dedicated Codex session starts, the launcher writes the actual backend
port, dashboard URL, process ids, and log paths to
`%USERPROFILE%\.agents\splusplus\runtime\codex-plugin.json` by default.
Override with `SYMPP_RUNTIME_FILE`, `SYMPP_BACKEND_PORT`,
`SYMPP_DASHBOARD_PORT`, `SYMPP_BACKEND_URL`, or `SYMPP_DASHBOARD_ORIGIN` when a
specific local setup needs to divert. The normal lifecycle is deliberately
simple: fresh managed servers on Codex startup, reuse only while at least one
Codex bridge lease is alive, and shutdown after the last bridge exits. When the
last bridge lease exits, the launcher stops only managed backend/frontend PIDs
that it recorded, including managed PIDs superseded by a newer backend/dashboard
plan, and can still verify as Symphony++ processes. Explicit `SYMPP_BACKEND_URL`
and `SYMPP_DASHBOARD_ORIGIN` targets are external and remain operator-owned.

To prove the daemon independently of Codex plugin loading, run this from the
source repository checkout root after the launcher or `mix sympp.cockpit` is
running. This helper is not copied into installed plugin cache directories:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

Passing this smoke confirms the local HTTP MCP endpoint handshakes and exposes
the expected unbound tools from the same source revision as the checkout. It
does not confirm that a Codex app session has loaded this opt-in plugin or the
latest skill Markdown; refresh the local plugin cache, then reload or start
that dedicated MCP-enabled session after changing plugin config, cache state,
or skill files. If the smoke reports `stale_or_unverified_daemon` or
`stale_daemon_source_revision_mismatch`, an old manual cockpit may still own
the port. Dedicated plugin launchers avoid untracked local listeners for
automatic reuse and pick a fallback port when the default is occupied. Set
`SYMPP_BACKEND_URL` or `SYMPP_DASHBOARD_ORIGIN` only when you intentionally want
to reuse an operator-owned external process.
