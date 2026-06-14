# Marketplace Runtime Artifact Contract

This contract defines the target installed-runtime behavior for the
`symphony-plus-plus-mcp` marketplace package. It is a product and release
contract for later implementation slices, not evidence that the current launcher
already consumes release artifacts.

## Product Goal

Normal marketplace-installed MCP sessions should start from a verified runtime
artifact instead of compiling the Elixir/Phoenix/Vite source tree on first
startup. The installed plugin remains a small Codex package containing skills,
the MCP manifest, launcher scripts, and artifact-resolution logic. The runtime
payload is a release artifact selected by manifest, verified before use, and
kept separate from developer source-checkout fallback paths.

The default `symphony-plus-plus` plugin remains MCP-free. Only the opt-in
`symphony-plus-plus-mcp` package participates in this installed-runtime
contract.

## Installed Runtime Flow

1. The marketplace package pins a release channel, plugin version, and source
   revision marker.
2. The launcher resolves the host platform and CPU architecture.
3. The launcher loads the artifact manifest for the pinned channel/version.
4. The launcher selects exactly one artifact whose platform tuple matches the
   host and whose source revision matches the package source revision marker.
5. The launcher downloads or reads the archive from the manifest location.
6. The launcher computes SHA-256 over the archive bytes before extraction.
7. The launcher extracts into the Symphony++ runtime home under a directory
   keyed by artifact version, platform, source revision, and archive SHA-256.
8. The launcher starts the expected runtime command from the extracted payload,
   starts or serves the packaged dashboard assets, and records runtime state
   under `$HOME/.agents/splusplus/runtime/` unless `SYMPP_RUNTIME_FILE`
   overrides it.
9. If verification fails, no extracted payload is started. The operator sees a
   diagnostic that names the channel, manifest version, selected platform,
   expected SHA-256, actual SHA-256 when available, cache path, and next action.

Artifact extraction must be idempotent. A previously extracted payload can be
reused only when its recorded source revision, platform, archive SHA-256,
expected runtime command, and dashboard asset fingerprint still match the
selected manifest entry.

## Manifest Shape

The manifest is immutable for a published marketplace-visible version. Later
corrections publish a new manifest version or release-channel entry instead of
mutating an already-visible manifest.

```json
{
  "schema_version": 1,
  "plugin": {
    "name": "symphony-plus-plus-mcp",
    "version": "0.1.6",
    "source_revision": "0123456789abcdef0123456789abcdef01234567"
  },
  "release": {
    "channel": "stable",
    "manifest_version": "2026.06.13.1",
    "source_revision": "0123456789abcdef0123456789abcdef01234567",
    "required_platforms": [
      {"os": "windows", "arch": "x86_64", "abi": "msvc"}
    ]
  },
  "artifacts": [
    {
      "platform": {
        "os": "windows",
        "arch": "x86_64",
        "abi": "msvc"
      },
      "archive": {
        "url": "https://example.invalid/symphony-plus-plus/0.1.6/windows-x86_64-msvc.zip",
        "path": null,
        "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      "runtime": {
        "command": "bin/symphony_plus_plus_server.bat",
        "args": ["--mcp-http", "--dashboard-assets", "priv/static/dashboard"],
        "mcp_path": "/mcp",
        "health_path": "/health"
      },
      "dashboard": {
        "asset_root": "priv/static/dashboard",
        "entrypoint": "index.html",
        "fingerprint": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      "fallback": {
        "developer_source_compile": "allowed_with_explicit_source_checkout",
        "installed_user_source_compile": "disabled_by_default"
      }
    }
  ]
}
```

Required manifest fields:

- `schema_version`: manifest parser version.
- `plugin.name`, `plugin.version`, and `plugin.source_revision`: marketplace
  package identity the manifest applies to. `plugin.source_revision` is the
  package-visible revision marker.
- `release.channel`: channel consumed by the marketplace entry.
- `release.manifest_version`: monotonically advancing release manifest id.
- `release.source_revision`: exact source commit used to build every artifact
  in this manifest.
- `release.required_platforms`: platform tuples that must have validated
  artifacts before this manifest can advance the release channel.
- `artifacts[].platform.os`: normalized operating-system id.
- `artifacts[].platform.arch`: normalized CPU architecture.
- `artifacts[].platform.abi`: ABI or runtime-family discriminator when needed.
- `artifacts[].archive.url` or `artifacts[].archive.path`: exactly one archive
  location. `url` is for hosted releases; `path` is for local test fixtures and
  operator-controlled dry runs.
- `artifacts[].archive.sha256`: lowercase hex SHA-256 of the archive bytes.
- `artifacts[].runtime.command`: command inside the extracted archive that
  starts the local HTTP MCP runtime.
- `artifacts[].runtime.args`: default arguments needed for MCP/dashboard mode.
- `artifacts[].runtime.mcp_path` and `health_path`: local HTTP endpoints the
  launcher validates after startup.
- `artifacts[].dashboard.asset_root`: static dashboard asset directory inside
  the extracted payload.
- `artifacts[].dashboard.entrypoint`: dashboard HTML entrypoint.
- `artifacts[].dashboard.fingerprint`: content fingerprint for the static asset
  set.
- `artifacts[].fallback`: explicit source-compile fallback policy for installed
  users and developers.

Optional future fields may describe signatures, retention windows, or alternate
mirrors. They are non-goals for this slice until the architect records a hosted
release and signing decision.

## Package Revision Metadata

Installed packages expose the package source revision with the existing
non-secret `.sympp-source-revision` marker written beside the plugin payload
during local refresh/marketplace cache publication. The launcher may also read
manifest-equivalent package metadata from a marketplace install record when the
host provides one, but it must normalize both paths into the same
`plugin.source_revision` value before selecting an artifact.

The selected artifact manifest is valid only when
`plugin.source_revision == release.source_revision` and the selected artifact
was built from that same revision. If no package source revision is available,
the launcher must diagnose `channel_not_ready` or an equivalent missing-revision
state instead of falling back to git state from an arbitrary checkout.

## Release-Channel Gating

A marketplace-visible plugin version must not advance ahead of its runtime
artifacts. Release automation should publish or expose a channel entry only
after all `release.required_platforms` artifacts exist and pass validation for
that exact source revision.

Minimum channel gate:

- Build each supported platform artifact from the same source revision.
- Build static dashboard assets into the artifact; do not rely on Vite dev
  startup for installed users.
- Compute and record archive SHA-256 after the final archive is produced.
- Smoke the runtime command from the extracted archive.
- Smoke the local HTTP MCP handshake and dashboard route from the artifact.
- Verify manifest source revision equals the package source revision marker.
- Verify the marketplace package points to a channel entry whose artifacts cover
  every `release.required_platforms` entry.

If any required platform is missing or fails validation, the channel remains on
the previous manifest. New source commits can still be tested from source
checkouts, but they are not marketplace-visible installed-runtime updates.

## Installed Behavior vs Developer Fallback

Normal installed behavior:

- Prefer the verified artifact selected by manifest.
- Reuse an extracted artifact only when its recorded verification metadata
  still matches the selected manifest.
- Start the runtime command shipped inside the artifact.
- Serve dashboard assets from the artifact.
- Keep dependency installation and source compilation off the normal first
  startup path.

Developer fallback:

- Source checkout compilation remains available for local development,
  dogfooding, and emergency diagnostics.
- Fallback requires an explicit source checkout path from the current source
  tree, marketplace source clone, or operator override such as `SYMPP_REPO_ROOT`.
- Fallback must be reported as source-checkout mode in runtime diagnostics.
- Fallback does not satisfy the marketplace-installed artifact contract and
  should not be used as release-channel evidence.

Installed-user source compilation is disabled by default. A future emergency
override may allow source fallback, but it must be opt-in, clearly diagnosed,
and never silently mask missing or unverifiable artifacts.

## Static Dashboard Expectations

Marketplace artifacts include production-built dashboard assets. Installed
launchers should not run `npm install` or Vite dev server as the default
dashboard path. The runtime may serve the static dashboard directly, or the
launcher may serve the extracted asset root through a lightweight local static
server. In both cases, diagnostics should identify the dashboard asset root and
fingerprint used for the current runtime.

Developer source checkouts may continue using Vite for live dashboard work.
That mode is separate from the installed artifact path.

## Operator Diagnostics

Existing diagnostics such as `diagnose-mcp-lifecycle.ps1`, launcher validation,
runtime state, and MCP health should distinguish these states:

- `artifact_ready`: selected artifact exists, SHA-256 matches, extracted
  payload metadata matches, runtime command starts, and dashboard assets are
  present.
- `artifact_missing`: no manifest entry exists for the plugin version, channel,
  source revision, or platform.
- `artifact_checksum_mismatch`: archive bytes do not match manifest SHA-256.
- `artifact_runtime_failed`: verified payload failed runtime startup or health.
- `artifact_dashboard_missing`: runtime started but expected static dashboard
  assets are missing or fingerprint mismatched.
- `source_checkout_fallback`: launcher intentionally used source compilation
  instead of a verified artifact.
- `channel_not_ready`: marketplace/plugin version is ahead of the latest
  validated channel entry.

Diagnostics must name non-secret paths, versions, revisions, platform tuple,
channel, manifest version, selected archive location, runtime file, log
locations, and recommended next action. They must not print bearer tokens,
GitHub tokens, MCP auth tokens, worker secrets, or secret-bearing command lines.

## Non-Goals And Open Questions

Non-goals for this contract slice:

- Implementing launcher artifact download, extraction, or runtime startup.
- Adding CI workflows or hosted release publication.
- Choosing a hosted release location, retention policy, or signing mechanism.
- Changing global Codex config behavior.
- Changing MCP tool schemas or dashboard product behavior.

Open questions for later product or release slices:

- Hosted artifact location and access pattern.
- Artifact retention and rollback policy.
- Whether signatures are required in addition to SHA-256.
- Exact supported platform matrix for the first artifact-backed release
  manifest.
- Whether emergency installed-user source fallback should exist, and what
  explicit operator switch would enable it.
