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

1. The marketplace package pins a release channel and plugin version, and may
   include source revision metadata for diagnostics.
2. The launcher resolves the host platform and CPU architecture.
3. The launcher loads the artifact manifest for the pinned channel/version.
4. The launcher selects exactly one installed-user artifact whose platform
   tuple, plugin identity/version, and MCP contract fingerprint match this
   package.
5. The launcher downloads or reads the archive from the manifest location.
6. The launcher computes SHA-256 over the archive bytes before extraction.
7. The launcher extracts into the Symphony++ runtime home under a directory
   keyed by artifact version, platform, available source revision metadata, and
   archive SHA-256.
8. The launcher starts the expected runtime command from the extracted payload,
   starts or serves the packaged dashboard assets, and records runtime state
   under `$HOME/.agents/splusplus/runtime/` unless `SYMPP_RUNTIME_FILE`
   overrides it.
9. If verification fails, no extracted payload is started. The operator sees a
   diagnostic that names the channel, manifest version, selected platform,
   expected SHA-256, actual SHA-256 when available, cache path, and next action.

Artifact extraction must be idempotent. A previously extracted payload can be
reused only when its recorded platform, archive SHA-256, expected runtime
command, dashboard asset fingerprint, and available source revision metadata
still match the selected manifest entry.

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
  "mcp_contract_fingerprint": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
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
      "mcp_contract_fingerprint": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
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
- `plugin.name` and `plugin.version`: marketplace package identity the manifest
  applies to.
- `plugin.source_revision`: optional package-visible revision metadata used for
  diagnostics, cache identity, and developer/source-checkout validation.
- `mcp_contract_fingerprint`: MCP contract fingerprint expected by the
  launcher and implemented by the artifact runtime.
- `release.channel`: channel consumed by the marketplace entry.
- `release.manifest_version`: monotonically advancing release manifest id.
- `release.source_revision`: optional source commit used to build every
  artifact in this manifest.
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

## Artifact Identity Metadata

Installed packages expose the package source revision with the existing
non-secret `.sympp-source-revision` marker written beside the plugin payload
during local refresh/marketplace cache publication when that revision is known.
The launcher may also read manifest-equivalent package metadata from a
marketplace install record when the host provides one.

For normal installed marketplace users, source revision is not the compatibility
boundary. Installed artifact selection is valid when plugin name, plugin
version, platform, and MCP contract fingerprint match, and archive/dashboard
verification succeeds. Source revision metadata remains useful for cache
identity, diagnostics, provenance, and developer/source-checkout validation, but
a missing or different raw git SHA must not reject a verified installed-user
artifact by itself.

For source-checkout and explicit developer artifact validation paths, source
revision checks may remain strict so local artifacts cannot silently mask
checkout drift.

## Release-Channel Gating

A marketplace-visible plugin version must not advance ahead of its runtime
artifacts. Release automation should publish or expose a channel entry only
after all `release.required_platforms` artifacts exist and pass validation for
the plugin version and MCP contract fingerprint being published.

Minimum channel gate:

- Build each supported platform artifact from the same source revision.
- Build static dashboard assets into the artifact; do not rely on Vite dev
  startup for installed users.
- Compute and record archive SHA-256 after the final archive is produced.
- Smoke the runtime command from the extracted archive.
- Smoke the local HTTP MCP handshake and dashboard route from the artifact.
- Verify the artifact declares the plugin version and MCP contract fingerprint
  expected by the package.
- Verify the marketplace package points to a channel entry whose artifacts cover
  every `release.required_platforms` entry.

If any required platform is missing or fails validation, the channel remains on
the previous manifest. New source commits can still be tested from source
checkouts, but they are not marketplace-visible installed-runtime updates.

## GitHub Release Publication

The PR/main workflow `.github/workflows/sympp-runtime-artifact.yml` is a
validation workflow. It builds per-platform runtime packages, validates each
local manifest, and uploads short-lived GitHub Actions artifacts for inspection.
Those Actions artifact URLs are not the release channel.

The release workflow `.github/workflows/sympp-runtime-release.yml` is the
durable publication lane. It runs on runtime release tags or manual dispatch,
builds `linux-x64`, `windows-x64`, and `macos-arm64` from one source revision,
  smokes the extracted artifact runtime with an explicit runtime-safe workflow,
  MCP health, and dashboard route on each platform, uploads each package and
  per-platform build manifest as GitHub Release assets, then writes an aggregate
  channel manifest such as
`sympp-runtime-artifacts-stable.json` and uploads it to the same release.

The installed MCP plugin carries
`assets/sympp-runtime-artifacts.json` as the stable channel pointer. That file
references the durable `sympp-runtime-stable` GitHub Release asset, so a normal
marketplace package has a launcher-discoverable channel without changing
launcher lookup policy. Publishing the stable channel should use manual dispatch
with `release_tag=sympp-runtime-stable` and `channel=stable`. If that stable
tag does not exist yet, set `source_ref` to the branch or SHA to build; when
`source_ref` is omitted, manual dispatch builds the requested `release_tag`.
Versioned tag builds still emit their own aggregate manifest on that tag for
inspection or explicit pinning.

The aggregate manifest is the launcher-consumable channel document. It includes:

- `plugin.name`, `plugin.version`, `plugin.marketplace`, and
  `plugin.source_revision`.
- `release.channel`, `release.manifest_version`, `release.source_revision`,
  `release.repository`, `release.tag`, `release.published_base_url`, and
  `release.required_platforms`.
- `launcher_contract.mcp_contract_fingerprint` and `contract_fingerprint` for
  the MCP contract expected by the installed launcher.
- One `artifacts[]` entry per required platform with a normalized platform
  tuple, durable GitHub Release archive URL, archive SHA-256, archive size,
  per-platform build manifest URL and SHA-256, runtime command metadata,
  dashboard asset root and fingerprint, and explicit fallback policy.

Release artifacts must not package
`implementation_docs_symphplusplus/templates/WORKFLOW.symfony_pp.md` as
`WORKFLOW.md`. That template is an explicit-copy operator starting point with
placeholders, not an installed-runtime default. Artifact MCP startup does not
require a workflow file. If a real workflow is supplied through
`SYMPP_WORKFLOW_FILE`, runtime arguments, or a source checkout fallback that has
its own `elixir/WORKFLOW.md`, the runtime may use it for legacy daemon paths.

The publisher refuses to write the aggregate manifest unless every required
platform manifest is present, every package exists locally, every local archive
hash matches its per-platform build manifest, all artifacts share one source
revision, all artifacts share one plugin identity, all artifacts share one MCP
contract fingerprint from their build manifests, and the dashboard fingerprint
required by the launcher is present. The generated aggregate shape uses the
existing `artifacts[]` manifest contract and can be consumed by the current
launcher helpers when placed at
`.sympp-runtime-artifacts.json`, `assets/sympp-runtime-artifacts.json`, or
another marketplace-visible manifest location that resolves to the same JSON.

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
  MCP contract fingerprint, or platform.
- `artifact_checksum_mismatch`: archive bytes do not match manifest SHA-256.
- `artifact_runtime_failed`: verified payload failed runtime startup or health.
- `artifact_dashboard_missing`: runtime started but expected static dashboard
  assets are missing or fingerprint mismatched.
- `source_checkout_fallback`: launcher intentionally used source compilation
  instead of a verified artifact.
- `channel_not_ready`: marketplace/plugin version is ahead of the latest
  validated channel entry.

Diagnostics must name non-secret paths, versions, available revisions, platform
tuple, channel, manifest version, selected archive location, runtime file, log
locations, and recommended next action. They must not print bearer tokens,
GitHub tokens, MCP auth tokens, worker secrets, or secret-bearing command lines.

## Non-Goals And Open Questions

Non-goals for this contract slice:

- Implementing launcher artifact download, extraction, or runtime startup.
- Changing launcher artifact selection policy.
- Adding artifact signing beyond SHA-256 verification.
- Changing global Codex config behavior.
- Changing MCP tool schemas or dashboard product behavior.

Open questions for later product or release slices:

- Artifact retention and rollback policy.
- Whether signatures are required in addition to SHA-256.
- Whether emergency installed-user source fallback should exist, and what
  explicit operator switch would enable it.
