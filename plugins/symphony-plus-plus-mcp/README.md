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
  launcher. Each plugin MCP process is a lightweight stdio bridge into a local
  HTTP runtime. The launcher reuses a healthy backend/dashboard when MCP health
  reports the same exact `source_revision` as the launcher-resolved commit,
  starts a new managed runtime for a new commit, and lets older managed
  runtimes drain until their bridge leases exit. The launcher installs
  dashboard npm dependencies into the selected source tree when Vite is missing,
  then bridges Codex stdio MCP traffic into the backend HTTP `/mcp` endpoint.
- The same `assets/splusplus-logo.png` icon used by the default Symphony++ plugin.
- `assets/sympp-runtime-artifacts.json`, a stable release-channel pointer for
  prebuilt installed-runtime artifacts.
- The MCP-mode Solo Session, worker, coordinator, architect, and WorkPackage skills.
- The local MCP launcher plus the Solo wrapper script needed after marketplace/cache packaging.
  The launcher discovers the full Codex marketplace source clone automatically,
  so normal marketplace installs do not require users to set `SYMPP_REPO_ROOT`.

The installed-runtime contract lives in the source repository operator docs as
`17_RUNTIME_ARTIFACT_CONTRACT.md`. It defines the verified artifact path,
release-channel gate, manifest fields, static dashboard expectations,
source-checkout fallback semantics, and diagnostics. Installed plugin cache
copies of this README are self-contained and include the stable channel pointer
used by the launcher artifact lookup path.

The default `symphony-plus-plus` plugin must remain skill-only and should stay
enabled broadly for non-MCP work. Dedicated MCP homes should enable this
companion plugin instead of the default plugin so the session has the full MCP
skill set and the `symphony_plus_plus` tool namespace from one package. Do not
enable both packages in the same Codex home unless you intentionally want both
skill prefixes visible. Codex starts this companion as a quiet stdio process;
background backend/frontend logs are redirected under the local runtime log
directory instead of streaming through every MCP call.

## Activation

Install this package only from the Codex home used for dedicated Symphony++
WorkRequest or WorkPackage sessions:

```powershell
codex plugin add symphony-plus-plus-mcp@symphony-plus-plus
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

The doctor checks cache, config, command-backed launcher shape, and package
fingerprints against the Codex marketplace snapshot. It cannot inspect tools
already registered inside an open Codex model session; if the doctor is healthy
but tools are still absent, restart or reload the dedicated MCP-enabled session.

Keep this companion out of generic worker, `worker_smart`, review-suite, and
`codex review` configs so ordinary review and execution sessions stay MCP-clean.

When an installed dedicated Codex session starts, the launcher prefers the
compatible marketplace source clone that matches the installed MCP plugin
payload. Installed plugin launchers ignore local source-root hints; use
`codex plugin marketplace upgrade` to change the installed runtime payload. When the launcher starts, it writes the actual backend
port, dashboard URL, process ids, and log paths to
`%USERPROFILE%\.agents\splusplus\runtime\codex-plugin.json` by default.
Override with `SYMPP_RUNTIME_FILE`, `SYMPP_BACKEND_PORT`,
`SYMPP_DASHBOARD_PORT`, `SYMPP_BACKEND_URL`, or `SYMPP_DASHBOARD_ORIGIN` when a
specific local setup needs to divert. Runtime identity is the agent-facing MCP
contract fingerprint plus the backend and dashboard endpoints. New Codex
sessions attach to a healthy matching runtime; if the running runtime exposes an
incompatible MCP contract, the launcher starts a new managed runtime and records
new leases against that runtime key. When the last bridge lease for a runtime
key exits, the launcher stops only managed backend/frontend PIDs for that key
that it can still verify as Symphony++ processes. A healthy default-port
backend/dashboard pair on
`127.0.0.1:19998` and `127.0.0.1:19999` that reports the same agent-facing MCP
contract fingerprint as the launcher is recorded as `external_loopback` when it
was not started by the bridge. The source revision remains in health and
runtime-state diagnostics, but it is not the reuse boundary when the MCP
contract is compatible. That mode is intentionally attach-only: bridge exits
must not stop the backend or dashboard, but later launches may reuse it quickly
and prune stale managed runtime records around it. Explicit `SYMPP_BACKEND_URL` and
`SYMPP_DASHBOARD_ORIGIN` targets are external, remain operator-owned, and are
not promoted into later implicit reuse.

To prove the daemon independently of Codex plugin loading, run this from the
source repository checkout root after the launcher or `mix sympp.cockpit` is
running. This helper is not copied into installed plugin cache directories:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

Passing this smoke confirms the local HTTP MCP endpoint handshakes, exposes the
expected unbound tools, and reports source diagnostics for the checkout. It
does not confirm that a Codex app session has loaded this opt-in plugin or the
latest skill Markdown; refresh the local plugin cache, then reload or start
that dedicated MCP-enabled session after changing plugin config, cache state,
or skill files. If the smoke reports `stale_or_unverified_daemon` or
`stale_daemon_source_revision_mismatch`, an old manual cockpit may still own
the port. Dedicated plugin launchers reuse untracked local backends only when
their MCP health reports the same agent-facing contract fingerprint; source
revision mismatches are emitted as diagnostics. Dashboards are reused from
recorded managed state or explicit `SYMPP_DASHBOARD_ORIGIN`, otherwise a new
managed dashboard is started on an available port only when the reused backend
source matches the launcher source. Set
`SYMPP_BACKEND_URL` or `SYMPP_DASHBOARD_ORIGIN` only when you intentionally want
to reuse an operator-owned external process.
