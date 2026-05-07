# Symphony++ Codex Plugin

This plugin exposes the `symphony-work-package` skill as a local Codex plugin.
The canonical source for the runtime remains this repository; the plugin cache
under `~/.codex/plugins/cache/...` is generated install state.

## Install

Point a Codex marketplace entry at this directory:

```json
{
  "name": "symphony-plus-plus",
  "source": {
    "source": "local",
    "path": "./plugins/symphony-plus-plus"
  },
  "policy": {
    "installation": "AVAILABLE",
    "authentication": "ON_USE"
  },
  "category": "Coding"
}
```

The committed repo marketplace at `.agents/plugins/marketplace.json` uses the
repo-root-relative source path `./plugins/symphony-plus-plus`.

Then enable the plugin with the active marketplace name:

```toml
[plugins."symphony-plus-plus@jonat-local"]
enabled = true
```

After changing plugin-facing files, refresh the local plugin cache from the
repository root:

```powershell
.\scripts\refresh-local-plugin.ps1
```

Restart or reload Codex so the refreshed skill list is loaded.

Worker-secret bootstrap metadata is emitted by `mix sympp.create_work` after it
stores the one-time secret in a private local store. On Windows, generated
commands use `scripts/sympp-worker-secret.ps1` for Windows Credential Manager.
`local-private-file` is a non-Windows fallback and uses
`scripts/sympp-worker-secret.sh` to read the private file and start the MCP child
process without printing the secret.
