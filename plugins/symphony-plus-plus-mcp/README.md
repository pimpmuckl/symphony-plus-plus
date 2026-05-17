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
