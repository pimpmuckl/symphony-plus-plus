# Symphony++ MCP Opt-In Plugin

This package is the explicit MCP-backed companion to the default
`symphony-plus-plus` Codex plugin.

Use the default plugin for generic sessions, review-suite lanes, `codex review`,
visible desktop cockpit threads, and Solo Session planning. Use this opt-in
plugin only in a dedicated Codex config, alternate Codex home, managed
app-server session, or worker/architect subprocess where starting
`symphony_plus_plus` MCP before session startup is intentional.
The default plugin's manifest loads only the Solo Session skill; the
MCP-dependent WorkPackage and architect skills live in this opt-in package.

Do not enable this plugin in the normal global Codex config unless every
generic Codex session on that config should start Symphony++ MCP. Current Codex
host behavior can eagerly start plugin-bundled MCP servers for each enabled
plugin session.

This plugin intentionally bundles:

- `mcpServers: "./.mcp.json"` for the generic `symphony_plus_plus` HTTP server at `http://127.0.0.1:4057/mcp`.
- The WorkPackage, architect, and Solo Session skills.
- The legacy stdio MCP wrapper for explicit fallback/dev bootstrap, plus the Solo wrapper script needed after marketplace/cache packaging.

The default `symphony-plus-plus` plugin must remain skill-only and should stay
enabled broadly. This opt-in plugin is the concrete install path for sessions
that need MCP tools registered before the model starts. If the cockpit/local
daemon is not already running, MCP tools may be unavailable, but this bundled
plugin target should not spawn a per-session Elixir process.

## Activation

Enable this package only in the config/Codex home used for dedicated
Symphony++ WorkRequest or WorkPackage sessions:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName jonat-local -EnableMcpCompanion
```

The command validates that the installed companion package carries the expected
HTTP MCP manifest, creates a timestamped backup before changing an existing
`config.toml`, refuses the default `~/.codex` home, and writes only the
companion plugin table:

```toml
[plugins."symphony-plus-plus-mcp@jonat-local"]
enabled = true
```

Then restart or reload that dedicated Codex session. Plugin MCP tools are
registered at session startup; an already-open session that only loaded
`symphony-plus-plus@jonat-local` can show the default Solo skill while still
having no `symphony_plus_plus` MCP tool namespace.

From the repository root, the activation doctor explains the current state and
next action:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName jonat-local -Doctor
```

The doctor checks cache, config, and the local HTTP daemon. It cannot inspect
tools already registered inside an open Codex model session; if the doctor is
healthy but tools are still absent, restart or reload the dedicated MCP-enabled
session.

Keep this companion out of generic worker, `worker_smart`, review-suite, and
`codex review` configs so ordinary review and execution sessions stay MCP-clean.

To prove the daemon independently of Codex plugin loading, start
`mix sympp.cockpit` and run this from the source repository checkout root. This
helper is not copied into installed plugin cache directories:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1
```

Passing this smoke confirms the local HTTP MCP endpoint handshakes and exposes
the expected unbound tools. It does not confirm that a Codex app session has
loaded this opt-in plugin; reload or start that dedicated MCP-enabled session
after changing plugin config/cache state.
