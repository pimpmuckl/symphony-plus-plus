# SYMPP-V2-DOGFOOD-001 MCP Activation Evidence

Date: 2026-05-18

## Scope

This dogfood pass verified the fresh/dedicated Codex-home activation path for
the opt-in `symphony-plus-plus-mcp` package without adding global
`[mcp_servers.symphony_plus_plus]` wiring.

Dedicated Codex home used for activation:

```text
C:\Users\jonat\.codex\tmp\sympp-v2-dogfood-001-codex-home-20260518-170735
```

## Automated Evidence

| Check | Result |
| --- | --- |
| Default home baseline before the later manual plugin install | Clean: default `config.toml` existed, had no `symphony-plus-plus-mcp` plugin entry, and had no global `mcp_servers.symphony_plus_plus` entry. |
| Default-home doctor baseline | `solo_ready_mcp_companion_not_enabled`; Solo Session plugin `ready`, MCP companion installed but not enabled, no global S++ MCP entry, endpoint reachable. |
| Dedicated plugin cache refresh | Passed for `symphony-plus-plus` and `symphony-plus-plus-mcp` with installed-cache validation. |
| Dedicated-home pre-enable doctor | `config_missing`; no global S++ MCP entry, endpoint reachable, next action was companion enablement. |
| Dedicated-home enable command | Passed with `status: created_config`; wrote only the companion plugin enablement entry. |
| Dedicated-home post-enable doctor | `healthy_local_workrequest_mcp`; companion `ready`, companion plugin enabled, endpoint reachable, no global S++ MCP entry. |
| Dedicated-home config content | Exactly `[plugins."symphony-plus-plus-mcp@jonat-local"]` plus `enabled = true`. |
| Unbound HTTP MCP smoke | Passed; exposed `sympp.health`, `claim_work_key`, and the `solo_*` tools. |
| Synthetic bound worker HTTP MCP smoke | Passed against an isolated temporary ledger on port `4058`; exposed 20 bound worker tools, 9 bound resources, and 7 unbound pre-claim tools. Raw work-key material and the temporary synthetic ledger directory were removed after the smoke. |
| Doctor self-test and HTTP smoke self-test | Passed. |

The bound smoke used a local synthetic WorkPackage and a short-lived
environment variable populated from a private local file. The raw secret,
claimed MCP session id, and synthetic access-grant details are intentionally
not recorded here.

## Current Default-Home Caveat

After the baseline default-home check, the operator manually installed/enabled
the opt-in MCP package in the real default Codex home. A follow-up doctor run
then reported `default_codex_home_mcp_companion_enabled` with
`symphony-plus-plus-mcp@jonat-local` enabled and still no global
`[mcp_servers.symphony_plus_plus]` wiring.

That later state violates the generic/default-session cleanliness gate for this
package, but it was not produced by the dedicated-home activation command. The
default config should be restored to skill-only before using this evidence as a
green light for broad dogfooding.

## Tool Visibility

This already-running Codex session did not expose the `symphony_plus_plus` MCP
tools through tool discovery after plugin/cache/config changes. That is
consistent with the existing session-reload boundary: the doctor and HTTP smoke
prove cache/config/daemon readiness, but they do not prove that an already-open
Codex app session has reloaded plugin-scoped MCP servers.

The Codex in-app MCP settings list also did not show the plugin-scoped
Symphony++ server after the manual opt-in package install. Treat that UI as a
manual visibility/product follow-up, not as the source of truth for this
verification. The repeatable proof points are the dedicated config, activation
doctor, and HTTP MCP smoke scripts.

## Repeat Commands

```powershell
$dogfoodHome = "C:\path\to\dedicated-sympp-codex-home"

.\scripts\refresh-local-plugin.ps1 `
  -CodexHome $dogfoodHome `
  -MarketplaceName jonat-local `
  -ValidateInstalledCache

.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 `
  -CodexHome $dogfoodHome `
  -MarketplaceName jonat-local `
  -EnableMcpCompanion

.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 `
  -CodexHome $dogfoodHome `
  -MarketplaceName jonat-local `
  -Doctor

.\scripts\smoke-sympp-mcp-http.ps1
```

For bound worker smoke, use an isolated ledger and pass the work key only by
environment variable name:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 `
  -Url http://127.0.0.1:<port>/mcp `
  -Bound `
  -WorkKeySecretEnv SYMPP_WORK_KEY_SECRET `
  -ClaimedBy <stable-worker-id>
```

## DOGFOOD-002 Readiness

The activation path, daemon path, and bound worker MCP surface are proven from
a dedicated home. DOGFOOD-002 should wait until the real default Codex home is
restored to skill-only/default-clean or the architect explicitly accepts that
manual contamination as out of scope.
