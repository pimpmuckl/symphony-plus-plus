param(
  [switch]$Help,
  [switch]$ValidateOnly,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$DefaultBackendPort = 19998
$DefaultDashboardPort = 19999
$BoardPath = "/sympp/board"
$ExpectedMcpContractFingerprint = "7111fb1508842226fc973a7f5b4a575326fc8729fd68263401fe7bdeb8124980"

. (Join-Path $PSScriptRoot "sympp-launcher-runtime.ps1")
. (Join-Path $PSScriptRoot "sympp-mcp-launcher-helpers.ps1")

function Write-Usage {
  Write-Host "Starts the Symphony++ Codex plugin MCP bridge and local operator servers."
  Write-Host ""
  Write-Host "Default behavior:"
  Write-Host "  - Reuse a healthy Symphony++ runtime when its MCP contract fingerprint matches this launcher."
  Write-Host "  - Keep source revision mismatches visible in diagnostics while allowing compatible runtimes to attach."
  Write-Host "  - Start a fresh managed backend and dashboard for a new MCP contract, leaving old leased runtimes to drain."
  Write-Host "  - Bridge Codex stdio MCP traffic into the HTTP backend /mcp endpoint."
  Write-Host ""
  Write-Host "Environment:"
  Write-Host "  SYMPP_REPO_ROOT              Explicit developer-only Symphony++ source checkout override. Marketplace installs are discovered automatically."
  Write-Host "  SYMPP_DATABASE               Optional SQLite ledger override passed to mix sympp.cockpit and mix sympp.mcp direct fallback."
  Write-Host "  SYMPP_LAUNCHER               Optional launcher: 'direct' or 'mise'. Defaults to 'mise' when elixir/mise.toml can run through mise; otherwise 'direct'."
  Write-Host "  SYMPP_MIX                    Optional mix executable path or name for direct launcher. Defaults to 'mix'."
  Write-Host "  SYMPP_MISE                   Optional mise executable path or name for mise launcher. Defaults to 'mise'."
  Write-Host "  MIX_BUILD_ROOT               Optional Mix build-root override. Defaults under %USERPROFILE%\.agents\splusplus\build\mcp for plugin launcher runs."
  Write-Host "  SYMPP_BACKEND_PORT           Backend/API port. Defaults to $DefaultBackendPort. Use 0 for any available port."
  Write-Host "  SYMPP_BACKEND_URL            Reuse an already-running backend URL instead of starting mix sympp.cockpit."
  Write-Host "  SYMPP_DASHBOARD_PORT         Preferred dashboard port. Defaults to $DefaultDashboardPort. Use 0 for any available port."
  Write-Host "  SYMPP_DASHBOARD_ORIGIN       Reuse an external dashboard origin instead of starting Vite."
  Write-Host "  SYMPP_AUTOSTART_SERVERS      Set to 0/false/off to skip backend and frontend autostart."
  Write-Host "  SYMPP_AUTOSTART_BACKEND      Set to 0/false/off to skip backend autostart."
  Write-Host "  SYMPP_AUTOSTART_FRONTEND     Set to 0/false/off to skip frontend autostart."
  Write-Host "  SYMPP_MCP_BRIDGE_MODE        'http' (default) bridges stdio to HTTP; 'direct_stdio' runs mix sympp.mcp directly."
  Write-Host "  SYMPP_ARTIFACT_RUNTIME       Set to 1/true/yes/on to prefer runtime artifacts from a source checkout."
  Write-Host "  SYMPP_RUNTIME_FILE           Optional runtime JSON output path. Defaults under %USERPROFILE%\.agents\splusplus\runtime."
  Write-Host "  SYMPP_LOG_DIR                Optional background server log directory. Defaults under %USERPROFILE%\.agents\splusplus\logs."
  Write-Host "  SYMPP_BACKEND_STARTUP_TIMEOUT_SEC    Backend startup wait. Defaults to 60."
  Write-Host "  SYMPP_BACKEND_PORT_RELEASE_TIMEOUT_SEC  Preferred backend port stale-listener wait. Defaults to 15."
  Write-Host "  SYMPP_ELIXIR_SETUP_TIMEOUT_SEC   Per-command Elixir setup wait. Defaults to 300."
  Write-Host "  SYMPP_FRONTEND_INSTALL_TIMEOUT_SEC   Dashboard npm install wait when dependencies are missing. Defaults to 180."
  Write-Host "  SYMPP_FRONTEND_STARTUP_TIMEOUT_SEC   Frontend startup wait. Defaults to 20."
  Write-Host "  SYMPP_MCP_HTTP_TIMEOUT_SEC           Per-request bridge timeout. Defaults to 300."
  Write-Host "  SYMPP_STARTUP_LOCK_TIMEOUT_SEC       Local startup lock wait. Defaults to the configured startup waits plus 30 seconds, with a 120-second floor."
  Write-Host ""
  Write-Host "Installed plugins resolve through the Codex marketplace snapshot. .sympp-source-root hints are ignored."
}

function Write-Diagnostic([string]$Message) {
  [Console]::Error.WriteLine($Message)
}

function Resolve-OptionalPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Test-SymphonySourceRoot([string]$Path) {
  return (-not [string]::IsNullOrWhiteSpace($Path)) -and (Test-Path -LiteralPath (Join-Path $Path "elixir/mix.exs"))
}

function Get-FileSha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
      return (($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
      $stream.Dispose()
    }
  } finally {
    $sha256.Dispose()
  }
}

function Test-InstalledPluginPayloadMatchesMarketplaceSource([string]$PluginRoot, [string]$SourceRoot) {
  $packageRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($PluginRoot))
  $packageName = Split-Path -Leaf $packageRoot
  $sourcePluginRoot = Join-Path $SourceRoot "plugins/$packageName"
  $relativePaths = @(
    ".codex-plugin/plugin.json",
    ".mcp.json",
    "scripts/start-sympp-mcp.ps1",
    "scripts/sympp-launcher-runtime.ps1"
  )
  $checked = 0

  foreach ($relativePath in $relativePaths) {
    $installedPath = Join-Path $PluginRoot $relativePath
    if (-not (Test-Path -LiteralPath $installedPath)) {
      continue
    }

    $sourcePath = Join-Path $sourcePluginRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
      return $false
    }

    if ((Get-FileSha256 $installedPath) -ne (Get-FileSha256 $sourcePath)) {
      return $false
    }
    $checked += 1
  }

  return $checked -gt 0
}

function Resolve-RepoRootFromMarketplaceCache([string]$PluginRoot) {
  $versionRoot = [System.IO.Path]::GetFullPath($PluginRoot)
  $packageRoot = Split-Path -Parent $versionRoot
  $marketplaceRoot = Split-Path -Parent $packageRoot
  $cacheRoot = Split-Path -Parent $marketplaceRoot
  $pluginsRoot = Split-Path -Parent $cacheRoot

  if ((Split-Path -Leaf $cacheRoot) -ne "cache" -or (Split-Path -Leaf $pluginsRoot) -ne "plugins") {
    return $null
  }

  $codexHome = Split-Path -Parent $pluginsRoot
  $marketplaceName = Split-Path -Leaf $marketplaceRoot
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $codexHome ".tmp/marketplaces/$marketplaceName"))

  if ((Test-SymphonySourceRoot $candidate) -and
      (Test-Path -LiteralPath (Join-Path $candidate "plugins/symphony-plus-plus/.codex-plugin/plugin.json")) -and
      (Test-Path -LiteralPath (Join-Path $candidate "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json"))) {
    if (-not (Test-InstalledPluginPayloadMatchesMarketplaceSource $versionRoot $candidate)) {
      throw "Codex marketplace source clone does not match the installed Symphony++ MCP plugin cache. Run codex plugin marketplace upgrade or refresh the installed cache before starting the MCP runtime: $candidate"
    }

    $installedRevision = Get-SymppPinnedSourceRevision $versionRoot
    $candidateRevision = Resolve-SymppSourceRevision $candidate
    if ($installedRevision -and $candidateRevision -and
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($installedRevision, $candidateRevision)) {
      throw "Codex marketplace source clone revision $candidateRevision does not match installed Symphony++ MCP cache revision $installedRevision. Refresh the installed plugin cache before starting the MCP runtime."
    }

    return $candidate
  }

  return $null
}

function Resolve-RepoRootFromSourceHint([string]$PluginRoot) {
  $sourceRootHintPath = Join-Path $PluginRoot ".sympp-source-root"
  if (-not (Test-Path -LiteralPath $sourceRootHintPath)) {
    return [pscustomobject]@{ found = $false; valid = $false; root = $null }
  }

  $hintText = (Get-Content -LiteralPath $sourceRootHintPath -Raw).Trim().TrimStart([char]0xFEFF)
  $hintedRoot = Resolve-OptionalPath $hintText
  if ($hintedRoot -and (Test-SymphonySourceRoot $hintedRoot)) {
    return [pscustomobject]@{ found = $true; valid = $true; root = $hintedRoot }
  }

  return [pscustomobject]@{ found = $true; valid = $false; root = $null }
}

function Resolve-RepoRoot {
  $configuredRoot = Resolve-OptionalPath $env:SYMPP_REPO_ROOT
  if ($configuredRoot) {
    if (Test-SymphonySourceRoot $configuredRoot) {
      return $configuredRoot
    }

    throw "SYMPP_REPO_ROOT does not look like a Symphony++ checkout with elixir/mix.exs: $configuredRoot"
  }

  $pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
  if (Test-SymphonySourceRoot $sourceCandidate) {
    return $sourceCandidate
  }

  $marketplaceRoot = Resolve-RepoRootFromMarketplaceCache $pluginRoot
  if ($marketplaceRoot) {
    return $marketplaceRoot
  }

  $sourceRootHint = Resolve-RepoRootFromSourceHint $pluginRoot
  if ($sourceRootHint.valid) {
    return $sourceRootHint.root
  }
  if ($sourceRootHint.found) {
    throw "Installed plugin source-root hint is invalid. Refresh the plugin cache or set SYMPP_REPO_ROOT."
  }

  throw "Cannot infer the Symphony++ runtime source. Reinstall or refresh the Symphony++ marketplace, or set SYMPP_REPO_ROOT to the source checkout root before starting the plugin MCP server."
}

function Resolve-SymppHome {
  $configured = Resolve-OptionalPath $env:SYMPP_HOME
  if ($configured) {
    return $configured
  }

  return Resolve-SymppPluginHome
}

function Resolve-RuntimeFile {
  $configured = Resolve-OptionalPath $env:SYMPP_RUNTIME_FILE
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppHome) "runtime/codex-plugin.json"))
}

function Resolve-LogDir {
  $configured = Resolve-OptionalPath $env:SYMPP_LOG_DIR
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppHome) "logs"))
}

function Resolve-StartupLockFile([string]$RuntimeFile) {
  $runtimeDir = Split-Path -Parent $RuntimeFile
  return [System.IO.Path]::GetFullPath((Join-Path $runtimeDir "codex-plugin.lock"))
}

function Test-EnvEnabled([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $false
  }

  return $value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
}

function Test-SourceCheckoutLaunch([string]$PluginRoot) {
  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PluginRoot "../.."))
  return Test-SymphonySourceRoot $sourceCandidate
}

function Test-SourceFallbackAllowed([string]$PluginRoot) {
  if (Test-SourceCheckoutLaunch $PluginRoot) {
    return $true
  }

  return (Test-EnvEnabled "SYMPP_DEVELOPER_MODE") -or
    (Test-EnvEnabled "SYMPP_SOURCE_FALLBACK") -or
    (Test-EnvEnabled "SYMPP_ALLOW_SOURCE_COMPILE")
}

function Test-ArtifactRuntimeAllowed([string]$PluginRoot) {
  if (Test-EnvEnabled "SYMPP_ARTIFACT_RUNTIME") {
    return $true
  }

  return -not (Test-SourceCheckoutLaunch $PluginRoot)
}

function Get-JsonPropertyValue($Object, [string[]]$Names) {
  if ($null -eq $Object) {
    return $null
  }

  foreach ($name in $Names) {
    if ($Object.PSObject.Properties[$name]) {
      return $Object.PSObject.Properties[$name].Value
    }
  }

  return $null
}

function Get-SymppPluginVersion([string]$PluginRoot) {
  $manifestPath = Join-Path $PluginRoot ".codex-plugin/plugin.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $version = [string]$manifest.version
    if (-not [string]::IsNullOrWhiteSpace($version)) {
      return $version.Trim()
    }
  } catch {
  }

  return $null
}

function Resolve-ExpectedSourceRevision([string]$PluginRoot) {
  $pinnedRevision = Get-SymppPinnedSourceRevision $PluginRoot
  if ($pinnedRevision) {
    return $pinnedRevision
  }

  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PluginRoot "../.."))
  if (Test-SymphonySourceRoot $sourceCandidate) {
    return Resolve-SymppSourceRevision $sourceCandidate $PluginRoot
  }

  return $null
}

function Get-SymppArtifactManifestPath([string]$PluginRoot) {
  foreach ($relativePath in @(".sympp-runtime-artifacts.json", "assets/sympp-runtime-artifacts.json")) {
    $candidate = Join-Path $PluginRoot $relativePath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }

  return $null
}

function Read-SymppArtifactManifest([string]$PluginRoot) {
  $path = Get-SymppArtifactManifestPath $PluginRoot
  if (-not $path) {
    return $null
  }

  try {
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $path -Force
    return $manifest
  } catch {
    throw "artifact_manifest_invalid: $path could not be parsed as JSON. detail=$($_.Exception.Message)"
  }
}

function Normalize-SymppSha256([string]$Sha256) {
  if ([string]::IsNullOrWhiteSpace($Sha256)) {
    return $null
  }

  $normalized = $Sha256.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{64}$") {
    return $normalized
  }

  return $null
}

function Test-SymppArtifactPlatformMatches($Artifact, [string]$Platform) {
  $artifactPlatform = [string](Get-JsonPropertyValue $Artifact @("platform", "target", "platform_key"))
  if (-not [string]::IsNullOrWhiteSpace($artifactPlatform)) {
    return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactPlatform.Trim(), $Platform)
  }

  $os = [string](Get-JsonPropertyValue $Artifact @("os", "target_os"))
  $arch = [string](Get-JsonPropertyValue $Artifact @("arch", "architecture", "target_arch"))
  if ([string]::IsNullOrWhiteSpace($os) -or [string]::IsNullOrWhiteSpace($arch)) {
    return $false
  }

  $artifactPlatform = "$($os.Trim().ToLowerInvariant())-$($arch.Trim().ToLowerInvariant())"
  return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactPlatform, $Platform)
}

function Test-SymppArtifactRevisionMatches($Artifact, [string]$ExpectedSourceRevision, [string]$ManifestSourceRevision) {
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $true
  }

  $artifactRevision = Normalize-SymppSourceRevision ([string](Get-JsonPropertyValue $Artifact @("source_revision", "revision", "git_revision")))
  if (-not $artifactRevision) {
    $artifactRevision = Normalize-SymppSourceRevision $ManifestSourceRevision
  }

  return $artifactRevision -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactRevision, $ExpectedSourceRevision)
}

function Test-SymppArtifactContractMatches($Artifact, [string]$ExpectedContractFingerprint, [string]$ManifestContractFingerprint) {
  $artifactContract = Normalize-McpContractFingerprint ([string](Get-JsonPropertyValue $Artifact @("mcp_contract_fingerprint", "contract_fingerprint")))
  if (-not $artifactContract) {
    $artifactContract = Normalize-McpContractFingerprint $ManifestContractFingerprint
  }

  if (-not $artifactContract) {
    return $true
  }

  return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactContract, $ExpectedContractFingerprint)
}

function Select-SymppArtifact($Manifest, [string]$Platform, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint) {
  if ($null -eq $Manifest) {
    return $null
  }

  $artifacts = @(Get-JsonPropertyValue $Manifest @("artifacts", "runtime_artifacts"))
  if ($artifacts.Count -eq 0) {
    return $null
  }

  $manifestSourceRevision = Normalize-SymppSourceRevision ([string](Get-JsonPropertyValue $Manifest @("source_revision", "revision", "git_revision")))
  $manifestContractFingerprint = Normalize-McpContractFingerprint ([string](Get-JsonPropertyValue $Manifest @("mcp_contract_fingerprint", "contract_fingerprint")))
  foreach ($artifact in $artifacts) {
    if ((Test-SymppArtifactPlatformMatches $artifact $Platform) -and
        (Test-SymppArtifactRevisionMatches $artifact $ExpectedSourceRevision $manifestSourceRevision) -and
        (Test-SymppArtifactContractMatches $artifact $ExpectedContractFingerprint $manifestContractFingerprint)) {
      return $artifact
    }
  }

  return $null
}

function Assert-SymppRelativeArtifactPath([string]$Path, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label must be present in the Symphony++ runtime artifact manifest."
  }

  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("..")) {
    throw "$Label must be a relative path inside the extracted Symphony++ runtime artifact."
  }
}

function Resolve-SymppArtifactSourceUri($Artifact, [string]$ManifestPath) {
  $value = [string](Get-JsonPropertyValue $Artifact @("url", "download_url", "uri", "path"))
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "artifact_missing: selected Symphony++ runtime artifact does not declare url, download_url, uri, or path."
  }

  if ([System.Uri]::IsWellFormedUriString($value, [System.UriKind]::Absolute)) {
    return $value
  }

  $manifestDir = Split-Path -Parent $ManifestPath
  return [System.IO.Path]::GetFullPath((Join-Path $manifestDir $value))
}

function Assert-SymppArtifactSourceUsable([string]$SourceUri) {
  if ([System.Uri]::IsWellFormedUriString($SourceUri, [System.UriKind]::Absolute)) {
    $uri = [System.Uri]$SourceUri
    if ($uri.Scheme -eq "file") {
      if (-not (Test-Path -LiteralPath $uri.LocalPath -PathType Leaf)) {
        throw "artifact_missing: selected Symphony++ runtime artifact file does not exist: $($uri.LocalPath)"
      }
      return
    }
    if ($uri.Scheme -eq "https" -or ($uri.Scheme -eq "http" -and $uri.IsLoopback)) {
      return
    }
    throw "artifact_download_blocked: Symphony++ runtime artifacts must use https, file, or loopback http URLs."
  }

  if (-not (Test-Path -LiteralPath $SourceUri -PathType Leaf)) {
    throw "artifact_missing: selected Symphony++ runtime artifact file does not exist: $SourceUri"
  }
}

function Resolve-SymppArtifactEntrypoint($Artifact) {
  $entrypoint = [string](Get-JsonPropertyValue $Artifact @("entrypoint", "backend_entrypoint", "command"))
  if ([string]::IsNullOrWhiteSpace($entrypoint)) {
    if (Test-SymppWindowsPlatform) {
      $entrypoint = "bin/symphony_elixir.bat"
    } else {
      $entrypoint = "bin/symphony_elixir"
    }
  }

  Assert-SymppRelativeArtifactPath $entrypoint "artifact entrypoint"
  return $entrypoint.Replace("\", "/")
}

function Resolve-SymppArtifactCacheRoot([string]$Platform, [string]$SourceRevision, [string]$PluginVersion, [string]$Sha256) {
  $revisionKey = if (-not [string]::IsNullOrWhiteSpace($SourceRevision)) {
    $SourceRevision.Substring(0, [Math]::Min(12, $SourceRevision.Length))
  } elseif (-not [string]::IsNullOrWhiteSpace($PluginVersion)) {
    $PluginVersion -replace "[^A-Za-z0-9_.-]", "_"
  } else {
    "unknown"
  }
  $shaKey = $Sha256.Substring(0, 16)
  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppPluginHome) "artifacts/mcp/$Platform/$revisionKey/$shaKey"))
}

function Test-SymppArtifactCacheReady([string]$ExtractRoot, [string]$Entrypoint, [string]$Sha256) {
  $markerPath = Join-Path $ExtractRoot ".sympp-artifact.json"
  $entrypointPath = Join-Path $ExtractRoot $Entrypoint
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $entrypointPath -PathType Leaf)) {
    return $false
  }

  try {
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.sha256, $Sha256)
  } catch {
    return $false
  }
}

function Assert-SymppArtifactArchiveVerified([string]$ArchivePath, [string]$ExpectedSha256) {
  $actual = Get-FileSha256 $ArchivePath
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $ExpectedSha256)) {
    throw "artifact_verification_failed: expected sha256 $ExpectedSha256 but got $actual for $ArchivePath."
  }
}

function Copy-SymppArtifactArchive([string]$SourceUri, [string]$TargetPath) {
  $targetDir = Split-Path -Parent $TargetPath
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  $tempPath = "$TargetPath.tmp-$PID"

  try {
    if ([System.Uri]::IsWellFormedUriString($SourceUri, [System.UriKind]::Absolute)) {
      $uri = [System.Uri]$SourceUri
      if ($uri.Scheme -eq "file") {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $tempPath -Force
      } elseif ($uri.Scheme -eq "https" -or ($uri.Scheme -eq "http" -and $uri.IsLoopback)) {
        Invoke-WebRequest -Uri $SourceUri -OutFile $tempPath -UseBasicParsing
      } else {
        throw "artifact_download_blocked: Symphony++ runtime artifacts must use https, file, or loopback http URLs."
      }
    } else {
      Copy-Item -LiteralPath $SourceUri -Destination $tempPath -Force
    }

    Move-Item -LiteralPath $tempPath -Destination $TargetPath -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Expand-SymppArtifactArchive([string]$ArchivePath, [string]$ExtractRoot, [string]$Entrypoint, [string]$Sha256, [string]$Platform, [string]$SourceRevision, [string]$PluginVersion, [string]$ManifestPath) {
  $parent = Split-Path -Parent $ExtractRoot
  $staging = "$ExtractRoot.extracting-$PID"
  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  try {
    Write-Diagnostic "artifact_extracting: extracting verified Symphony++ runtime artifact to $ExtractRoot."
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force
    $entrypointPath = Join-Path $staging $Entrypoint
    if (-not (Test-Path -LiteralPath $entrypointPath -PathType Leaf)) {
      throw "artifact_missing: extracted Symphony++ runtime artifact did not contain entrypoint $Entrypoint."
    }
    if (-not (Test-SymppWindowsPlatform)) {
      try {
        & chmod +x $entrypointPath
        if ($LASTEXITCODE -ne 0) {
          throw "chmod exited with $LASTEXITCODE"
        }
      } catch {
        throw "artifact_verification_failed: could not mark extracted Symphony++ runtime artifact entrypoint executable. detail=$($_.Exception.Message)"
      }
    }

    $marker = [pscustomobject]@{
      sha256 = $Sha256
      platform = $Platform
      source_revision = $SourceRevision
      plugin_version = $PluginVersion
      manifest_path = $ManifestPath
      extracted_at = (Get-Date).ToString("o")
    }
    $marker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $staging ".sympp-artifact.json") -Encoding UTF8
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $staging -Destination $ExtractRoot -Force
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Resolve-SymppPreparedArtifactRuntime([string]$PluginRoot, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [switch]$ValidateOnly) {
  $platform = Get-SymppRuntimePlatformKey
  if ([string]::IsNullOrWhiteSpace($platform)) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "platform_unknown"; runtime = $null }
  }

  $manifest = Read-SymppArtifactManifest $PluginRoot
  if ($null -eq $manifest) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "manifest_missing"; platform = $platform; runtime = $null }
  }

  $artifact = Select-SymppArtifact $manifest $platform $ExpectedSourceRevision $ExpectedContractFingerprint
  if ($null -eq $artifact) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "matching_artifact_missing"; platform = $platform; manifest_path = $manifest.manifest_path; runtime = $null }
  }

  $sha256 = Normalize-SymppSha256 ([string](Get-JsonPropertyValue $artifact @("sha256", "sha256sum", "digest")))
  if (-not $sha256) {
    throw "artifact_verification_failed: selected Symphony++ runtime artifact does not declare a valid sha256."
  }

  $pluginVersion = Get-SymppPluginVersion $PluginRoot
  $entrypoint = Resolve-SymppArtifactEntrypoint $artifact
  $cacheRoot = Resolve-SymppArtifactCacheRoot $platform $ExpectedSourceRevision $pluginVersion $sha256
  $extractRoot = Join-Path $cacheRoot "runtime"
  $archivePath = Join-Path $cacheRoot "artifact.zip"

  if ($ValidateOnly) {
    $ready = Test-SymppArtifactCacheReady $extractRoot $entrypoint $sha256
    if (-not $ready) {
      $sourceUri = Resolve-SymppArtifactSourceUri $artifact $manifest.manifest_path
      Assert-SymppArtifactSourceUsable $sourceUri
    }
    return [pscustomobject]@{
      status = $(if ($ready) { "ready" } else { "artifact_selected" })
      detail = $(if ($ready) { "cache_ready" } else { "download_required" })
      platform = $platform
      manifest_path = $manifest.manifest_path
      cache_root = $cacheRoot
      runtime = $null
    }
  }

  $lock = Enter-FileLock (Join-Path $cacheRoot "artifact.lock") 600
  try {
    if (Test-SymppArtifactCacheReady $extractRoot $entrypoint $sha256) {
      Write-Diagnostic "ready: reusing verified Symphony++ runtime artifact at $extractRoot."
    } else {
      $sourceUri = Resolve-SymppArtifactSourceUri $artifact $manifest.manifest_path
      Assert-SymppArtifactSourceUsable $sourceUri
      if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Diagnostic "artifact_downloading: downloading Symphony++ runtime artifact for $platform."
        Copy-SymppArtifactArchive $sourceUri $archivePath
      }
      try {
        Assert-SymppArtifactArchiveVerified $archivePath $sha256
      } catch {
        Write-Diagnostic "artifact_redownloading: cached Symphony++ runtime artifact failed verification; downloading again. detail=$($_.Exception.Message)"
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Copy-SymppArtifactArchive $sourceUri $archivePath
      }
      Assert-SymppArtifactArchiveVerified $archivePath $sha256
      Expand-SymppArtifactArchive $archivePath $extractRoot $entrypoint $sha256 $platform $ExpectedSourceRevision $pluginVersion $manifest.manifest_path
    }
  } finally {
    Exit-FileLock $lock
  }

  return [pscustomobject]@{
    status = "ready"
    detail = "artifact_ready"
    platform = $platform
    manifest_path = $manifest.manifest_path
    cache_root = $cacheRoot
    runtime = [pscustomobject]@{
      root = [System.IO.Path]::GetFullPath($extractRoot)
      entrypoint = [System.IO.Path]::GetFullPath((Join-Path $extractRoot $entrypoint))
      sha256 = $sha256
      platform = $platform
      source_revision = $ExpectedSourceRevision
      plugin_version = $pluginVersion
      manifest_path = $manifest.manifest_path
    }
  }
}

function Resolve-SymppArtifactProbe([string]$PluginRoot, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$ArtifactRuntimeAllowed, [bool]$SourceFallbackAllowed, [switch]$ValidateOnly) {
  if (-not $ArtifactRuntimeAllowed) {
    return [pscustomobject]@{
      status = "artifact_skipped"
      detail = "source_checkout"
      platform = Get-SymppRuntimePlatformKey
      runtime = $null
    }
  }

  try {
    return Resolve-SymppPreparedArtifactRuntime $PluginRoot $ExpectedSourceRevision $ExpectedContractFingerprint -ValidateOnly:$ValidateOnly
  } catch {
    if ($SourceFallbackAllowed) {
      return [pscustomobject]@{
        status = "artifact_unavailable"
        detail = $_.Exception.Message
        platform = Get-SymppRuntimePlatformKey
        runtime = $null
      }
    }

    throw
  }
}

function Resolve-LaunchArtifactSelection(
  [string]$PluginRoot,
  [string]$RepoRoot,
  $ArtifactProbe,
  [string]$ExpectedSourceRevision,
  [string]$ExpectedContractFingerprint,
  [bool]$ArtifactRuntimeAllowed,
  [bool]$SourceFallbackAllowed
) {
  $artifactRuntime = $null
  $runtimeMode = "source"
  $sourceRevision = $ExpectedSourceRevision

  if ($ArtifactProbe.status -eq "ready" -or $ArtifactProbe.status -eq "artifact_selected") {
    try {
      $preparedArtifact = Resolve-SymppArtifactProbe $PluginRoot $sourceRevision $ExpectedContractFingerprint $ArtifactRuntimeAllowed $SourceFallbackAllowed
      if ($preparedArtifact.status -eq "ready" -and $preparedArtifact.runtime) {
        $artifactRuntime = $preparedArtifact.runtime
        $runtimeMode = "artifact"
        Write-Diagnostic "ready: verified Symphony++ runtime artifact selected for $($artifactRuntime.platform)."
      } elseif (-not $SourceFallbackAllowed) {
        Write-Diagnostic "$($preparedArtifact.status): $($preparedArtifact.detail)"
        Write-Diagnostic "source_fallback_disabled: set SYMPP_SOURCE_FALLBACK=1 or SYMPP_DEVELOPER_MODE=1 to compile from a source checkout."
        throw "source_fallback_disabled: no verified Symphony++ runtime artifact is ready for this installed launcher."
      }
    } catch {
      if (-not $SourceFallbackAllowed) {
        Write-Diagnostic "source_fallback_disabled: set SYMPP_SOURCE_FALLBACK=1 or SYMPP_DEVELOPER_MODE=1 to compile from a source checkout."
        throw
      }
      Write-Diagnostic "source_fallback_compiling: artifact startup failed under explicit source fallback control. detail=$($_.Exception.Message)"
      if ([string]::IsNullOrWhiteSpace($sourceRevision)) {
        $sourceRevision = Resolve-SymppSourceRevision $RepoRoot $PluginRoot
        Set-SymppSourceRevisionEnvironment $sourceRevision
      }
    }
  } elseif ($ArtifactProbe.status -eq "artifact_unavailable" -and $SourceFallbackAllowed) {
    Write-Diagnostic "source_fallback_compiling: artifact probe failed under source fallback control. detail=$($ArtifactProbe.detail)"
  }

  return [pscustomobject]@{
    artifact_runtime = $artifactRuntime
    runtime_mode = $runtimeMode
    expected_source_revision = $sourceRevision
  }
}

function Enter-FileLock([string]$LockPath, [int]$TimeoutSec) {
  $lockDir = Split-Path -Parent $LockPath
  New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 200
    }
  }

  throw "Timed out waiting for Symphony++ launcher startup lock: $LockPath"
}

function Exit-FileLock($Lock) {
  if ($null -ne $Lock) {
    $Lock.Dispose()
  }
}

function Test-EnvDisabled([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $false
  }

  return $value.Trim().ToLowerInvariant() -in @("0", "false", "no", "off")
}

function Get-EnvInteger([string]$Name, [int]$Default, [int]$Min, [int]$Max) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Default
  }

  $parsed = 0
  if (-not [int]::TryParse($value.Trim(), [ref]$parsed) -or $parsed -lt $Min -or $parsed -gt $Max) {
    throw "$Name must be an integer from $Min to $Max."
  }

  return $parsed
}

function Get-EnvMode([string]$Name, [string]$Default, [string[]]$Allowed) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  $mode = if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { $value.Trim().ToLowerInvariant() }
  if ($Allowed -notcontains $mode) {
    throw "$Name must be one of: $($Allowed -join ', ')."
  }

  return $mode
}

function Test-IsMiseShim([string]$Path) {
  $normalized = $Path.Replace("\", "/").ToLowerInvariant()
  return ($normalized -match "/mise/" -or $normalized -match "/\.mise/") -and $normalized -match "/shims?/"
}

function Resolve-CommandSource([string]$CommandName, [string]$MissingMessage) {
  $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw $MissingMessage
  }

  if ($command.Source) {
    return [string]$command.Source
  }

  return [string]$command.Path
}

function Assert-LoopbackHttpOrigin([string]$Url, [string]$Name) {
  try {
    $uri = [System.Uri]$Url
  } catch {
    throw "$Name must be a valid local http URL."
  }

  if ($uri.Scheme -ne "http" -or -not $uri.IsLoopback) {
    throw "$Name must use a loopback http origin."
  }
}

function Resolve-NpmCommand {
  foreach ($candidate in @("npm.cmd", "npm.exe", "npm")) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.CommandType -eq "Application") {
      if ($command.Source) {
        return [string]$command.Source
      }
      return [string]$command.Path
    }
  }

  throw "Could not find npm executable. Install Node/npm or set SYMPP_DASHBOARD_ORIGIN to an existing dashboard."
}

function Test-NpmAvailable {
  try {
    [void](Resolve-NpmCommand)
    return $true
  } catch {
    return $false
  }
}

function Get-PowerShellHostCommandName {
  foreach ($candidate in @("pwsh", "powershell.exe", "powershell")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
      return $candidate
    }
  }

  return "powershell"
}

function Get-StartProcessCommand([string]$FilePath, [string[]]$ArgumentList) {
  if ($FilePath.EndsWith(".ps1", [System.StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{
      file = Get-PowerShellHostCommandName
      args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FilePath) + @($ArgumentList)
    }
  }

  return [pscustomobject]@{
    file = $FilePath
    args = @($ArgumentList)
  }
}

function ConvertTo-ProcessArgument([string]$Argument) {
  if ($null -eq $Argument -or $Argument.Length -eq 0) {
    return '""'
  }

  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }

  $result = [System.Text.StringBuilder]::new()
  [void]$result.Append('"')
  $backslashes = 0
  foreach ($char in $Argument.ToCharArray()) {
    if ($char -eq '\') {
      $backslashes += 1
    } elseif ($char -eq '"') {
      [void]$result.Append('\' * (($backslashes * 2) + 1))
      [void]$result.Append('"')
      $backslashes = 0
    } else {
      if ($backslashes -gt 0) {
        [void]$result.Append('\' * $backslashes)
        $backslashes = 0
      }
      [void]$result.Append($char)
    }
  }

  if ($backslashes -gt 0) {
    [void]$result.Append('\' * ($backslashes * 2))
  }
  [void]$result.Append('"')
  return $result.ToString()
}

function Join-ProcessArgumentList([string[]]$ArgumentList) {
  return (@($ArgumentList) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
}

function Resolve-MixCommand([string]$MixCommand) {
  $source = Resolve-CommandSource $MixCommand "Could not find mix executable '$MixCommand'. Install Elixir or set SYMPP_MIX."
  if (Test-IsMiseShim $source) {
    throw "Direct launcher resolved mix to a mise shim: $source. Set SYMPP_MIX to a non-mise Mix executable, or set SYMPP_LAUNCHER=mise after trusting the checkout's mise config."
  }

  return $source
}

function Assert-LauncherAvailable([string]$Launcher, [string]$MixCommand, [string]$MiseCommand) {
  switch ($Launcher) {
    "direct" {
      [void](Resolve-MixCommand $MixCommand)
      return
    }
    "mise" {
      [void](Resolve-CommandSource $MiseCommand "Could not find mise executable '$MiseCommand'. Install mise or set SYMPP_MISE.")
      return
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$Launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Get-LauncherCommand([string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string[]]$MixArgs) {
  switch ($Launcher) {
    "direct" {
      return [pscustomobject]@{
        file = Resolve-MixCommand $MixCommand
        args = @($MixArgs)
      }
    }
    "mise" {
      return [pscustomobject]@{
        file = Resolve-CommandSource $MiseCommand "Could not find mise executable '$MiseCommand'. Install mise or set SYMPP_MISE."
        args = @("exec", "--", "mix") + @($MixArgs)
      }
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$Launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Test-LauncherVersion([string]$Launcher, [string]$MixCommand, [string]$MiseCommand) {
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand @("--version")
  & $command.file @($command.args) | Out-Host
  return $LASTEXITCODE
}

function Test-PortAvailable([int]$Port) {
  if ($Port -eq 0) {
    return $true
  }

  $listener = $null
  try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) {
      $listener.Stop()
    }
  }
}

function New-PortOwner([int]$ProcessId, [string]$LocalAddress) {
  $processName = "<unknown>"
  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($process.ProcessName)) {
      $processName = [string]$process.ProcessName
    }
  } catch {
  }

  return [pscustomobject]@{
    pid = $ProcessId
    process = $processName
    localAddress = $LocalAddress
  }
}

function Add-PortOwner($Owners, $Seen, [int]$ProcessId, [string]$LocalAddress) {
  $key = "$ProcessId|$LocalAddress"
  if ($Seen.Contains($key)) {
    return
  }

  [void]$Seen.Add($key)
  [void]$Owners.Add((New-PortOwner $ProcessId $LocalAddress))
}

function Get-TcpPortOwners([int]$Port) {
  $owners = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new()

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
      $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
      foreach ($connection in $connections) {
        $processId = [int]$connection.OwningProcess
        if ($processId -gt 0) {
          Add-PortOwner $owners $seen $processId ([string]$connection.LocalAddress)
        }
      }
    } catch {
    }
  }

  if ($owners.Count -eq 0 -and (Get-Command netstat -ErrorAction SilentlyContinue)) {
    try {
      $escapedPort = [regex]::Escape([string]$Port)
      foreach ($line in @(& netstat -ano -p tcp 2>$null)) {
        if ($line -match "^\s*TCP\s+(.+):$escapedPort\s+\S+\s+LISTENING\s+(\d+)\s*$") {
          Add-PortOwner $owners $seen ([int]$matches[2]) $matches[1].Trim()
        }
      }
    } catch {
    }
  }

  return @($owners)
}

function Format-PortOwners([object[]]$Owners) {
  if ($Owners.Count -eq 0) {
    return "an unknown process"
  }

  return (@($Owners) | ForEach-Object {
      "pid=$($_.pid) process=$($_.process) localAddress=$($_.localAddress)"
    }) -join "; "
}

function New-BackendPortOccupiedMessage([int]$Port, [object[]]$Owners) {
  $ownerSummary = Format-PortOwners $Owners
  return "backend_port_occupied: configured Symphony++ backend port http://127.0.0.1:$Port is occupied by $ownerSummary. Wait for stale listeners to exit, stop the owning process, set SYMPP_BACKEND_PORT=0 or another explicit port, or set SYMPP_BACKEND_URL to a healthy backend."
}

function Test-SymppBackendCommandLine([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) {
    return $false
  }

  return $CommandLine -match "(?i)\bsympp\.cockpit\b"
}

function Test-SymppBackendOwners([object[]]$Owners) {
  foreach ($owner in @($Owners)) {
    $processId = 0
    if ($null -ne $owner) {
      [void][int]::TryParse([string]$owner.pid, [ref]$processId)
    }
    if ($processId -gt 0 -and (Test-SymppBackendCommandLine (Get-ProcessCommandLine $processId))) {
      return $true
    }
  }

  return $false
}

function New-BackendBusySymppMessage([int]$Port, [object[]]$Owners, $Health) {
  $detail = if ($null -ne $Health -and -not [string]::IsNullOrWhiteSpace([string]$Health.detail)) { [string]$Health.detail } else { "unhealthy" }
  return "backend_port_busy_sympp_unhealthy: configured Symphony++ backend port http://127.0.0.1:$Port is occupied by $(Format-PortOwners $Owners), but MCP health did not complete (detail=$detail). Refusing to start a fallback runtime; retry after the singleton finishes startup or stop the stale owner."
}

function Wait-ForTcpPortRelease([int]$Port, [int]$TimeoutSec) {
  if ($Port -eq 0 -or (Test-PortAvailable $Port)) {
    return [pscustomobject]@{
      released = $true
      owners = @()
    }
  }

  $owners = @(Get-TcpPortOwners $Port)
  if ($TimeoutSec -gt 0) {
    Write-Diagnostic "Configured Symphony++ backend port 127.0.0.1:$Port is occupied by $(Format-PortOwners $owners); waiting up to $TimeoutSec seconds for stale listeners to clear."
  }

  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-PortAvailable $Port) {
      return [pscustomobject]@{
        released = $true
        owners = @()
      }
    }

    $owners = @(Get-TcpPortOwners $Port)
  }

  return [pscustomobject]@{
    released = $false
    owners = $owners
  }
}

function Get-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    $listener.Stop()
  }
}

function Select-AvailablePort([int]$PreferredPort, [int[]]$Avoid = @()) {
  $avoidSet = [System.Collections.Generic.HashSet[int]]::new()
  foreach ($port in @($Avoid)) {
    if ($port -gt 0) {
      [void]$avoidSet.Add($port)
    }
  }

  if ($PreferredPort -eq 0) {
    do {
      $port = Get-FreeTcpPort
    } while ($avoidSet.Contains($port))
    return $port
  }

  if (-not $avoidSet.Contains($PreferredPort) -and (Test-PortAvailable $PreferredPort)) {
    return $PreferredPort
  }

  for ($offset = 1; $offset -le 200; $offset++) {
    $candidate = $PreferredPort + $offset
    if ($candidate -gt 65535) {
      break
    }
    if (-not $avoidSet.Contains($candidate) -and (Test-PortAvailable $candidate)) {
      return $candidate
    }
  }

  do {
    $fallback = Get-FreeTcpPort
  } while ($avoidSet.Contains($fallback))
  return $fallback
}

function ConvertTo-JsonBody($Payload) {
  return $Payload | ConvertTo-Json -Depth 16 -Compress
}

function Get-ResponseHeaderValue($Headers, [string]$Name) {
  if ($null -eq $Headers) {
    return $null
  }

  $rawValue = $null
  if ($Headers -is [System.Net.WebHeaderCollection]) {
    $rawValue = $Headers[$Name]
  } elseif ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in $Headers.Keys) {
      if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rawValue = $Headers[$key]
        break
      }
    }
  } else {
    $property = $Headers.PSObject.Properties |
      Where-Object { [string]::Equals($_.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase) } |
      Select-Object -First 1
    if ($property) {
      $rawValue = $property.Value
    }
  }

  foreach ($value in @($rawValue)) {
    if ($null -eq $value) {
      continue
    }

    foreach ($entry in @($value)) {
      foreach ($part in ([string]$entry).Split(",")) {
        $text = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
          return $text
        }
      }
    }
  }

  return $null
}

function Read-ErrorResponseBody($Response) {
  if ($null -eq $Response) {
    return $null
  }

  try {
    if ($Response.PSObject.Methods["GetResponseStream"]) {
      $stream = $Response.GetResponseStream()
      if ($null -eq $stream) {
        return $null
      }

      $reader = [System.IO.StreamReader]::new($stream)
      try {
        return $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
    }

    if ($Response.PSObject.Properties["Content"] -and $Response.Content) {
      return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } catch {
    return $null
  }

  return $null
}

function New-InitializeRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-plugin-launcher-init"
    method = "initialize"
    params = @{
      protocolVersion = "2025-03-26"
      clientInfo = @{
        name = "sympp-plugin-launcher"
        version = "0.1.0"
      }
      capabilities = @{}
    }
  }
}

function New-HealthRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-plugin-launcher-health"
    method = "tools/call"
    params = @{
      name = "sympp.health"
      arguments = @{}
    }
  }
}

function New-SymppBackendHealth([bool]$Healthy, [string]$SourceRevision, [string]$Detail, [bool]$TcpOpen, [bool]$McpReady = $false, [bool]$LedgerReachable = $false, [string]$Status = $null, [string]$ContractFingerprint = $null) {
  return [pscustomobject]@{
    healthy = $Healthy
    source_revision = $SourceRevision
    contract_fingerprint = $ContractFingerprint
    detail = $Detail
    tcp_open = $TcpOpen
    mcp_ready = $McpReady
    ledger_reachable = $LedgerReachable
    status = $Status
  }
}

function Test-LoopbackHttpTcpOpen([string]$Origin) {
  if ([string]::IsNullOrWhiteSpace($Origin)) {
    return $false
  }

  $client = $null
  try {
    $uri = [System.Uri]::new($Origin.TrimEnd("/"))
    if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") {
      return $false
    }
    if (@("127.0.0.1", "localhost", "::1") -notcontains $uri.Host) {
      return $false
    }

    $port = [int]$uri.Port
    if ($port -le 0) {
      $port = if ($uri.Scheme -eq "https") { 443 } else { 80 }
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    $connect = $client.BeginConnect($uri.Host, $port, $null, $null)
    if (-not $connect.AsyncWaitHandle.WaitOne(300)) {
      return $false
    }
    $client.EndConnect($connect)
    return $true
  } catch {
    return $false
  } finally {
    if ($client) {
      $client.Close()
    }
  }
}

function Get-HeaderValue($Headers, [string]$Name) {
  return Get-ResponseHeaderValue $Headers $Name
}

function Convert-SseContentToJsonLines([string]$Content) {
  $messages = [System.Collections.Generic.List[string]]::new()
  $dataLines = [System.Collections.Generic.List[string]]::new()

  foreach ($rawLine in ($Content -split "`r?`n")) {
    $line = $rawLine.TrimEnd("`r")
    if ([string]::IsNullOrWhiteSpace($line)) {
      if ($dataLines.Count -gt 0) {
        $message = ($dataLines -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($message) -and $message -ne "[DONE]") {
          $messages.Add($message)
        }
        $dataLines.Clear()
      }
      continue
    }

    if ($line.StartsWith("data:", [System.StringComparison]::OrdinalIgnoreCase)) {
      $dataLines.Add($line.Substring(5).TrimStart())
    }
  }

  if ($dataLines.Count -gt 0) {
    $message = ($dataLines -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($message) -and $message -ne "[DONE]") {
      $messages.Add($message)
    }
  }

  return @($messages)
}

function Convert-McpHttpContentToJsonLines([string]$Content, $Headers) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    return @()
  }

  $contentType = Get-HeaderValue $Headers "Content-Type"
  if ($contentType -and $contentType.ToLowerInvariant().Contains("text/event-stream")) {
    return @(Convert-SseContentToJsonLines $Content)
  }

  return @($Content.Trim())
}

function Get-InitializeProtocolVersion([string]$Body) {
  try {
    $payload = $Body | ConvertFrom-Json
    if ($payload.method -eq "initialize" -and $payload.params.protocolVersion) {
      return [string]$payload.params.protocolVersion
    }
  } catch {
  }

  return $null
}

function Get-ResponseProtocolVersion([string[]]$ContentLines) {
  foreach ($contentLine in @($ContentLines)) {
    if ([string]::IsNullOrWhiteSpace($contentLine)) {
      continue
    }

    try {
      $payload = $contentLine | ConvertFrom-Json
      if ($payload.result.protocolVersion) {
        return [string]$payload.result.protocolVersion
      }
    } catch {
    }
  }

  return $null
}

function Get-HealthSourceRevision($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["source"]) {
    return $null
  }

  $source = $structuredContent.source
  if ($null -eq $source -or -not $source.PSObject.Properties["revision"]) {
    return $null
  }

  return Normalize-SymppSourceRevision ([string]$source.revision)
}

function Normalize-McpContractFingerprint([string]$Fingerprint) {
  if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
    return $null
  }

  $fingerprint = $Fingerprint.Trim().ToLowerInvariant()
  if ($fingerprint -match "^[0-9a-f]{64}$") {
    return $fingerprint
  }

  return $null
}

function Get-HealthContractFingerprint($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent) {
    return $null
  }

  if ($structuredContent.PSObject.Properties["source"] -and
      $null -ne $structuredContent.source -and
      $structuredContent.source.PSObject.Properties["mcp_contract"] -and
      $null -ne $structuredContent.source.mcp_contract -and
      $structuredContent.source.mcp_contract.PSObject.Properties["fingerprint"]) {
    return Normalize-McpContractFingerprint ([string]$structuredContent.source.mcp_contract.fingerprint)
  }

  if ($structuredContent.PSObject.Properties["mcp_contract"] -and
      $null -ne $structuredContent.mcp_contract -and
      $structuredContent.mcp_contract.PSObject.Properties["fingerprint"]) {
    return Normalize-McpContractFingerprint ([string]$structuredContent.mcp_contract.fingerprint)
  }

  return $null
}

function Invoke-McpPost([string]$Url, [string]$Body, [string]$SessionId, [string]$ProtocolVersion, [int]$TimeoutSec) {
  $headers = @{ Accept = "application/json, text/event-stream" }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $headers["Mcp-Session-Id"] = $SessionId
  }
  if (-not [string]::IsNullOrWhiteSpace($ProtocolVersion)) {
    $headers["MCP-Protocol-Version"] = $ProtocolVersion
  }

  try {
    $response = Invoke-WebRequest `
      -Uri $Url `
      -Method Post `
      -Headers $headers `
      -ContentType "application/json" `
      -Body $Body `
      -TimeoutSec $TimeoutSec `
      -UseBasicParsing `
      -ErrorAction Stop

    return [pscustomobject]@{
      ok = $true
      statusCode = [int]$response.StatusCode
      headers = $response.Headers
      content = [string]$response.Content
      content_lines = @(Convert-McpHttpContentToJsonLines ([string]$response.Content) $response.Headers)
      error = $null
    }
  } catch {
    $response = $_.Exception.Response
    $statusCode = $null
    if ($null -ne $response) {
      try {
        $statusCode = [int]$response.StatusCode
      } catch {
        $statusCode = $null
      }
    }

    return [pscustomobject]@{
      ok = $false
      statusCode = $statusCode
      headers = if ($null -ne $response) { $response.Headers } else { $null }
      content = Read-ErrorResponseBody $response
      content_lines = @()
      error = $_.Exception.Message
    }
  }
}

function Get-SymppBackendHealth([string]$BackendUrl) {
  if ([string]::IsNullOrWhiteSpace($BackendUrl)) {
    return New-SymppBackendHealth $false $null "missing_url" $false
  }

  $tcpOpen = Test-LoopbackHttpTcpOpen $BackendUrl
  $mcpUrl = $BackendUrl.TrimEnd("/") + "/mcp"
  $initializeBody = ConvertTo-JsonBody (New-InitializeRequest)
  $init = Invoke-McpPost $mcpUrl $initializeBody $null $null 2
  if (-not $init.ok -or [string]::IsNullOrWhiteSpace($init.content)) {
    return New-SymppBackendHealth $false $null "initialize_failed" $tcpOpen
  }

  $sessionId = Get-ResponseHeaderValue $init.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return New-SymppBackendHealth $false $null "missing_session_id" $tcpOpen
  }

  $protocolVersion = Get-ResponseProtocolVersion @($init.content_lines)
  if ([string]::IsNullOrWhiteSpace($protocolVersion)) {
    $protocolVersion = Get-InitializeProtocolVersion $initializeBody
  }

  $health = Invoke-McpPost $mcpUrl (ConvertTo-JsonBody (New-HealthRequest)) $sessionId $protocolVersion 2
  $healthLines = @($health.content_lines)
  if (-not $health.ok -or $healthLines.Count -eq 0) {
    return New-SymppBackendHealth $false $null "health_failed" $tcpOpen
  }

  try {
    $payload = $healthLines[0] | ConvertFrom-Json
    if ($null -ne $payload.result -and $null -eq $payload.error) {
      $structuredContent = $payload.result.structuredContent
      $status = if ($null -ne $structuredContent -and $structuredContent.PSObject.Properties["status"]) { [string]$structuredContent.status } else { $null }
      $ledgerReachable = $false
      if ($null -ne $structuredContent -and
          $structuredContent.PSObject.Properties["ledger"] -and
          $null -ne $structuredContent.ledger -and
          $structuredContent.ledger.PSObject.Properties["reachable"]) {
        $ledgerReachable = $structuredContent.ledger.reachable -eq $true
      }
      $healthy = [System.StringComparer]::OrdinalIgnoreCase.Equals($status, "ok") -and $ledgerReachable
      $detail = if ($healthy) { $null } else { "health_degraded" }
      return New-SymppBackendHealth $healthy (Get-HealthSourceRevision $payload) $detail $true $true $ledgerReachable $status (Get-HealthContractFingerprint $payload)
    }

    return New-SymppBackendHealth $false $null "health_error" $tcpOpen $true $false $null
  } catch {
    return New-SymppBackendHealth $false $null "health_parse_failed" $tcpOpen
  }
}

function Get-SymppBackendHealthWithRetry([string]$BackendUrl, [int]$Attempts = 4, [int]$DelayMs = 500) {
  $last = $null
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $last = Get-SymppBackendHealth $BackendUrl
    if ($last.healthy -or -not $last.tcp_open) {
      return $last
    }
    if ($attempt -lt $Attempts) {
      Start-Sleep -Milliseconds $DelayMs
    }
  }

  return $last
}

function Test-HealthySymppBackend([string]$BackendUrl) {
  return (Get-SymppBackendHealthWithRetry $BackendUrl).healthy
}

function Test-BackendContractMatches($Health, [string]$ExpectedContractFingerprint) {
  if ($null -eq $Health -or -not $Health.healthy) {
    return $false
  }

  $expected = Normalize-McpContractFingerprint $ExpectedContractFingerprint
  if ([string]::IsNullOrWhiteSpace($expected)) {
    return $false
  }

  $actual = $null
  if ($Health.PSObject.Properties["contract_fingerprint"]) {
    $actual = Normalize-McpContractFingerprint ([string]$Health.contract_fingerprint)
  }

  return -not [string]::IsNullOrWhiteSpace($actual) -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $expected)
}

function Test-BackendSourceRevisionEquals($Health, [string]$ExpectedSourceRevision) {
  if ($null -eq $Health -or [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $false
  }

  return Test-SourceRevisionEquals ([string]$Health.source_revision) $ExpectedSourceRevision
}

function Test-SourceRevisionEquals([string]$ActualSourceRevision, [string]$ExpectedSourceRevision) {
  return -not [string]::IsNullOrWhiteSpace($ActualSourceRevision) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision) -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($ActualSourceRevision, $ExpectedSourceRevision)
}

function Test-BackendLaunchCompatible($Health, [string]$ExpectedContractFingerprint) {
  return Test-BackendContractMatches $Health $ExpectedContractFingerprint
}

function Format-BackendLaunchCompatibilityMismatch($Health, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint) {
  return "MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $Health.contract_fingerprint) does not match expected $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). Source revision was $(Format-SourceRevisionForDiagnostic $Health.source_revision), expected $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision)."
}

function New-RuntimeKey([string]$BackendUrl, [string]$DashboardOrigin, [string]$ContractFingerprint) {
  $backend = if ([string]::IsNullOrWhiteSpace($BackendUrl)) { "none" } else { $BackendUrl.TrimEnd("/").ToLowerInvariant() }
  $dashboard = if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) { "none" } else { $DashboardOrigin.TrimEnd("/").ToLowerInvariant() }
  $contract = if ([string]::IsNullOrWhiteSpace($ContractFingerprint)) { "unknown" } else { $ContractFingerprint.Trim().ToLowerInvariant() }
  return "contract=$contract;backend=$backend;dashboard=$dashboard"
}

function Get-RuntimeStateKey($State) {
  if ($null -eq $State) {
    return $null
  }

  if ($State.PSObject.Properties["runtime_key"] -and -not [string]::IsNullOrWhiteSpace([string]$State.runtime_key)) {
    return [string]$State.runtime_key
  }

  $contractFingerprint = $null
  if ($null -ne $State.backend -and $State.backend.PSObject.Properties["contract_fingerprint"]) {
    $contractFingerprint = [string]$State.backend.contract_fingerprint
  }

  if ($null -eq $State.backend) {
    return $null
  }

  return New-RuntimeKey ([string]$State.backend.url) ([string]$State.frontend.origin) $contractFingerprint
}

function Format-SourceRevisionForDiagnostic([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return "unknown"
  }

  return $Revision
}

function Format-McpContractFingerprintForDiagnostic([string]$Fingerprint) {
  $fingerprint = Normalize-McpContractFingerprint $Fingerprint
  if ([string]::IsNullOrWhiteSpace($fingerprint)) {
    return "unknown"
  }

  return $fingerprint
}

function Write-CompatibleSourceMismatchDiagnostic([string]$Url, $Health, [string]$ExpectedSourceRevision) {
  if ($null -eq $Health -or [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return
  }

  if ([string]::IsNullOrWhiteSpace([string]$Health.source_revision)) {
    Write-Diagnostic "Reusing compatible Symphony++ backend $Url with unknown source revision because MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $Health.contract_fingerprint) matches this launcher."
    return
  }

  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Health.source_revision, $ExpectedSourceRevision)) {
    Write-Diagnostic "Reusing compatible Symphony++ backend $Url even though source revision $(Format-SourceRevisionForDiagnostic $Health.source_revision) differs from expected $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision); MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $Health.contract_fingerprint) matches this launcher."
  }
}

function Set-SymppSourceRevisionEnvironment([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return
  }

  $env:SYMPP_SOURCE_REVISION = $Revision
  [Environment]::SetEnvironmentVariable("SYMPP_SOURCE_REVISION", $Revision, "Process")
}

function Test-HealthySymppDashboard([string]$DashboardOrigin) {
  if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    return $false
  }

  $url = $DashboardOrigin.TrimEnd("/") + $BoardPath
  try {
    $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 -and [string]$response.Content -match "Symphony\+\+ Dashboard"
  } catch {
    return $false
  }
}

function Test-SymppDashboardMcpProxyMatches([string]$DashboardOrigin, [string]$ExpectedContractFingerprint) {
  if ([string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)) {
    return $false
  }

  $proxyHealth = Get-SymppBackendHealthWithRetry $DashboardOrigin 2 250
  return Test-BackendContractMatches $proxyHealth $ExpectedContractFingerprint
}

function Get-PortFromOrigin([string]$Origin) {
  try {
    $uri = [System.Uri]::new($Origin)
    return [int]$uri.Port
  } catch {
    return $null
  }
}

function Read-RuntimeState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-RuntimeState([string]$Path, $State) {
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $json = $State | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($Path, "$json`n", $utf8NoBom)
}

function Resolve-BridgeLeaseDir([string]$RuntimeFile) {
  return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $RuntimeFile) "codex-plugin-leases"))
}

function New-BridgeLease([string]$RuntimeFile, $BackendPlan, $DashboardPlan, [string]$RuntimeKey) {
  $leaseDir = Resolve-BridgeLeaseDir $RuntimeFile
  New-Item -ItemType Directory -Path $leaseDir -Force | Out-Null
  $leasePath = Join-Path $leaseDir ("bridge-$PID-$([guid]::NewGuid().ToString('N')).json")
  $lease = [pscustomobject]@{
    pid = $PID
    created_at = (Get-Date).ToString("o")
    runtime_key = $RuntimeKey
    runtime_kind = if ($BackendPlan.managed -eq $true) { "managed" } else { [string]$BackendPlan.status }
    source_revision = $BackendPlan.source_revision
    backend_url = $BackendPlan.url
    dashboard_origin = $DashboardPlan.origin
  }
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($leasePath, (($lease | ConvertTo-Json -Depth 8) + "`n"), $utf8NoBom)
  return $leasePath
}

function Remove-BridgeLease([string]$LeasePath) {
  if (-not [string]::IsNullOrWhiteSpace($LeasePath)) {
    Remove-Item -LiteralPath $LeasePath -Force -ErrorAction SilentlyContinue
  }
}

function Get-ProcessCommandLine([int]$ProcessId) {
  if ($ProcessId -le 0) {
    return $null
  }

  $cim = Get-Command Get-CimInstance -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cim) {
    try {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
      if ($process) {
        return [string]$process.CommandLine
      }
    } catch {
    }
  }

  $procCmdline = "/proc/$ProcessId/cmdline"
  if (Test-Path -LiteralPath $procCmdline) {
    try {
      $raw = [System.IO.File]::ReadAllText($procCmdline)
      $text = ($raw -replace [char]0, " ").Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        return $text
      }
    } catch {
    }
  }

  return $null
}

function Test-ProcessAlive([int]$ProcessId) {
  if ($ProcessId -le 0) {
    return $false
  }

  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Test-BridgeLeaseActive($Lease) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["pid"]) {
    return $false
  }

  $leasePid = 0
  if (-not [int]::TryParse([string]$Lease.pid, [ref]$leasePid) -or $leasePid -le 0) {
    return $false
  }

  if (-not (Test-ProcessAlive $leasePid)) {
    return $false
  }

  $commandLine = Get-ProcessCommandLine $leasePid
  return -not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine -match "start-sympp-mcp\.(ps1|cmd)"
}

function Get-ActiveBridgeLeases([string]$RuntimeFile) {
  $leaseDir = Resolve-BridgeLeaseDir $RuntimeFile
  if (-not (Test-Path -LiteralPath $leaseDir -PathType Container)) {
    return @()
  }

  $active = [System.Collections.Generic.List[object]]::new()
  foreach ($leasePath in @(Get-ChildItem -LiteralPath $leaseDir -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue)) {
    $lease = $null
    try {
      $lease = Get-Content -LiteralPath $leasePath.FullName -Raw | ConvertFrom-Json
    } catch {
    }

    if (Test-BridgeLeaseActive $lease) {
      $active.Add([pscustomobject]@{ path = $leasePath.FullName; lease = $lease })
    } else {
      Remove-Item -LiteralPath $leasePath.FullName -Force -ErrorAction SilentlyContinue
    }
  }

  return @($active)
}

function Test-BridgeLeaseMatchesRuntimeKey($Lease, [string]$RuntimeKey) {
  if ($null -eq $Lease -or [string]::IsNullOrWhiteSpace($RuntimeKey)) {
    return $false
  }

  if (-not $Lease.PSObject.Properties["runtime_key"] -or [string]::IsNullOrWhiteSpace([string]$Lease.runtime_key)) {
    return $false
  }

  return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Lease.runtime_key, $RuntimeKey)
}

function Test-ActiveLegacyBridgeLease($ActiveLeases) {
  foreach ($activeLease in @($ActiveLeases)) {
    $lease = $activeLease.lease
    if ($null -eq $lease -or -not $lease.PSObject.Properties["runtime_key"] -or [string]::IsNullOrWhiteSpace([string]$lease.runtime_key)) {
      return $true
    }
  }

  return $false
}

function Test-ActiveBridgeLeaseForRuntimeKey($ActiveLeases, [string]$RuntimeKey) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesRuntimeKey $activeLease.lease $RuntimeKey) {
      return $true
    }
  }

  return $false
}

function Stop-ManagedRuntimeProcess([string]$Role, $ProcessIdValue, [int]$Port) {
  $managedPid = 0
  if (-not [int]::TryParse([string]$ProcessIdValue, [ref]$managedPid) -or $managedPid -le 0) {
    return $false
  }

  $commandLine = Get-ProcessCommandLine $managedPid
  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    Write-Diagnostic "Skipping $Role shutdown for pid=$managedPid because its command line could not be verified."
    return $false
  }

  $rolePattern = if ($Role -eq "backend") { "sympp\.cockpit" } else { "vite" }
  $portPattern = if ($Port -gt 0) { "(--port\s+$Port|--port\s+`"$Port`")" } else { $null }
  if ($commandLine -notmatch $rolePattern -or ($portPattern -and $commandLine -notmatch $portPattern)) {
    Write-Diagnostic "Skipping $Role shutdown for pid=$managedPid because it no longer matches the managed Symphony++ command."
    return $false
  }

  Write-Diagnostic "Stopping managed Symphony++ $Role pid=$managedPid after last Codex MCP bridge exited."
  $process = Get-Process -Id $managedPid -ErrorAction SilentlyContinue
  Stop-Process -Id $managedPid -Force -ErrorAction SilentlyContinue
  if ($process) {
    try {
      [void]$process.WaitForExit(5000)
    } catch {
    }
  }
  return $true
}

function Get-RuntimeEntryPort($Entry) {
  $port = 0
  if ($null -ne $Entry) {
    [void][int]::TryParse([string]$Entry.port, [ref]$port)
  }

  return $port
}

function Stop-ManagedRuntimeEntry([string]$Role, $Entry) {
  if ($null -eq $Entry -or $Entry.managed -ne $true) {
    return $false
  }

  $entryPort = Get-RuntimeEntryPort $Entry
  $managedPid = 0
  if (-not [int]::TryParse([string]$Entry.pid, [ref]$managedPid) -or $managedPid -le 0) {
    $listenerPid = if ($entryPort -gt 0) { Get-ManagedListenerPid $Role $entryPort } else { $null }
    if ($listenerPid) {
      Write-Diagnostic "Pruning stale managed Symphony++ $Role runtime entry with missing pid; matching listener pid=$listenerPid remains unmanaged because ownership cannot be proven from the stale record."
    } else {
      Write-Diagnostic "Pruning stale managed Symphony++ $Role runtime entry with missing pid."
    }

    return $true
  }

  if (-not (Test-ProcessAlive $managedPid)) {
    $listenerPid = if ($entryPort -gt 0) { Get-ManagedListenerPid $Role $entryPort } else { $null }
    if ($listenerPid) {
      Write-Diagnostic "Pruning stale managed Symphony++ $Role runtime entry for exited pid=$managedPid; matching listener pid=$listenerPid remains unmanaged because ownership cannot be proven from the stale record."
    } else {
      Write-Diagnostic "Pruning stale managed Symphony++ $Role runtime entry for exited pid=$managedPid."
    }

    return $true
  }

  return Stop-ManagedRuntimeProcess $Role $managedPid $entryPort
}

function Test-RuntimeStateExternalLoopback($RuntimeState) {
  if ($null -eq $RuntimeState) {
    return $false
  }

  if ($null -eq $RuntimeState.backend -or $null -eq $RuntimeState.frontend -or
      $RuntimeState.backend.managed -eq $true -or $RuntimeState.frontend.managed -eq $true) {
    return $false
  }

  return [string]$RuntimeState.backend.status -eq "external_loopback" -and
    [string]$RuntimeState.frontend.status -eq "external_loopback"
}

function Test-RuntimeEntryEndpointMatches([string]$Role, $Entry, [string]$Endpoint) {
  if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($Endpoint)) {
    return $false
  }

  $entryEndpoint = if ($Role -eq "backend") { [string]$Entry.url } else { [string]$Entry.origin }
  return -not [string]::IsNullOrWhiteSpace($entryEndpoint) -and
    $entryEndpoint.TrimEnd("/") -eq $Endpoint.TrimEnd("/")
}

function Test-ArtifactBackendProvidesDashboard($RuntimeState, $BackendPlan, [string]$RuntimeMode) {
  if ($RuntimeMode -eq "artifact") {
    return $true
  }

  return $BackendPlan.reused -eq $true -and
    $BackendPlan.should_start -ne $true -and
    $null -ne $RuntimeState -and
    $RuntimeState.PSObject.Properties["runtime_kind"] -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$RuntimeState.runtime_kind, "artifact") -and
    (Test-RuntimeEntryEndpointMatches "backend" $RuntimeState.backend $BackendPlan.url)
}

function Test-ManagedRuntimeEntrySuperseded([string]$Role, $Entry, [string]$SelectedEndpoint) {
  if ($null -eq $Entry -or $Entry.managed -ne $true) {
    return $false
  }

  $entryEndpoint = if ($Role -eq "backend") { [string]$Entry.url } else { [string]$Entry.origin }
  if ([string]::IsNullOrWhiteSpace($entryEndpoint)) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($SelectedEndpoint)) {
    return $true
  }

  return $entryEndpoint.TrimEnd("/") -ne $SelectedEndpoint.TrimEnd("/")
}

function Test-PortSelectionAllowsReuse([int]$PreferredPort, [string]$Endpoint, [bool]$EnforcePreferredPort) {
  if (-not $EnforcePreferredPort -or $PreferredPort -eq 0) {
    return $true
  }

  return (Get-PortFromOrigin $Endpoint) -eq $PreferredPort
}

function Test-RuntimeEntryExternalOverride($Entry, [string]$Endpoint, [string]$Role) {
  if ($null -eq $Entry -or [string]$Entry.status -ne "external_override") {
    return $false
  }

  return Test-RuntimeEntryEndpointMatches $Role $Entry $Endpoint
}

function Test-EndpointMatches([string]$RecordedEndpoint, [string]$ExpectedEndpoint) {
  return -not [string]::IsNullOrWhiteSpace($RecordedEndpoint) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedEndpoint) -and
    $RecordedEndpoint.TrimEnd("/") -eq $ExpectedEndpoint.TrimEnd("/")
}

function Test-BridgeLeaseMatchesBackend($Lease, [string]$BackendUrl) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["backend_url"]) {
    return $false
  }

  return Test-EndpointMatches ([string]$Lease.backend_url) $BackendUrl
}

function Test-BridgeLeaseMatchesDashboard($Lease, [string]$DashboardOrigin) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["dashboard_origin"]) {
    return $false
  }

  return Test-EndpointMatches ([string]$Lease.dashboard_origin) $DashboardOrigin
}

function Test-ActiveBridgeLeaseForBackend($ActiveLeases, [string]$BackendUrl) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesBackend $activeLease.lease $BackendUrl) {
      return $true
    }
  }

  return $false
}

function Test-ActiveBridgeLeaseForDashboard($ActiveLeases, [string]$DashboardOrigin) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesDashboard $activeLease.lease $DashboardOrigin) {
      return $true
    }
  }

  return $false
}

function New-SupersededRuntimeState($RuntimeState, $BackendPlan, $DashboardPlan) {
  $backend = $null
  $frontend = $null
  $runtimeKey = $null
  if ($null -ne $RuntimeState) {
    if (Test-ManagedRuntimeEntrySuperseded "backend" $RuntimeState.backend ([string]$BackendPlan.url)) {
      $backend = $RuntimeState.backend
    }
    if (Test-ManagedRuntimeEntrySuperseded "frontend" $RuntimeState.frontend ([string]$DashboardPlan.origin)) {
      $frontend = $RuntimeState.frontend
    }
    if ($null -ne $backend -or $null -ne $frontend) {
      $runtimeKey = Get-RuntimeStateKey $RuntimeState
    }
  }

  return [pscustomobject]@{
    runtime_key = $runtimeKey
    backend = $backend
    frontend = $frontend
  }
}

function Get-SupersededRuntimeKey($Superseded) {
  if ($null -eq $Superseded -or -not $Superseded.PSObject.Properties["runtime_key"]) {
    return $null
  }

  $runtimeKey = [string]$Superseded.runtime_key
  if ([string]::IsNullOrWhiteSpace($runtimeKey)) {
    return $null
  }

  return $runtimeKey
}

function Test-SupersededRuntimeStateHasEntries($Superseded) {
  return $null -ne $Superseded -and ($null -ne $Superseded.backend -or $null -ne $Superseded.frontend)
}

function Get-SupersededRuntimeStates($State) {
  $states = [System.Collections.ArrayList]::new()
  $seen = @{}
  if ($null -eq $State) {
    return @()
  }

  foreach ($entry in @($State.superseded_runtimes)) {
    if (-not (Test-SupersededRuntimeStateHasEntries $entry)) {
      continue
    }

    $runtimeKey = Get-SupersededRuntimeKey $entry
    if (-not [string]::IsNullOrWhiteSpace($runtimeKey)) {
      if ($seen.ContainsKey($runtimeKey)) {
        continue
      }
      $seen[$runtimeKey] = $true
    }

    [void]$states.Add($entry)
  }

  if ($State.PSObject.Properties["superseded"] -and (Test-SupersededRuntimeStateHasEntries $State.superseded)) {
    $runtimeKey = Get-SupersededRuntimeKey $State.superseded
    if ([string]::IsNullOrWhiteSpace($runtimeKey) -or -not $seen.ContainsKey($runtimeKey)) {
      [void]$states.Add($State.superseded)
    }
  }

  return @($states)
}

function Merge-SupersededRuntimeStates($Existing, $Candidate) {
  $states = [System.Collections.ArrayList]::new()
  $seen = @{}
  foreach ($entry in @($Candidate) + @($Existing)) {
    if (-not (Test-SupersededRuntimeStateHasEntries $entry)) {
      continue
    }

    $runtimeKey = Get-SupersededRuntimeKey $entry
    if (-not [string]::IsNullOrWhiteSpace($runtimeKey)) {
      if ($seen.ContainsKey($runtimeKey)) {
        continue
      }
      $seen[$runtimeKey] = $true
    }

    [void]$states.Add($entry)
  }

  return @($states)
}

function Set-SupersededRuntimeStates($State, $SupersededStates) {
  if ($null -eq $State) {
    return
  }

  $states = @($SupersededStates | Where-Object { Test-SupersededRuntimeStateHasEntries $_ })
  $legacyState = if ($states.Count -gt 0) { $states[0] } else { $null }
  $State | Add-Member -NotePropertyName superseded -NotePropertyValue $legacyState -Force
  $State | Add-Member -NotePropertyName superseded_runtimes -NotePropertyValue $states -Force
}

function Stop-SupersededManagedServersIfUnused([string]$RuntimeFile, $Superseded) {
  if ($null -eq $Superseded) {
    return $Superseded
  }

  $activeLeases = @(Get-ActiveBridgeLeases $RuntimeFile)
  if (Test-ActiveLegacyBridgeLease $activeLeases) {
    return $Superseded
  }

  if (-not (Test-ActiveBridgeLeaseForDashboard $activeLeases ([string]$Superseded.frontend.origin)) -and
      (Stop-ManagedRuntimeEntry "frontend" $Superseded.frontend)) {
    $Superseded.frontend = $null
  }
  if (-not (Test-ActiveBridgeLeaseForBackend $activeLeases ([string]$Superseded.backend.url)) -and
      (Stop-ManagedRuntimeEntry "backend" $Superseded.backend)) {
    $Superseded.backend = $null
  }

  return $Superseded
}

function Stop-SupersededRuntimeStatesIfUnused([string]$RuntimeFile, $SupersededStates) {
  $remaining = [System.Collections.ArrayList]::new()
  foreach ($superseded in @($SupersededStates)) {
    $updated = Stop-SupersededManagedServersIfUnused $RuntimeFile $superseded
    if (Test-SupersededRuntimeStateHasEntries $updated) {
      [void]$remaining.Add($updated)
    }
  }

  return @($remaining)
}

function Stop-ManagedRuntimeStateEntries($State, [string]$PreserveBackendUrl = $null, [string]$PreserveDashboardOrigin = $null) {
  $stoppedAny = $false
  if ($null -eq $State) {
    return $false
  }

  $supersededStates = [System.Collections.ArrayList]::new()
  foreach ($superseded in @(Get-SupersededRuntimeStates $State)) {
    if (-not (Test-RuntimeEntryEndpointMatches "frontend" $superseded.frontend $PreserveDashboardOrigin) -and
        (Stop-ManagedRuntimeEntry "frontend" $superseded.frontend)) {
      $superseded.frontend = $null
      $stoppedAny = $true
    }
    if (-not (Test-RuntimeEntryEndpointMatches "backend" $superseded.backend $PreserveBackendUrl) -and
        (Stop-ManagedRuntimeEntry "backend" $superseded.backend)) {
      $superseded.backend = $null
      $stoppedAny = $true
    }
    if (Test-SupersededRuntimeStateHasEntries $superseded) {
      [void]$supersededStates.Add($superseded)
    }
  }
  Set-SupersededRuntimeStates $State $supersededStates

  if (-not (Test-RuntimeEntryEndpointMatches "frontend" $State.frontend $PreserveDashboardOrigin) -and
      (Stop-ManagedRuntimeEntry "frontend" $State.frontend)) {
    $State.frontend.status = "stopped"
    $State.frontend.pid = $null
    $stoppedAny = $true
  }

  if (-not (Test-RuntimeEntryEndpointMatches "backend" $State.backend $PreserveBackendUrl) -and
      (Stop-ManagedRuntimeEntry "backend" $State.backend)) {
    $State.backend.status = "stopped"
    $State.backend.pid = $null
    $stoppedAny = $true
  }

  return $stoppedAny
}

function Stop-CurrentManagedRuntimeStateEntries($State, $ActiveLeases) {
  $stoppedAny = $false
  if ($null -eq $State) {
    return $false
  }

  if (-not (Test-ActiveBridgeLeaseForDashboard $ActiveLeases ([string]$State.frontend.origin)) -and
      (Stop-ManagedRuntimeEntry "frontend" $State.frontend)) {
    $State.frontend.status = "stopped"
    $State.frontend.pid = $null
    $stoppedAny = $true
  }

  if (-not (Test-ActiveBridgeLeaseForBackend $ActiveLeases ([string]$State.backend.url)) -and
      (Stop-ManagedRuntimeEntry "backend" $State.backend)) {
    $State.backend.status = "stopped"
    $State.backend.pid = $null
    $stoppedAny = $true
  }

  return $stoppedAny
}

function Get-ManagedListenerPid([string]$Role, [int]$Port) {
  $rolePattern = if ($Role -eq "backend") { "sympp\.cockpit" } else { "vite" }
  foreach ($owner in @(Get-TcpPortOwners $Port)) {
    $commandLine = Get-ProcessCommandLine ([int]$owner.pid)
    if (-not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine -match $rolePattern) {
      return [int]$owner.pid
    }
  }

  return $null
}

function Stop-ManagedServersIfUnused([string]$RuntimeFile, [string]$RuntimeKey) {
  $lock = Enter-FileLock (Resolve-StartupLockFile $RuntimeFile) 30
  try {
    $activeLeases = @(Get-ActiveBridgeLeases $RuntimeFile)
    if ((Test-ActiveLegacyBridgeLease $activeLeases) -or (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases $RuntimeKey)) {
      return
    }

    $state = Read-RuntimeState $RuntimeFile
    if ($null -eq $state) {
      return
    }

    $stateKey = Get-RuntimeStateKey $state
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($stateKey, $RuntimeKey)) {
      [void](Stop-CurrentManagedRuntimeStateEntries $state $activeLeases)
    }
    $supersededStates = Stop-SupersededRuntimeStatesIfUnused $RuntimeFile (Get-SupersededRuntimeStates $state)
    Set-SupersededRuntimeStates $state $supersededStates

    Write-RuntimeState $RuntimeFile $state
  } finally {
    Exit-FileLock $lock
  }
}

function Start-LoggedProcess([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [hashtable]$Environment, [string]$LogPrefix, [string]$LogDir) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdoutPath = Join-Path $LogDir "$LogPrefix-$stamp.out.log"
  $stderrPath = Join-Path $LogDir "$LogPrefix-$stamp.err.log"
  $startCommand = Get-StartProcessCommand $FilePath $ArgumentList

  $oldEnvironment = @{}
  foreach ($key in @($Environment.Keys)) {
    $oldEnvironment[$key] = [Environment]::GetEnvironmentVariable([string]$key, "Process")
    [Environment]::SetEnvironmentVariable([string]$key, [string]$Environment[$key], "Process")
  }

  try {
    $startArgs = @{
      FilePath = $startCommand.file
      ArgumentList = (Join-ProcessArgumentList @($startCommand.args))
      WorkingDirectory = $WorkingDirectory
      RedirectStandardOutput = $stdoutPath; RedirectStandardError = $stderrPath; PassThru = $true
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $startArgs["WindowStyle"] = "Hidden" }
    $process = Start-Process @startArgs
  } finally {
    foreach ($key in @($Environment.Keys)) {
      [Environment]::SetEnvironmentVariable([string]$key, $oldEnvironment[$key], "Process")
    }
  }

  return [pscustomobject]@{
    process = $process
    stdout = $stdoutPath
    stderr = $stderrPath
  }
}

function Stop-LoggedProcess($Launch) {
  if ($null -eq $Launch -or $null -eq $Launch.process -or $Launch.process.HasExited) {
    return
  }

  Stop-Process -Id $Launch.process.Id -Force -ErrorAction SilentlyContinue
  try {
    [void]$Launch.process.WaitForExit(5000)
  } catch {
  }
}

function Wait-Until([scriptblock]$Predicate, [int]$TimeoutSec) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if (& $Predicate) {
      return $true
    }
    Start-Sleep -Milliseconds 500
  }

  return $false
}

function New-ReusedBackendPlan([string]$Status, [string]$Url, $Health, [bool]$Managed, $ProcessId) {
  $url = $Url.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    url = $url
    mcp_url = "$url/mcp"
    port = Get-PortFromOrigin $url
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $ProcessId
    source_revision = $Health.source_revision
    contract_fingerprint = $Health.contract_fingerprint
  }
}

function Resolve-BackendPlan([int]$PreferredPort, [string]$ConfiguredUrl, $RuntimeState, [int]$PortReleaseTimeoutSec, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$EnforcePreferredPort, [int[]]$AvoidPorts = @()) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredUrl)) {
    $url = $ConfiguredUrl.TrimEnd("/")
    Assert-LoopbackHttpOrigin $url "SYMPP_BACKEND_URL"
    $health = Get-SymppBackendHealthWithRetry $url
    if (-not $health.healthy) {
      throw "SYMPP_BACKEND_URL is not a healthy Symphony++ backend: $url"
    }
    if (-not (Test-BackendLaunchCompatible $health $ExpectedContractFingerprint)) {
      throw "SYMPP_BACKEND_URL is healthy but not compatible with this launcher: $(Format-BackendLaunchCompatibilityMismatch $health $ExpectedSourceRevision $ExpectedContractFingerprint): $url"
    }

    Write-CompatibleSourceMismatchDiagnostic $url $health $ExpectedSourceRevision
    return New-ReusedBackendPlan "external_override" $url $health $false $null
  }

  $selectedPort = $null
  if ($PreferredPort -gt 0) {
    $preferredUrl = "http://127.0.0.1:$PreferredPort"
    $preferredHealth = Get-SymppBackendHealthWithRetry $preferredUrl
    $preferredEntry = if ($null -ne $RuntimeState) { $RuntimeState.backend } else { $null }
    if ($preferredHealth.healthy) {
      if (Test-RuntimeEntryExternalOverride $preferredEntry $preferredUrl "backend") {
        Write-Diagnostic "Ignoring recorded external backend $preferredUrl for implicit reuse. Set SYMPP_BACKEND_URL=$preferredUrl to reuse it explicitly."
      } elseif (Test-BackendLaunchCompatible $preferredHealth $ExpectedContractFingerprint) {
        $managed = $false
        $entryPid = $null
        $status = "external_loopback"
        if (Test-RuntimeEntryEndpointMatches "backend" $preferredEntry $preferredUrl) {
          $managed = $preferredEntry.managed -eq $true
          $entryPid = $preferredEntry.pid
          if ($managed) {
            $status = "reused"
          }
        }
        Write-CompatibleSourceMismatchDiagnostic $preferredUrl $preferredHealth $ExpectedSourceRevision
        return New-ReusedBackendPlan $status $preferredUrl $preferredHealth $managed $entryPid
      } else {
        Write-Diagnostic "Ignoring healthy Symphony++ backend $preferredUrl because $(Format-BackendLaunchCompatibilityMismatch $preferredHealth $ExpectedSourceRevision $ExpectedContractFingerprint)"
      }
      $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
    }
  }

  if ($null -ne $RuntimeState -and $null -ne $RuntimeState.backend) {
    $runtimeUrl = [string]$RuntimeState.backend.url
    if (-not [string]::IsNullOrWhiteSpace($runtimeUrl)) {
      $runtimeUrl = $runtimeUrl.TrimEnd("/")
      $runtimeHealth = Get-SymppBackendHealthWithRetry $runtimeUrl
      $runtimeManaged = $RuntimeState.backend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeUrl $EnforcePreferredPort
      if ($runtimeManaged -and $portAllowed -and $runtimeHealth.healthy -and (Test-BackendLaunchCompatible $runtimeHealth $ExpectedContractFingerprint)) {
        Write-CompatibleSourceMismatchDiagnostic $runtimeUrl $runtimeHealth $ExpectedSourceRevision
        return New-ReusedBackendPlan "reused" $runtimeUrl $runtimeHealth ($RuntimeState.backend.managed -eq $true) $RuntimeState.backend.pid
      }

      if ($runtimeHealth.healthy -and -not (Test-BackendLaunchCompatible $runtimeHealth $ExpectedContractFingerprint)) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because $(Format-BackendLaunchCompatibilityMismatch $runtimeHealth $ExpectedSourceRevision $ExpectedContractFingerprint)"
      } elseif ($runtimeHealth.healthy -and -not $runtimeManaged) {
        Write-Diagnostic "Ignoring recorded external backend $runtimeUrl for implicit reuse. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      } elseif ($runtimeHealth.healthy -and -not $portAllowed) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because SYMPP_BACKEND_PORT requests $PreferredPort. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      }
    }
  }

  if ($null -eq $selectedPort -and $PreferredPort -gt 0) {
    $portRelease = Wait-ForTcpPortRelease $PreferredPort $PortReleaseTimeoutSec
    if (-not $portRelease.released) {
      if (Test-SymppBackendOwners @($portRelease.owners)) {
        $busyHealth = Get-SymppBackendHealthWithRetry "http://127.0.0.1:$PreferredPort" 6 750
        if ($busyHealth.healthy -and (Test-BackendLaunchCompatible $busyHealth $ExpectedContractFingerprint)) {
          Write-CompatibleSourceMismatchDiagnostic "http://127.0.0.1:$PreferredPort" $busyHealth $ExpectedSourceRevision
          return New-ReusedBackendPlan "external_loopback" "http://127.0.0.1:$PreferredPort" $busyHealth $false $null
        }
        if ($busyHealth.mcp_ready) {
          Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) The occupied Symphony++ backend responded to MCP but is not a healthy compatible runtime (status=$($busyHealth.status), source=$(Format-SourceRevisionForDiagnostic $busyHealth.source_revision), contract=$(Format-McpContractFingerprintForDiagnostic $busyHealth.contract_fingerprint)). Selecting a fallback managed backend port for this Codex session."
          $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
        } elseif (-not $EnforcePreferredPort) {
          Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) The occupied Symphony++ backend did not become MCP-ready after the bounded retry window. Selecting a fallback managed backend port for this Codex session."
          $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
        } else {
          throw (New-BackendBusySymppMessage $PreferredPort @($portRelease.owners) $busyHealth)
        }
      } else {
        Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) Selecting a fallback managed backend port for this Codex session."
        $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
      }
    } else {
      $selectedPort = $PreferredPort
    }
  } elseif ($null -eq $selectedPort) {
    $selectedPort = Select-AvailablePort $PreferredPort @($AvoidPorts)
  }

  $url = "http://127.0.0.1:$selectedPort"
  return [pscustomobject]@{
    status = "starting"
    url = $url
    mcp_url = "$url/mcp"
    port = $selectedPort
    should_start = $true
    reused = $false
    managed = $true
    pid = $null
    source_revision = $null
    contract_fingerprint = $null
  }
}

function New-ReusedDashboardPlan([string]$Status, [string]$Origin, [bool]$Managed, $ProcessId) {
  $origin = $Origin.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    origin = $origin
    url = "$origin$BoardPath"
    port = Get-PortFromOrigin $origin
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $ProcessId
  }
}

function New-DisabledDashboardPlan([string]$Status, [string]$Error = $null) {
  return [pscustomobject]@{
    status = $Status
    origin = $null
    url = $null
    port = $null
    should_start = $false
    reused = $false
    managed = $false
    pid = $null
    error = $Error
  }
}

function Resolve-FastAttachRuntimePlan {
  param(
    $RuntimeState,
    [string]$ExpectedSourceRevision,
    [string]$ExpectedContractFingerprint,
    [int]$PreferredBackendPort,
    [int]$PreferredDashboardPort,
    [bool]$BackendPortExplicit,
    [bool]$DashboardPortExplicit,
    [string]$ConfiguredBackendUrl,
    [string]$ConfiguredDashboardOrigin,
    [object]$BackendHealthOverride = $null,
    [object]$DashboardHealthyOverride = $null,
    [object]$DashboardProxyMatchesOverride = $null
  )

  if ($BackendPortExplicit -or $DashboardPortExplicit -or
      -not [string]::IsNullOrWhiteSpace($ConfiguredBackendUrl) -or
      -not [string]::IsNullOrWhiteSpace($ConfiguredDashboardOrigin)) {
    return $null
  }

  if ($null -eq $RuntimeState -or $null -eq $RuntimeState.backend -or $null -eq $RuntimeState.frontend) {
    return $null
  }

  $managedRuntime = $RuntimeState.backend.managed -eq $true -and $RuntimeState.frontend.managed -eq $true
  $externalLoopbackRuntime = Test-RuntimeStateExternalLoopback $RuntimeState
  if (-not $managedRuntime -and -not $externalLoopbackRuntime) {
    return $null
  }

  $backendUrl = [string]$RuntimeState.backend.url
  $dashboardOrigin = [string]$RuntimeState.frontend.origin
  if ([string]::IsNullOrWhiteSpace($backendUrl) -or [string]::IsNullOrWhiteSpace($dashboardOrigin)) {
    return $null
  }

  $backendUrl = $backendUrl.TrimEnd("/")
  $dashboardOrigin = $dashboardOrigin.TrimEnd("/")
  try {
    Assert-LoopbackHttpOrigin $backendUrl "recorded Symphony++ backend"
    Assert-LoopbackHttpOrigin $dashboardOrigin "recorded Symphony++ dashboard"
  } catch {
    return $null
  }

  $artifactRuntimeState = $RuntimeState.PSObject.Properties["runtime_kind"] -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$RuntimeState.runtime_kind, "artifact")
  $dashboardSharesBackendPort = [System.StringComparer]::OrdinalIgnoreCase.Equals($backendUrl, $dashboardOrigin)
  $dashboardPortAllowed = if ($artifactRuntimeState -and $dashboardSharesBackendPort) {
    $true
  } else {
    Test-PortSelectionAllowsReuse $PreferredDashboardPort $dashboardOrigin $true
  }

  if (-not (Test-PortSelectionAllowsReuse $PreferredBackendPort $backendUrl $true) -or
      -not $dashboardPortAllowed) {
    return $null
  }

  $backendHealth = if ($null -ne $BackendHealthOverride) { $BackendHealthOverride } else { Get-SymppBackendHealthWithRetry $backendUrl }
  if (-not (Test-BackendLaunchCompatible $backendHealth $ExpectedContractFingerprint)) {
    return $null
  }
  Write-CompatibleSourceMismatchDiagnostic $backendUrl $backendHealth $ExpectedSourceRevision

  $dashboardHealthy = if ($null -ne $DashboardHealthyOverride) { [bool]$DashboardHealthyOverride } else { Test-HealthySymppDashboard $dashboardOrigin }
  if (-not $dashboardHealthy) {
    return $null
  }

  $dashboardProxyMatches =
    if ($null -ne $DashboardProxyMatchesOverride) {
      [bool]$DashboardProxyMatchesOverride
    } else {
      Test-SymppDashboardMcpProxyMatches $dashboardOrigin $ExpectedContractFingerprint
    }
  if (-not $dashboardProxyMatches) {
    return $null
  }

  $planStatus = if ($managedRuntime) { "fast_attach" } else { "external_loopback" }
  $backendPlan = New-ReusedBackendPlan $planStatus $backendUrl $backendHealth $managedRuntime $RuntimeState.backend.pid
  $dashboardPlan = New-ReusedDashboardPlan $planStatus $dashboardOrigin $managedRuntime $RuntimeState.frontend.pid
  $runtimeKey = New-RuntimeKey $backendPlan.url $dashboardPlan.origin $backendHealth.contract_fingerprint
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals((Get-RuntimeStateKey $RuntimeState), $runtimeKey)) {
    return $null
  }

  return [pscustomobject]@{
    backend_plan = $backendPlan
    dashboard_plan = $dashboardPlan
    runtime_key = $runtimeKey
  }
}

function Resolve-DashboardPlan([int]$PreferredPort, [string]$ConfiguredOrigin, [string]$BackendUrl, [string]$BackendSourceRevision, $RuntimeState, [bool]$EnforcePreferredPort, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$AllowRecordedRuntimeReuse) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredOrigin)) {
    $origin = $ConfiguredOrigin.TrimEnd("/")
    return New-ReusedDashboardPlan "external_override" $origin $false $null
  }

  $backendPort = Get-PortFromOrigin $BackendUrl
  if ($PreferredPort -gt 0 -and $PreferredPort -eq $DefaultDashboardPort -and $backendPort -eq $DefaultBackendPort) {
    $preferredOrigin = "http://127.0.0.1:$PreferredPort"
    if ((Test-HealthySymppDashboard $preferredOrigin) -and (Test-SymppDashboardMcpProxyMatches $preferredOrigin $ExpectedContractFingerprint)) {
      $preferredEntry = if ($null -ne $RuntimeState) { $RuntimeState.frontend } else { $null }
      $managed = $false
      $entryPid = $null
      $status = "external_loopback"
      if (Test-RuntimeEntryExternalOverride $preferredEntry $preferredOrigin "frontend") {
        Write-Diagnostic "Ignoring recorded external dashboard $preferredOrigin for implicit default-port reuse. Set SYMPP_DASHBOARD_ORIGIN=$preferredOrigin to reuse it explicitly."
      } elseif (Test-RuntimeEntryEndpointMatches "frontend" $preferredEntry $preferredOrigin) {
        $managed = $preferredEntry.managed -eq $true
        $entryPid = $preferredEntry.pid
        if ($managed) {
          $status = "reused"
        }

        return New-ReusedDashboardPlan $status $preferredOrigin $managed $entryPid
      } else {
        return New-ReusedDashboardPlan $status $preferredOrigin $managed $entryPid
      }
    }
  }

  if ($AllowRecordedRuntimeReuse -and $null -ne $RuntimeState -and $null -ne $RuntimeState.frontend) {
    $runtimeBackendUrl = [string]$RuntimeState.backend.url
    $runtimeOrigin = [string]$RuntimeState.frontend.origin
    if (-not [string]::IsNullOrWhiteSpace($runtimeBackendUrl) -and
        $runtimeBackendUrl.TrimEnd("/") -eq $BackendUrl.TrimEnd("/")) {
      $runtimeManaged = $RuntimeState.frontend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeOrigin $EnforcePreferredPort
      if ($runtimeManaged -and $portAllowed -and -not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin) -and (Test-SymppDashboardMcpProxyMatches $runtimeOrigin $ExpectedContractFingerprint)) {
        return New-ReusedDashboardPlan "reused" $runtimeOrigin ($RuntimeState.frontend.managed -eq $true) $RuntimeState.frontend.pid
      }
      if (-not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
        if (-not $runtimeManaged) {
          Write-Diagnostic "Ignoring recorded external dashboard $($runtimeOrigin.TrimEnd('/')) for implicit reuse. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        } elseif (-not $portAllowed) {
          Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because SYMPP_DASHBOARD_PORT requests $PreferredPort. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        } elseif (-not (Test-SymppDashboardMcpProxyMatches $runtimeOrigin $ExpectedContractFingerprint)) {
          Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because its MCP proxy does not match expected MCP contract $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). Expected source revision remains $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision)."
        }
      }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
      Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because it was recorded for backend $($runtimeBackendUrl.TrimEnd('/')), not $($BackendUrl.TrimEnd('/'))."
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision) -and
      -not (Test-SourceRevisionEquals $BackendSourceRevision $ExpectedSourceRevision)) {
    Write-Diagnostic "Not starting Symphony++ dashboard assets from source $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision) against compatible backend source $(Format-SourceRevisionForDiagnostic $BackendSourceRevision). MCP bridge will attach backend-only; restart the singleton or set SYMPP_DASHBOARD_ORIGIN to use an operator-owned dashboard."
    return New-DisabledDashboardPlan "disabled_source_drift" "backend_source_revision_mismatch"
  }

  $avoid = if ($backendPort) { @([int]$backendPort) } else { @() }
  $selectedPort = Select-AvailablePort $PreferredPort $avoid
  $origin = "http://127.0.0.1:$selectedPort"
  return [pscustomobject]@{
    status = "starting"
    origin = $origin
    url = "$origin$BoardPath"
    port = $selectedPort
    should_start = $true
    reused = $false
    managed = $true
    pid = $null
  }
}

function Invoke-ElixirSetupCommand([string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string[]]$MixArgs, [string]$LogPrefix, [string]$LogDir, [int]$TimeoutSec) {
  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $MixArgs

  $launch = Start-LoggedProcess $command.file $command.args $ElixirDir @{} $LogPrefix $LogDir
  $completed = $false
  try {
    $completed = $launch.process.WaitForExit($TimeoutSec * 1000)
    if (-not $completed) {
      throw "Timed out after $TimeoutSec seconds."
    }

    if ($launch.process.ExitCode -ne 0) {
      throw "Exited with code $($launch.process.ExitCode)."
    }

    return $launch
  } catch {
    if (-not $completed) {
      Stop-LoggedProcess $launch
    }

    throw "$LogPrefix failed. detail=$($_.Exception.Message) stdout_log=$($launch.stdout) stderr_log=$($launch.stderr)"
  }
}

function Initialize-ElixirRuntime([string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec) {
  Write-Diagnostic "source_fallback_compiling: ensuring Symphony++ Elixir dependencies are available in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("deps.get", "--check-locked") "elixir-deps" $LogDir $TimeoutSec

  Write-Diagnostic "source_fallback_compiling: compiling Symphony++ Elixir runtime in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("compile") "elixir-compile" $LogDir $TimeoutSec
}

function Start-Backend($Plan, [string]$DashboardOrigin, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec, [string]$ExpectedContractFingerprint, $ArtifactRuntime = $null) {
  $args = @("sympp.cockpit", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $args += @("--dashboard-origin", $DashboardOrigin)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $args += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  if ($null -ne $ArtifactRuntime) {
    $command = [pscustomobject]@{
      file = [string]$ArtifactRuntime.entrypoint
      args = $args
      working_directory = [string]$ArtifactRuntime.root
    }
  } else {
    Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
    $sourceCommand = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $args
    $command = [pscustomobject]@{
      file = $sourceCommand.file
      args = $sourceCommand.args
      working_directory = $ElixirDir
    }
  }

  $launch = Start-LoggedProcess $command.file $command.args $command.working_directory @{} "backend-$($Plan.port)" $LogDir
  $ready = Wait-Until { Test-HealthySymppBackend $Plan.url } $TimeoutSec
  if (-not $ready) {
    $portOwners = @(Get-TcpPortOwners ([int]$Plan.port))
    $portDetail = "portOwners=$(Format-PortOwners $portOwners)"
    if ($launch.process.HasExited) {
      throw "Symphony++ backend exited before becoming healthy at $($Plan.url). $portDetail stderr_log=$($launch.stderr)"
    }

    Stop-LoggedProcess $launch
    throw "Symphony++ backend did not become healthy at $($Plan.url) within $TimeoutSec seconds. $portDetail stderr_log=$($launch.stderr)"
  }

  $health = Get-SymppBackendHealthWithRetry $Plan.url
  if (-not (Test-BackendContractMatches $health $ExpectedContractFingerprint)) {
    Stop-LoggedProcess $launch
    throw "Symphony++ backend at $($Plan.url) reported MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $health.contract_fingerprint), expected $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). stderr_log=$($launch.stderr)"
  }

  $listenerPid = Get-ManagedListenerPid "backend" ([int]$Plan.port)
  return [pscustomobject]@{
    pid = if ($listenerPid) { $listenerPid } else { $launch.process.Id }
    stdout = $launch.stdout
    stderr = $launch.stderr
    source_revision = if ($health.healthy) { $health.source_revision } else { $null }
    contract_fingerprint = if ($health.healthy) { $health.contract_fingerprint } else { $null }
  }
}

function Test-FrontendDependenciesAvailable([string]$AssetsDir) {
  foreach ($candidate in @(
      "node_modules/.bin/vite.cmd",
      "node_modules/.bin/vite.ps1",
      "node_modules/.bin/vite"
    )) {
    if (Test-Path -LiteralPath (Join-Path $AssetsDir $candidate)) {
      return $true
    }
  }

  return $false
}

function Install-FrontendDependencies([string]$AssetsDir, [string]$LogDir, [int]$TimeoutSec) {
  if (Test-FrontendDependenciesAvailable $AssetsDir) {
    return $null
  }

  $npm = Resolve-NpmCommand
  $args = if (Test-Path -LiteralPath (Join-Path $AssetsDir "package-lock.json")) {
    @("ci", "--no-audit", "--no-fund")
  } else {
    @("install", "--no-audit", "--no-fund")
  }

  Write-Diagnostic "Installing Symphony++ dashboard dependencies in $AssetsDir because Vite is missing."
  $launch = Start-LoggedProcess $npm $args $AssetsDir @{} "frontend-install" $LogDir
  $completed = $false
  try {
    $completed = $launch.process.WaitForExit($TimeoutSec * 1000)
    if (-not $completed) {
      throw "Timed out after $TimeoutSec seconds."
    }

    if ($launch.process.ExitCode -ne 0) {
      throw "Exited with code $($launch.process.ExitCode)."
    }

    return $launch
  } catch {
    if (-not $completed) {
      Stop-LoggedProcess $launch
    }

    throw "frontend-install failed. detail=$($_.Exception.Message) stdout_log=$($launch.stdout) stderr_log=$($launch.stderr)"
  }
}

function Start-Frontend($Plan, [string]$BackendUrl, [string]$AssetsDir, [string]$LogDir, [int]$TimeoutSec) {
  $npm = Resolve-NpmCommand
  $args = @("run", "dev", "--", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  $launch = Start-LoggedProcess $npm $args $AssetsDir @{ SYMPP_API_ORIGIN = $BackendUrl } "frontend-$($Plan.port)" $LogDir
  $ready = Wait-Until { Test-HealthySymppDashboard $Plan.origin } $TimeoutSec
  if (-not $ready) {
    if ($launch.process.HasExited) {
      throw "Symphony++ dashboard exited before becoming healthy. stderr: $($launch.stderr)"
    }

    Stop-LoggedProcess $launch
    throw "Symphony++ dashboard did not become healthy at $($Plan.origin) within $TimeoutSec seconds. logs: $($launch.stderr)"
  }

  $listenerPid = Get-ManagedListenerPid "frontend" ([int]$Plan.port)
  return [pscustomobject]@{
    pid = if ($listenerPid) { $listenerPid } else { $launch.process.Id }
    stdout = $launch.stdout
    stderr = $launch.stderr
  }
}

function Get-RequestIdForError([string]$Line) {
  try {
    $payload = $Line | ConvertFrom-Json
    if ($payload.PSObject.Properties["id"]) {
      return $payload.id
    }
  } catch {
  }

  return $null
}

function Write-JsonRpcErrorLine([object]$Id, [int]$Code, [string]$Message, [object]$Data = $null) {
  $errorObject = @{
    jsonrpc = "2.0"
    id = $Id
    error = @{
      code = $Code
      message = $Message
    }
  }
  if ($null -ne $Data) {
    $errorObject.error["data"] = $Data
  }

  [Console]::Out.WriteLine(($errorObject | ConvertTo-Json -Depth 12 -Compress))
  [Console]::Out.Flush()
}

function Write-McpResponseLine([string]$Content) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    return
  }

  $line = $Content.Trim() -replace "(`r`n|`n|`r)", ""
  if (-not [string]::IsNullOrWhiteSpace($line)) {
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
  }
}

function Invoke-HttpMcpBridge([string]$McpUrl, [int]$TimeoutSec) {
  $sessionId = $null
  $protocolVersion = $null
  while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
      break
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $requestProtocolVersion = Get-InitializeProtocolVersion $line
    $response = Invoke-McpPost $McpUrl $line $sessionId $protocolVersion $TimeoutSec
    $nextSessionId = Get-ResponseHeaderValue $response.headers "Mcp-Session-Id"
    if (-not [string]::IsNullOrWhiteSpace($nextSessionId)) {
      $sessionId = $nextSessionId
    }

    if (-not $response.ok) {
      Write-JsonRpcErrorLine (Get-RequestIdForError $line) -32000 "Symphony++ HTTP MCP bridge request failed." @{
        statusCode = $response.statusCode
        detail = $response.error
      }
      continue
    }

    if (-not [string]::IsNullOrWhiteSpace($requestProtocolVersion)) {
      $responseProtocolVersion = Get-ResponseProtocolVersion @($response.content_lines)
      if (-not [string]::IsNullOrWhiteSpace($responseProtocolVersion)) {
        $protocolVersion = $responseProtocolVersion
      } else {
        $protocolVersion = $requestProtocolVersion
      }
    }

    foreach ($contentLine in @($response.content_lines)) {
      Write-McpResponseLine $contentLine
    }
  }
}

function Invoke-DirectStdioMcp([string]$RepoRoot, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, $ArtifactRuntime = $null) {
  $mcpArgs = @("sympp.mcp", "--mode", "stdio", "--repo-root", $RepoRoot)
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $mcpArgs += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  if ($null -ne $ArtifactRuntime) {
    Set-Location -LiteralPath ([string]$ArtifactRuntime.root)
    & ([string]$ArtifactRuntime.entrypoint) @($mcpArgs)
    exit $LASTEXITCODE
  }

  Set-Location -LiteralPath $ElixirDir
  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $mcpArgs
  & $command.file @($command.args)
  exit $LASTEXITCODE
}

function Invoke-SelfTest {
  if ((Select-AvailablePort 0) -le 0) {
    throw "Select-AvailablePort did not return an ephemeral port."
  }
  $preferredForAvoidTest = Select-AvailablePort 0
  $fallbackForAvoidTest = Select-AvailablePort $preferredForAvoidTest @($preferredForAvoidTest, ($preferredForAvoidTest + 1))
  if ($fallbackForAvoidTest -eq $preferredForAvoidTest -or $fallbackForAvoidTest -eq ($preferredForAvoidTest + 1)) {
    throw "Select-AvailablePort did not honor avoided fallback ports."
  }

  $headers = [System.Net.WebHeaderCollection]::new()
  $headers.Add("Mcp-Session-Id", "session-one")
  if ((Get-ResponseHeaderValue $headers "mcp-session-id") -ne "session-one") {
    throw "Get-ResponseHeaderValue did not read WebHeaderCollection values case-insensitively."
  }

  if ((Test-EnvDisabled "__SYMPP_SELFTEST_MISSING__") -ne $false) {
    throw "Test-EnvDisabled should treat missing variables as enabled/default."
  }

  $marketplaceSelfTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sympp-plugin-marketplace-cache-$([guid]::NewGuid().ToString('N'))"
  $oldSymppHome = [Environment]::GetEnvironmentVariable("SYMPP_HOME", "Process")
  try {
    $codexHome = Join-Path $marketplaceSelfTestRoot "codex"
    $symppHome = Join-Path $marketplaceSelfTestRoot "sympp-home"
    [Environment]::SetEnvironmentVariable("SYMPP_HOME", $symppHome, "Process")
    $pluginRoot = Join-Path $codexHome "plugins/cache/symphony-plus-plus/symphony-plus-plus-mcp/0.1.0"
    $sourceRoot = Join-Path $codexHome ".tmp/marketplaces/symphony-plus-plus"
    $sourcePluginRoot = Join-Path $sourceRoot "plugins/symphony-plus-plus-mcp"
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot "elixir") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot "plugins/symphony-plus-plus/.codex-plugin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourcePluginRoot ".codex-plugin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourcePluginRoot "scripts") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $pluginRoot ".codex-plugin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $pluginRoot "scripts") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sourceRoot "elixir/mix.exs") -Value "# self-test" -NoNewline
    Set-Content -LiteralPath (Join-Path $sourceRoot "plugins/symphony-plus-plus/.codex-plugin/plugin.json") -Value '{"name":"symphony-plus-plus"}' -NoNewline
    Set-Content -LiteralPath (Join-Path $sourcePluginRoot ".codex-plugin/plugin.json") -Value '{"name":"symphony-plus-plus-mcp"}' -NoNewline
    Set-Content -LiteralPath (Join-Path $pluginRoot ".codex-plugin/plugin.json") -Value '{"name":"symphony-plus-plus-mcp"}' -NoNewline
    foreach ($relativePath in @("scripts/start-sympp-mcp.ps1", "scripts/sympp-launcher-runtime.ps1", "scripts/sympp-mcp-launcher-helpers.ps1")) {
      Set-Content -LiteralPath (Join-Path $sourcePluginRoot $relativePath) -Value "# matching payload" -NoNewline
      Set-Content -LiteralPath (Join-Path $pluginRoot $relativePath) -Value "# matching payload" -NoNewline
    }
    Set-Content -LiteralPath (Join-Path $pluginRoot ".sympp-source-root") -Value (Join-Path $marketplaceSelfTestRoot "stale-dev-checkout") -NoNewline

    if ((Resolve-RepoRootFromMarketplaceCache $pluginRoot) -ne ([System.IO.Path]::GetFullPath($sourceRoot))) {
      throw "Marketplace source discovery should accept a source clone that matches the installed plugin payload and ignore stale source-root hints."
    }

    Set-Content -LiteralPath (Join-Path $pluginRoot "scripts/sympp-launcher-runtime.ps1") -Value "# stale installed payload" -NoNewline
    if ($null -ne (Resolve-RepoRootFromMarketplaceCache $pluginRoot)) {
      throw "Marketplace source discovery should ignore mismatched installed plugin payloads."
    }

    $sourceCacheRoot = Join-Path $symppHome "source-cache/symphony-plus-plus-selftest"
    $staleSourceCacheRoot = Join-Path $symppHome "source-cache/symphony-plus-plus-stale"
    $sourceCachePluginRoot = Join-Path $sourceCacheRoot "plugins/symphony-plus-plus-mcp"
    New-Item -ItemType Directory -Path (Join-Path $sourceCacheRoot "elixir") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceCachePluginRoot ".codex-plugin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceCachePluginRoot "scripts") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sourceCacheRoot "elixir/mix.exs") -Value "# source-cache self-test" -NoNewline
    foreach ($relativePath in @(".codex-plugin/plugin.json", "scripts/start-sympp-mcp.ps1", "scripts/sympp-launcher-runtime.ps1", "scripts/sympp-mcp-launcher-helpers.ps1")) {
      $installedPayload = Get-Content -LiteralPath (Join-Path $pluginRoot $relativePath) -Raw
      Set-Content -LiteralPath (Join-Path $sourceCachePluginRoot $relativePath) -Value $installedPayload -NoNewline
    }

    $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) {
      throw "Source-cache self-test requires git."
    }

    & $git.Source @("-C", $sourceCacheRoot, "init", "-q")
    if ($LASTEXITCODE -ne 0) {
      throw "Source-cache self-test failed to initialize git."
    }

    & $git.Source @("-C", $sourceCacheRoot, "add", ".")
    if ($LASTEXITCODE -ne 0) {
      throw "Source-cache self-test failed to stage git files."
    }

    & $git.Source @("-C", $sourceCacheRoot, "-c", "user.email=sympp-selftest@example.invalid", "-c", "user.name=Symphony Self Test", "commit", "-qm", "source-cache self-test")
    if ($LASTEXITCODE -ne 0) {
      throw "Source-cache self-test failed to commit git files."
    }

    $pinnedRevision = Resolve-SymppSourceRevision $sourceCacheRoot
    if (-not $pinnedRevision) {
      throw "Source-cache self-test failed to resolve the git revision."
    }

    Set-Content -LiteralPath (Join-Path $pluginRoot ".sympp-source-revision") -Value "$pinnedRevision`n" -NoNewline
    Copy-Item -LiteralPath $sourceCacheRoot -Destination $staleSourceCacheRoot -Recurse
    $staleSourceCachePluginRoot = Join-Path $staleSourceCacheRoot "plugins/symphony-plus-plus-mcp"
    Set-Content -LiteralPath (Join-Path $staleSourceCachePluginRoot "scripts/sympp-launcher-runtime.ps1") -Value "# stale source-cache payload" -NoNewline
    (Get-Item -LiteralPath $staleSourceCacheRoot).LastWriteTime = (Get-Date).AddMinutes(1)
    if ((Resolve-RepoRootFromSourceCache $pluginRoot) -ne ([System.IO.Path]::GetFullPath($sourceCacheRoot))) {
      throw "Source-cache discovery should select a clean installed Symphony++ runtime source cache revision and payload."
    }
    if ((Resolve-RepoRootFromPluginRoot $pluginRoot) -ne ([System.IO.Path]::GetFullPath($sourceCacheRoot))) {
      throw "Installed plugin discovery should prefer source-cache over a stale marketplace source clone."
    }

    if ((Resolve-SymppSourceRevision (Join-Path $marketplaceSelfTestRoot "not-a-git-repo") $pluginRoot) -ne $pinnedRevision) {
      throw "Pinned installed source revision should be used when git and marketplace metadata are unavailable."
    }
  } finally {
    [Environment]::SetEnvironmentVariable("SYMPP_HOME", $oldSymppHome, "Process")
    Remove-Item -LiteralPath $marketplaceSelfTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  $old = [Environment]::GetEnvironmentVariable("SYMPP_SELFTEST_FLAG", "Process")
  try {
    [Environment]::SetEnvironmentVariable("SYMPP_SELFTEST_FLAG", "off", "Process")
    if (-not (Test-EnvDisabled "SYMPP_SELFTEST_FLAG")) {
      throw "Test-EnvDisabled did not treat 'off' as disabled."
    }
  } finally {
    [Environment]::SetEnvironmentVariable("SYMPP_SELFTEST_FLAG", $old, "Process")
  }

  $wrapped = Get-StartProcessCommand "C:\Tools\mix.ps1" @("sympp.cockpit")
  if ($wrapped.file -notmatch "^(pwsh|powershell(\.exe)?)$" -or $wrapped.args[4] -ne "C:\Tools\mix.ps1") {
    throw "Get-StartProcessCommand did not wrap PowerShell scripts for Start-Process."
  }

  if ((Convert-SymppProcessorArchitectureToTargetArch "AMD64") -ne "x86_64" -or
      (Convert-SymppProcessorArchitectureToTargetArch "ARM64") -ne "aarch64" -or
      (Convert-SymppProcessorArchitectureToTargetArch "x86") -ne "x86") {
    throw "Convert-SymppProcessorArchitectureToTargetArch did not normalize known Windows architectures."
  }

  $nativeEnvNames = @("PROCESSOR_ARCHITECTURE", "PROCESSOR_ARCHITEW6432", "TARGET_ARCH", "TARGET_OS", "TARGET_ABI")
  $oldNativeEnv = @{}
  foreach ($name in $nativeEnvNames) {
    $oldNativeEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
  }
  try {
    foreach ($name in $nativeEnvNames) {
      [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "x86", "Process")
    [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITEW6432", "AMD64", "Process")
    if ((Get-SymppWindowsProcessorArchitecture) -ne "AMD64") {
      throw "Get-SymppWindowsProcessorArchitecture did not prefer native WOW64 architecture."
    }
    Set-SymppWindowsNativeTargetEnvironment
    if (Test-SymppWindowsPlatform) {
      if ([Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Process") -ne "AMD64") {
        throw "Set-SymppWindowsNativeTargetEnvironment did not normalize WOW64 PROCESSOR_ARCHITECTURE."
      }
      if ([Environment]::GetEnvironmentVariable("TARGET_ARCH", "Process") -ne "x86_64") {
        throw "Set-SymppWindowsNativeTargetEnvironment did not seed the WOW64 native TARGET_ARCH."
      }
    }

    [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITECTURE", $null, "Process")
    [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITEW6432", $null, "Process")
    Set-SymppWindowsNativeTargetEnvironment
    if (Test-SymppWindowsPlatform) {
      $processorArchitecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Process")
      if ([string]::IsNullOrWhiteSpace($processorArchitecture)) {
        throw "Set-SymppWindowsNativeTargetEnvironment did not seed PROCESSOR_ARCHITECTURE."
      }
      if ([Environment]::GetEnvironmentVariable("TARGET_OS", "Process") -ne "windows") {
        throw "Set-SymppWindowsNativeTargetEnvironment did not seed TARGET_OS."
      }
      if ([Environment]::GetEnvironmentVariable("TARGET_ABI", "Process") -ne "msvc") {
        throw "Set-SymppWindowsNativeTargetEnvironment did not seed TARGET_ABI."
      }
      $targetArch = [Environment]::GetEnvironmentVariable("TARGET_ARCH", "Process")
      if ([string]::IsNullOrWhiteSpace($targetArch)) {
        throw "Set-SymppWindowsNativeTargetEnvironment did not seed TARGET_ARCH."
      }
    } elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("TARGET_OS", "Process"))) {
      throw "Set-SymppWindowsNativeTargetEnvironment should not seed target env on non-Windows platforms."
    }

    [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "KEEP_ARCH", "Process")
    [Environment]::SetEnvironmentVariable("TARGET_ARCH", "keep-target", "Process")
    [Environment]::SetEnvironmentVariable("TARGET_OS", "keep-os", "Process")
    [Environment]::SetEnvironmentVariable("TARGET_ABI", "keep-abi", "Process")
    Set-SymppWindowsNativeTargetEnvironment
    if ([Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Process") -ne "KEEP_ARCH" -or
        [Environment]::GetEnvironmentVariable("TARGET_ARCH", "Process") -ne "keep-target" -or
        [Environment]::GetEnvironmentVariable("TARGET_OS", "Process") -ne "keep-os" -or
        [Environment]::GetEnvironmentVariable("TARGET_ABI", "Process") -ne "keep-abi") {
      throw "Set-SymppWindowsNativeTargetEnvironment overwrote explicit native target env."
    }
  } finally {
    foreach ($name in $nativeEnvNames) {
      [Environment]::SetEnvironmentVariable($name, $oldNativeEnv[$name], "Process")
    }
  }

  $joinedArgs = Join-ProcessArgumentList @("--database", "C:\Users\Jane Doe\ledger db.sqlite3", 'value"withquote')
  if ($joinedArgs -notmatch '"C:\\Users\\Jane Doe\\ledger db\.sqlite3"' -or $joinedArgs -notmatch '"value\\"withquote"') {
    throw "Join-ProcessArgumentList did not preserve spaced or quoted arguments."
  }

  Assert-LoopbackHttpOrigin "http://127.0.0.1:19998" "SYMPP_BACKEND_URL"
  $rejectedRemoteOrigin = $false
  try {
    Assert-LoopbackHttpOrigin "http://example.com:19998" "SYMPP_BACKEND_URL"
  } catch {
    $rejectedRemoteOrigin = $true
  }
  if (-not $rejectedRemoteOrigin) {
    throw "Assert-LoopbackHttpOrigin did not reject a remote backend URL."
  }

  $freePortRelease = Wait-ForTcpPortRelease (Select-AvailablePort 0) 0
  if (-not $freePortRelease.released) {
    throw "Wait-ForTcpPortRelease did not recognize a free port."
  }

  $occupiedListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
  try {
    $occupiedListener.Start()
    $occupiedPort = [int]$occupiedListener.LocalEndpoint.Port
    $occupiedRelease = Wait-ForTcpPortRelease $occupiedPort 0
    if ($occupiedRelease.released) {
      throw "Wait-ForTcpPortRelease did not detect an occupied port."
    }

    $occupiedMessage = New-BackendPortOccupiedMessage $occupiedPort @($occupiedRelease.owners)
    if ($occupiedMessage -notmatch "backend_port_occupied" -or $occupiedMessage -notmatch [string]$occupiedPort) {
      throw "New-BackendPortOccupiedMessage did not include the status code and port."
    }
  } finally {
    $occupiedListener.Stop()
  }

  $processLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "sympp-plugin-selftest-process-logs"
  $sleepLaunch = $null
  try {
    $sleepLaunch = Start-LoggedProcess `
      (Get-PowerShellHostCommandName) `
      @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") `
      ([System.IO.Path]::GetTempPath()) `
      @{} `
      "sleep" `
      $processLogDir
    if ($sleepLaunch.process.HasExited) {
      throw "Self-test process exited before Stop-LoggedProcess could stop it."
    }

    Stop-LoggedProcess $sleepLaunch
    if (-not $sleepLaunch.process.HasExited) {
      throw "Stop-LoggedProcess did not terminate the self-test process."
    }
  } finally {
    Stop-LoggedProcess $sleepLaunch
    Remove-Item -LiteralPath $processLogDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  $sseHeaders = @{ "Content-Type" = "text/event-stream; charset=utf-8" }
  $sseContent = "event: message`ndata: {`"jsonrpc`":`"2.0`",`"id`":1,`"result`":{}}`n`n"
  $sseLines = @(Convert-McpHttpContentToJsonLines $sseContent $sseHeaders)
  if ($sseLines.Count -ne 1 -or ($sseLines[0] | ConvertFrom-Json).id -ne 1) {
    throw "SSE MCP response content did not normalize to JSON-RPC lines."
  }

  $sseWebHeaders = [System.Net.WebHeaderCollection]::new()
  $sseWebHeaders.Add("Content-Type", "text/event-stream; charset=utf-8")
  $sseWebHeaderLines = @(Convert-McpHttpContentToJsonLines $sseContent $sseWebHeaders)
  if ($sseWebHeaderLines.Count -ne 1 -or ($sseWebHeaderLines[0] | ConvertFrom-Json).id -ne 1) {
    throw "SSE MCP response WebHeaderCollection content did not normalize to JSON-RPC lines."
  }

  $initializeBody = ConvertTo-JsonBody (New-InitializeRequest)
  if ((Get-InitializeProtocolVersion $initializeBody) -ne "2025-03-26") {
    throw "Initialize protocol version extraction failed."
  }
  $initializeResponse = '{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18"}}'
  if ((Get-ResponseProtocolVersion @($initializeResponse)) -ne "2025-06-18") {
    throw "Response protocol version extraction failed."
  }

  $revisionA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  $revisionB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  $contractA = $ExpectedMcpContractFingerprint
  $contractB = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  $healthyA = [pscustomobject]@{ healthy = $true; source_revision = $revisionA; contract_fingerprint = $contractA }
  $oldSourceRevisionEnv = [Environment]::GetEnvironmentVariable("SYMPP_SOURCE_REVISION", "Process")
  try {
    Set-SymppSourceRevisionEnvironment $revisionA
    if ([Environment]::GetEnvironmentVariable("SYMPP_SOURCE_REVISION", "Process") -ne $revisionA -or $env:SYMPP_SOURCE_REVISION -ne $revisionA) {
      throw "Set-SymppSourceRevisionEnvironment should expose the expected source revision to child backend processes."
    }
  } finally {
    [Environment]::SetEnvironmentVariable("SYMPP_SOURCE_REVISION", $oldSourceRevisionEnv, "Process")
    $env:SYMPP_SOURCE_REVISION = $oldSourceRevisionEnv
  }
  if (-not (Test-BackendContractMatches $healthyA $contractA)) {
    throw "Contract-matching backend health should be reusable."
  }
  if (Test-BackendContractMatches $healthyA $contractB) {
    throw "Incompatible MCP contract fingerprints should not be reusable."
  }
  if (Test-BackendContractMatches $healthyA $null) {
    throw "Backend contract matching should fail closed when the expected fingerprint is unknown."
  }
  if (Test-BackendContractMatches ([pscustomobject]@{ healthy = $true; source_revision = $revisionA }) $contractA) {
    throw "Backends that do not report an MCP contract fingerprint should not be reusable."
  }
  if (Test-BackendContractMatches ([pscustomobject]@{ healthy = $false; source_revision = $revisionA; contract_fingerprint = $contractA }) $contractA) {
    throw "Unhealthy backend should not be contract-matched."
  }
  $degradedA = New-SymppBackendHealth $false $revisionA "health_degraded" $true $true $false "degraded" $contractA
  if (Test-BackendContractMatches $degradedA $contractA) {
    throw "Degraded backend health should not be treated as reusable."
  }
  if (-not (Test-SymppBackendCommandLine "erl.exe -noshell -s mix sympp.cockpit --host 127.0.0.1 --port 19998")) {
    throw "Symphony++ backend command-line detection should recognize sympp.cockpit."
  }
  if (Test-SymppBackendCommandLine "node.exe node_modules/vite/bin/vite.js --host 127.0.0.1") {
    throw "Symphony++ backend command-line detection should not match dashboard Vite."
  }
  $busyMessage = New-BackendBusySymppMessage 19998 @([pscustomobject]@{ pid = 1234; process = "erl"; localAddress = "127.0.0.1" }) (New-SymppBackendHealth $false $null "initialize_failed" $true)
  if ($busyMessage -notmatch "backend_port_busy_sympp_unhealthy" -or $busyMessage -notmatch "initialize_failed") {
    throw "Busy Symphony++ backend diagnostic should include the refusal code and health detail."
  }

  $runtimeKeyA = New-RuntimeKey "http://127.0.0.1:45678/" "http://127.0.0.1:45679/" $contractA
  $runtimeKeyANormalized = New-RuntimeKey "http://127.0.0.1:45678" "http://127.0.0.1:45679" $contractA
  if ($runtimeKeyA -ne $runtimeKeyANormalized -or $runtimeKeyA -notmatch $contractA -or $runtimeKeyA -match $revisionA) {
    throw "Runtime keys should normalize endpoint slashes and include the MCP contract fingerprint instead of the source revision."
  }
  if (-not (Test-PortSelectionAllowsReuse 19998 "http://127.0.0.1:20000" $false)) {
    throw "Implicit port selection should allow existing managed runtime reuse."
  }
  if (Test-PortSelectionAllowsReuse 19998 "http://127.0.0.1:20000" $true) {
    throw "Explicit backend/dashboard port selection should block reuse from another port."
  }
  $externalOverrideEntry = [pscustomobject]@{ status = "external_override"; url = "http://127.0.0.1:19998" }
  if (-not (Test-RuntimeEntryExternalOverride $externalOverrideEntry "http://127.0.0.1:19998/" "backend")) {
    throw "Recorded external override entries should be identifiable by endpoint."
  }
  if (Test-RuntimeEntryExternalOverride $externalOverrideEntry "http://127.0.0.1:20000" "backend") {
    throw "Recorded external override entries should not match different endpoints."
  }
  $reusedBackend = New-ReusedBackendPlan "reused" "http://127.0.0.1:19998/" $healthyA $true 1234
  if ($reusedBackend.pid -ne 1234 -or -not $reusedBackend.managed -or $reusedBackend.url -ne "http://127.0.0.1:19998") {
    throw "Reusable backend plan should preserve managed process metadata."
  }
  $reusedDashboard = New-ReusedDashboardPlan "reused" "http://127.0.0.1:19999/" $true 1235
  if ($reusedDashboard.pid -ne 1235 -or -not $reusedDashboard.managed -or $reusedDashboard.origin -ne "http://127.0.0.1:19999") {
    throw "Reusable dashboard plan should preserve managed process metadata."
  }
  $sourceRuntimeState = [pscustomobject]@{
    runtime_kind = "managed"
    backend = [pscustomobject]@{ url = "http://127.0.0.1:19998" }
  }
  if (Test-ArtifactBackendProvidesDashboard $sourceRuntimeState $reusedBackend "source") {
    throw "Reused source backends should not be treated as artifact static dashboard providers."
  }
  $artifactRuntimeState = [pscustomobject]@{
    runtime_kind = "artifact"
    backend = [pscustomobject]@{ url = "http://127.0.0.1:19998/" }
  }
  if (-not (Test-ArtifactBackendProvidesDashboard $artifactRuntimeState $reusedBackend "source")) {
    throw "Recorded artifact backends should provide the artifact static dashboard when reused."
  }

  $oldRuntimeKey = New-RuntimeKey "http://127.0.0.1:19998" "http://127.0.0.1:19999" $contractA
  $oldRuntimeState = [pscustomobject]@{
    runtime_key = $oldRuntimeKey
    backend = [pscustomobject]@{
      managed = $true
      url = "http://127.0.0.1:19998"
      port = 19998
      pid = 1234
      source_revision = $revisionA
      contract_fingerprint = $contractA
    }
    frontend = [pscustomobject]@{
      managed = $true
      origin = "http://127.0.0.1:19999"
      port = 19999
      pid = 1235
    }
  }
  $fastAttachPlan = Resolve-FastAttachRuntimePlan $oldRuntimeState $revisionB $contractA 19998 19999 $false $false $null $null $healthyA $true $true
  if ($null -eq $fastAttachPlan -or
      $fastAttachPlan.backend_plan.status -ne "fast_attach" -or
      $fastAttachPlan.dashboard_plan.status -ne "fast_attach" -or
      $fastAttachPlan.runtime_key -ne $oldRuntimeKey) {
    throw "MCP-only fast attach should reuse a healthy managed runtime for the same MCP contract fingerprint and default endpoints."
  }
  $sourceDriftDashboardPlan = Resolve-DashboardPlan 20001 $null "http://127.0.0.1:20000" $revisionA $null $false $revisionB $contractA $false
  if ($sourceDriftDashboardPlan.status -ne "disabled_source_drift" -or $sourceDriftDashboardPlan.should_start) {
    throw "Fresh dashboard autostart should be disabled against a source-drifted but contract-compatible backend."
  }
  if ($null -ne (Resolve-FastAttachRuntimePlan $oldRuntimeState $revisionB $contractB 19998 19999 $false $false $null $null $healthyA $true $true)) {
    throw "Fast attach should reject incompatible MCP contract fingerprints."
  }
  if ($null -ne (Resolve-FastAttachRuntimePlan $oldRuntimeState $revisionA $contractA 19998 19999 $true $false $null $null $healthyA $true $true)) {
    throw "Fast attach should not bypass explicit backend port selection."
  }
  if ($null -ne (Resolve-FastAttachRuntimePlan $oldRuntimeState $revisionA $contractA 19998 19999 $false $false $null $null $healthyA $true $false)) {
    throw "Fast attach should reject dashboards whose MCP proxy does not match the expected contract."
  }
  $externalRuntimeState = [pscustomobject]@{
    runtime_key = $oldRuntimeKey
    backend = [pscustomobject]@{ managed = $false; url = "http://127.0.0.1:19998"; port = 19998; pid = 1234; source_revision = $revisionA; contract_fingerprint = $contractA }
    frontend = [pscustomobject]@{ managed = $true; origin = "http://127.0.0.1:19999"; port = 19999; pid = 1235 }
  }
  if ($null -ne (Resolve-FastAttachRuntimePlan $externalRuntimeState $revisionA $contractA 19998 19999 $false $false $null $null $healthyA $true $true)) {
    throw "Fast attach should reject mixed managed/external runtime entries."
  }
  $explicitDashboardRuntimeState = [pscustomobject]@{
    runtime_kind = "external_loopback"
    runtime_key = $oldRuntimeKey
    backend = [pscustomobject]@{ status = "external_loopback"; managed = $false; url = "http://127.0.0.1:19998"; port = 19998; pid = 1234; source_revision = $revisionA; contract_fingerprint = $contractA }
    frontend = [pscustomobject]@{ status = "external_override"; managed = $false; origin = "http://127.0.0.1:19999"; port = 19999; pid = 1235 }
  }
  if ($null -ne (Resolve-FastAttachRuntimePlan $explicitDashboardRuntimeState $revisionA $contractA 19998 19999 $false $false $null $null $healthyA $true $true)) {
    throw "Fast attach should not promote explicit external dashboard origins into implicit external_loopback reuse."
  }
  $externalLoopbackRuntimeState = [pscustomobject]@{
    runtime_kind = "external_loopback"
    runtime_key = $oldRuntimeKey
    backend = [pscustomobject]@{ status = "external_loopback"; managed = $false; url = "http://127.0.0.1:19998"; port = 19998; pid = 1234; source_revision = $revisionA; contract_fingerprint = $contractA }
    frontend = [pscustomobject]@{ status = "external_loopback"; managed = $false; origin = "http://127.0.0.1:19999"; port = 19999; pid = 1235 }
  }
  $externalFastAttachPlan = Resolve-FastAttachRuntimePlan $externalLoopbackRuntimeState $revisionA $contractA 19998 19999 $false $false $null $null $healthyA $true $true
  if ($null -eq $externalFastAttachPlan -or
      $externalFastAttachPlan.backend_plan.status -ne "external_loopback" -or
      $externalFastAttachPlan.backend_plan.managed -or
      $externalFastAttachPlan.dashboard_plan.managed) {
    throw "Fast attach should reuse healthy external_loopback default runtime entries without taking ownership."
  }

  $newBackendPlan = [pscustomobject]@{ url = "http://127.0.0.1:20000" }
  $newDashboardPlan = [pscustomobject]@{ origin = "http://127.0.0.1:20001" }
  $superseded = New-SupersededRuntimeState $oldRuntimeState $newBackendPlan $newDashboardPlan
  if ($null -eq $superseded.backend -or $null -eq $superseded.frontend) {
    throw "Superseded managed runtime entries should be preserved for cleanup."
  }
  if ($superseded.runtime_key -ne $oldRuntimeKey) {
    throw "Superseded runtime state should retain the old runtime key for key-scoped cleanup."
  }
  $olderRuntimeKey = New-RuntimeKey "http://127.0.0.1:19996" "http://127.0.0.1:19997" $contractA
  $olderSuperseded = [pscustomobject]@{
    runtime_key = $olderRuntimeKey
    backend = [pscustomobject]@{ managed = $true; url = "http://127.0.0.1:19996"; port = 19996; pid = 4321 }
    frontend = [pscustomobject]@{ managed = $true; origin = "http://127.0.0.1:19997"; port = 19997; pid = 4322 }
  }
  $mergedSuperseded = @(Merge-SupersededRuntimeStates @($olderSuperseded) $superseded)
  if ($mergedSuperseded.Count -ne 2 -or $mergedSuperseded[0].runtime_key -ne $oldRuntimeKey -or $mergedSuperseded[1].runtime_key -ne $olderRuntimeKey) {
    throw "Superseded runtime merge should retain multiple old runtime keys newest-first."
  }
  $mergedState = [pscustomobject]@{}
  Set-SupersededRuntimeStates $mergedState $mergedSuperseded
  if (@($mergedState.superseded_runtimes).Count -ne 2 -or $mergedState.superseded.runtime_key -ne $oldRuntimeKey) {
    throw "Superseded runtime state should expose both list and newest legacy field."
  }
  if (-not (Test-RuntimeEntryEndpointMatches "backend" $oldRuntimeState.backend "http://127.0.0.1:19998/")) {
    throw "Runtime backend endpoint matching should normalize trailing slashes."
  }
  if (-not (Test-RuntimeEntryEndpointMatches "frontend" $oldRuntimeState.frontend "http://127.0.0.1:19999/")) {
    throw "Runtime frontend endpoint matching should normalize trailing slashes."
  }

  $runtimePath = Join-Path ([System.IO.Path]::GetTempPath()) "sympp-plugin-selftest-runtime.json"
  $staleSuperseded = [pscustomobject]@{
    runtime_key = $olderRuntimeKey
    backend = [pscustomobject]@{ managed = $true; url = "http://127.0.0.1:19996"; port = 19996; pid = 0 }
    frontend = [pscustomobject]@{ managed = $true; origin = "http://127.0.0.1:19997"; port = 19997; pid = 987654321 }
  }
  if (@(Stop-SupersededRuntimeStatesIfUnused $runtimePath @($staleSuperseded)).Count -ne 0) {
    throw "Dead managed superseded runtime entries should be pruned instead of retried forever."
  }

  $state = [pscustomobject]@{
    runtime_key = $oldRuntimeKey
    backend = [pscustomobject]@{
      status = "reused"
      managed = $false
      url = "http://127.0.0.1:$DefaultBackendPort"
      source_revision = $revisionA
      contract_fingerprint = $contractA
    }
    frontend = [pscustomobject]@{ origin = "http://127.0.0.1:$DefaultDashboardPort" }
  }
  Write-RuntimeState $runtimePath $state
  $read = Read-RuntimeState $runtimePath
  if ($read.backend.url -ne $state.backend.url) {
    throw "Runtime state did not round-trip."
  }

  $leasePath = New-BridgeLease $runtimePath $state.backend $state.frontend $oldRuntimeKey
  $activeLeases = @(Get-ActiveBridgeLeases $runtimePath)
  if ($activeLeases.Count -ne 1 -or $activeLeases[0].path -ne $leasePath) {
    throw "Bridge lease did not appear active for the current launcher process."
  }
  if (-not (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases $oldRuntimeKey)) {
    throw "Bridge lease should be discoverable by runtime key."
  }
  if (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases (New-RuntimeKey "http://127.0.0.1:20000" "http://127.0.0.1:20001" $contractB)) {
    throw "Bridge lease should not match a different runtime key."
  }
  if (-not (Test-ActiveBridgeLeaseForBackend $activeLeases $state.backend.url)) {
    throw "Bridge lease should keep shared backend runtime entries alive."
  }
  if (-not (Test-ActiveBridgeLeaseForDashboard $activeLeases $state.frontend.origin)) {
    throw "Bridge lease should keep shared dashboard runtime entries alive."
  }
  if (Test-ActiveBridgeLeaseForDashboard $activeLeases "http://127.0.0.1:29999") {
    throw "Bridge lease should not match a different dashboard endpoint."
  }
  Remove-BridgeLease $leasePath
  $activeAfterRemove = @(Get-ActiveBridgeLeases $runtimePath)
  if ($activeAfterRemove.Count -ne 0) {
    throw "Bridge lease cleanup did not remove the current launcher lease."
  }
  $staleLeaseDir = Resolve-BridgeLeaseDir $runtimePath
  New-Item -ItemType Directory -Path $staleLeaseDir -Force | Out-Null
  $staleLeasePath = Join-Path $staleLeaseDir "bridge-0-stale.json"
  Set-Content -LiteralPath $staleLeasePath -Value '{"pid":0}' -NoNewline
  $activeAfterStale = @(Get-ActiveBridgeLeases $runtimePath)
  if ($activeAfterStale.Count -ne 0 -or (Test-Path -LiteralPath $staleLeasePath)) {
    throw "Stale bridge leases were not pruned."
  }

  Remove-Item -LiteralPath $runtimePath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Resolve-BridgeLeaseDir $runtimePath) -Recurse -Force -ErrorAction SilentlyContinue

  Write-Host "Symphony++ MCP launcher self-test passed."
}

if ($Help) {
  Write-Usage
  exit 0
}

if ($SelfTest) {
  Invoke-SelfTest
  exit 0
}

$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$expectedContractFingerprint = Normalize-McpContractFingerprint $ExpectedMcpContractFingerprint
if ([string]::IsNullOrWhiteSpace($expectedContractFingerprint)) {
  throw "Symphony++ MCP launcher expected MCP contract fingerprint is invalid."
}
$expectedSourceRevision = Resolve-ExpectedSourceRevision $pluginRoot
$artifactRuntimeAllowed = Test-ArtifactRuntimeAllowed $pluginRoot
$artifactRuntime = $null
$runtimeMode = "source"

$repoRoot = Resolve-RepoRoot
if ([string]::IsNullOrWhiteSpace($expectedSourceRevision)) {
  $expectedSourceRevision = Resolve-SymppSourceRevision $repoRoot $pluginRoot
}
$sourceFallbackAllowed = (Test-SourceFallbackAllowed $pluginRoot) -or (Test-SymphonySourceRoot $repoRoot)
$artifactProbe = Resolve-SymppArtifactProbe $pluginRoot $expectedSourceRevision $expectedContractFingerprint $artifactRuntimeAllowed $sourceFallbackAllowed -ValidateOnly
$artifactValidationLaunchable = @("ready", "artifact_selected") -contains $artifactProbe.status

$elixirDir = Join-Path $repoRoot "elixir"
$assetsDir = Join-Path $elixirDir "assets"
$mix = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MIX)) { "mix" } else { $env:SYMPP_MIX }
$mise = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MISE)) { "mise" } else { $env:SYMPP_MISE }
$defaultLauncher = if ($sourceFallbackAllowed -and (Test-Path -LiteralPath $elixirDir)) { Resolve-SymppDefaultLauncher $elixirDir $mise } else { "direct" }
$launcher = Get-EnvMode "SYMPP_LAUNCHER" $defaultLauncher @("direct", "mise")
Set-SymppSourceRevisionEnvironment $expectedSourceRevision
Set-SymppWindowsNativeTargetEnvironment
$defaultMixBuildRoot = if ($sourceFallbackAllowed -and (Test-Path -LiteralPath $elixirDir)) { Resolve-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp" $pluginRoot } else { $null }
if (-not $ValidateOnly) {
  if ($sourceFallbackAllowed -and (Test-Path -LiteralPath $elixirDir)) {
    Set-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp" $pluginRoot
  }
}
$runtimeFile = Resolve-RuntimeFile
$logDir = Resolve-LogDir

if ($ValidateOnly) {
  $validationRuntimeMode = if ($artifactValidationLaunchable) { "artifact" } elseif ($sourceFallbackAllowed) { "source" } else { "blocked" }
  if ($validationRuntimeMode -eq "blocked") {
    throw "Symphony++ MCP launcher validation failed: no verified runtime artifact is launchable and source fallback is unavailable."
  }

  if ($sourceFallbackAllowed -and -not $artifactValidationLaunchable) {
    Assert-LauncherAvailable $launcher $mix $mise
    Set-Location -LiteralPath $elixirDir
    $validationExitCode = Test-LauncherVersion $launcher $mix $mise
    if ($validationExitCode -ne 0) {
      throw "Selected Symphony++ MCP launcher failed validation with exit code $validationExitCode."
    }
  }

  Write-Host "Symphony++ MCP launcher validation passed."
  Write-Host "  repoRoot: $repoRoot"
  Write-Host "  elixirDir: $elixirDir"
  Write-Host "  assetsDir: $assetsDir"
  Write-Host "  runtimeMode: $validationRuntimeMode"
  Write-Host "  artifactStatus: $($artifactProbe.status)"
  Write-Host "  artifactDetail: $($artifactProbe.detail)"
  if ($artifactProbe.manifest_path) {
    Write-Host "  artifactManifest: $($artifactProbe.manifest_path)"
  }
  if ($artifactProbe.cache_root) {
    Write-Host "  artifactCache: $($artifactProbe.cache_root)"
  }
  Write-Host "  sourceFallback: $(if ($sourceFallbackAllowed) { "enabled" } else { "disabled" })"
  Write-Host "  launcher: $launcher"
  if ($defaultMixBuildRoot) {
    Write-Host "  mixBuildRoot: $defaultMixBuildRoot"
  }
  Write-Host "  runtimeFile: $runtimeFile"
  Write-Host "  logDir: $logDir"
  if (Test-NpmAvailable) {
    Write-Host "  dashboardLauncher: available"
  } else {
    Write-Host "  dashboardLauncher: unavailable (MCP bridge can still start; dashboard autostart will be recorded as failed)"
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    Write-Host "  database: $([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE))"
  }
  exit 0
}

$elixirSetupTimeout = Get-EnvInteger "SYMPP_ELIXIR_SETUP_TIMEOUT_SEC" 300 1 1800
$bridgeMode = Get-EnvMode "SYMPP_MCP_BRIDGE_MODE" "http" @("http", "direct_stdio")
if ($bridgeMode -eq "direct_stdio") {
  $artifactSelection = Resolve-LaunchArtifactSelection $pluginRoot $repoRoot $artifactProbe $expectedSourceRevision $expectedContractFingerprint $artifactRuntimeAllowed $sourceFallbackAllowed
  $artifactRuntime = $artifactSelection.artifact_runtime
  $runtimeMode = [string]$artifactSelection.runtime_mode
  $expectedSourceRevision = [string]$artifactSelection.expected_source_revision
  if ($runtimeMode -eq "source") {
    [void](Initialize-ElixirRuntime $elixirDir $launcher $mix $mise $logDir $elixirSetupTimeout)
  }
  Invoke-DirectStdioMcp $repoRoot $elixirDir $launcher $mix $mise $artifactRuntime
  exit 0
}

$autostartServers = -not (Test-EnvDisabled "SYMPP_AUTOSTART_SERVERS")
$autostartBackend = $autostartServers -and -not (Test-EnvDisabled "SYMPP_AUTOSTART_BACKEND")
$autostartFrontend = $autostartServers -and -not (Test-EnvDisabled "SYMPP_AUTOSTART_FRONTEND")
$backendPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_BACKEND_PORT)
$dashboardPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_PORT)
$backendPort = Get-EnvInteger "SYMPP_BACKEND_PORT" $DefaultBackendPort 0 65535
$dashboardPort = Get-EnvInteger "SYMPP_DASHBOARD_PORT" $DefaultDashboardPort 0 65535
$backendTimeout = Get-EnvInteger "SYMPP_BACKEND_STARTUP_TIMEOUT_SEC" 60 1 600
$backendPortReleaseTimeout = Get-EnvInteger "SYMPP_BACKEND_PORT_RELEASE_TIMEOUT_SEC" 15 0 600
$frontendInstallTimeout = Get-EnvInteger "SYMPP_FRONTEND_INSTALL_TIMEOUT_SEC" 180 1 1800
$frontendTimeout = Get-EnvInteger "SYMPP_FRONTEND_STARTUP_TIMEOUT_SEC" 20 1 600
$bridgeTimeout = Get-EnvInteger "SYMPP_MCP_HTTP_TIMEOUT_SEC" 300 1 3600
$startupLockMinimum = 30
if ($autostartBackend) {
  $startupLockMinimum += ($elixirSetupTimeout * 2)
  $startupLockMinimum += $backendTimeout
  $startupLockMinimum += $backendPortReleaseTimeout
}
if ($autostartFrontend) {
  $startupLockMinimum += $frontendInstallTimeout
  $startupLockMinimum += $frontendTimeout
}
$startupLockDefault = [Math]::Min(1800, [Math]::Max(120, $startupLockMinimum))
$startupLockTimeout = Get-EnvInteger "SYMPP_STARTUP_LOCK_TIMEOUT_SEC" $startupLockDefault 1 1800
if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_STARTUP_LOCK_TIMEOUT_SEC) -and $startupLockTimeout -lt $startupLockMinimum) {
  throw "SYMPP_STARTUP_LOCK_TIMEOUT_SEC must be at least $startupLockMinimum for the configured backend/frontend startup waits."
}

$backendLaunch = $null
$frontendLaunch = $null
$frontendInstall = $null
$frontendError = $null
$backendPlan = $null
$dashboardPlan = $null
$bridgeLeasePath = $null
$runtimeKey = $null
$supersededStates = @()

$fastAttachCandidate = Resolve-FastAttachRuntimePlan `
  (Read-RuntimeState $runtimeFile) `
  $expectedSourceRevision `
  $expectedContractFingerprint `
  $backendPort `
  $dashboardPort `
  $backendPortExplicit `
  $dashboardPortExplicit `
  $env:SYMPP_BACKEND_URL `
  $env:SYMPP_DASHBOARD_ORIGIN
if ($null -ne $fastAttachCandidate) {
  $fastAttachLock = Enter-FileLock (Resolve-StartupLockFile $runtimeFile) $startupLockTimeout
  try {
    $fastAttachState = Read-RuntimeState $runtimeFile
    $fastAttachPlan = Resolve-FastAttachRuntimePlan `
      $fastAttachState `
      $expectedSourceRevision `
      $expectedContractFingerprint `
      $backendPort `
      $dashboardPort `
      $backendPortExplicit `
      $dashboardPortExplicit `
      $env:SYMPP_BACKEND_URL `
      $env:SYMPP_DASHBOARD_ORIGIN
    if ($null -ne $fastAttachPlan) {
      $supersededStates = Stop-SupersededRuntimeStatesIfUnused $runtimeFile (Get-SupersededRuntimeStates $fastAttachState)
      Set-SupersededRuntimeStates $fastAttachState $supersededStates
      Write-RuntimeState $runtimeFile $fastAttachState

      $backendPlan = $fastAttachPlan.backend_plan
      $dashboardPlan = $fastAttachPlan.dashboard_plan
      $runtimeKey = $fastAttachPlan.runtime_key
      $bridgeLeasePath = New-BridgeLease $runtimeFile $backendPlan $dashboardPlan $runtimeKey
    }
  } finally {
    Exit-FileLock $fastAttachLock
  }

  if ($null -ne $bridgeLeasePath) {
    try {
      Write-Diagnostic "Symphony++ MCP bridge attached: backend=$($backendPlan.url) dashboard=$($dashboardPlan.url) runtime=$runtimeFile"
      Invoke-HttpMcpBridge $backendPlan.mcp_url $bridgeTimeout
    } finally {
      Remove-BridgeLease $bridgeLeasePath
      Stop-ManagedServersIfUnused $runtimeFile $runtimeKey
    }
    exit 0
  }
}

$startupLock = Enter-FileLock (Resolve-StartupLockFile $runtimeFile) $startupLockTimeout
try {
  $runtimeState = Read-RuntimeState $runtimeFile
  $activeLeasesAtStart = @(Get-ActiveBridgeLeases $runtimeFile)
  if ($activeLeasesAtStart.Count -eq 0 -and $null -ne $runtimeState -and $null -ne $runtimeState.backend) {
    $runtimeHealth = Get-SymppBackendHealthWithRetry ([string]$runtimeState.backend.url)
    $preserveBackendUrl = if ([string]::IsNullOrWhiteSpace($env:SYMPP_BACKEND_URL)) { $null } else { $env:SYMPP_BACKEND_URL.TrimEnd("/") }
    $preserveDashboardOrigin = if ([string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_ORIGIN)) { $null } else { $env:SYMPP_DASHBOARD_ORIGIN.TrimEnd("/") }
    if (-not (Test-BackendContractMatches $runtimeHealth $expectedContractFingerprint) -and
        (Stop-ManagedRuntimeStateEntries $runtimeState $preserveBackendUrl $preserveDashboardOrigin)) {
      Write-RuntimeState $runtimeFile $runtimeState
    }
  }

  $backendPlan = Resolve-BackendPlan $backendPort $env:SYMPP_BACKEND_URL $runtimeState $backendPortReleaseTimeout $expectedSourceRevision $expectedContractFingerprint $backendPortExplicit @($dashboardPort)
  if ($backendPlan.should_start -and -not $autostartBackend) {
    throw "Backend autostart is disabled and no reusable Symphony++ backend was found at $($backendPlan.url)."
  }
  if ($backendPlan.should_start) {
    $artifactSelection = Resolve-LaunchArtifactSelection $pluginRoot $repoRoot $artifactProbe $expectedSourceRevision $expectedContractFingerprint $artifactRuntimeAllowed $sourceFallbackAllowed
    $artifactRuntime = $artifactSelection.artifact_runtime
    $runtimeMode = [string]$artifactSelection.runtime_mode
    $expectedSourceRevision = [string]$artifactSelection.expected_source_revision
  }

  $allowRecordedDashboardReuse = $backendPlan.managed -eq $true -and [string]$backendPlan.status -eq "reused"
  $artifactDashboardPortMatchesBackend = $dashboardPortExplicit -and $dashboardPort -eq $backendPlan.port
  $artifactBackendProvidesDashboard = (Test-ArtifactBackendProvidesDashboard $runtimeState $backendPlan $runtimeMode) -and
    ($backendPlan.should_start -or ((Test-HealthySymppDashboard $backendPlan.url) -and (Test-SymppDashboardMcpProxyMatches $backendPlan.url $expectedContractFingerprint)))
  if ($artifactBackendProvidesDashboard -and -not $backendPlan.should_start) {
    $runtimeMode = "artifact"
  }
  if ($artifactBackendProvidesDashboard -and
      [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_ORIGIN) -and
      ((-not $dashboardPortExplicit) -or $artifactDashboardPortMatchesBackend) -and
      ($backendPlan.should_start -or $backendPlan.reused)) {
    $dashboardPlan = New-ReusedDashboardPlan "artifact_static" $backendPlan.url ($backendPlan.managed -eq $true) $backendPlan.pid
  } else {
    $dashboardBackendSourceRevision = if ($backendPlan.should_start) { $expectedSourceRevision } else { [string]$backendPlan.source_revision }
    $dashboardPlan = Resolve-DashboardPlan $dashboardPort $env:SYMPP_DASHBOARD_ORIGIN $backendPlan.url $dashboardBackendSourceRevision $runtimeState $dashboardPortExplicit $expectedSourceRevision $expectedContractFingerprint $allowRecordedDashboardReuse
  }
  if ($runtimeMode -eq "artifact" -and $dashboardPortExplicit -and $dashboardPlan.should_start -and -not (Test-Path -LiteralPath $assetsDir -PathType Container)) {
    throw "SYMPP_DASHBOARD_PORT requires source dashboard assets when artifact mode must start a separate dashboard. Set SYMPP_DASHBOARD_ORIGIN to reuse an operator-owned dashboard, or clear SYMPP_DASHBOARD_PORT to use the artifact backend dashboard."
  }
  if ($dashboardPlan.should_start -and -not $autostartFrontend) {
    $dashboardPlan = New-DisabledDashboardPlan "disabled" "frontend_autostart_disabled"
  }

  $supersededStates = Merge-SupersededRuntimeStates (Get-SupersededRuntimeStates $runtimeState) (New-SupersededRuntimeState $runtimeState $backendPlan $dashboardPlan)
  $supersededStates = Stop-SupersededRuntimeStatesIfUnused $runtimeFile $supersededStates

  if ($backendPlan.should_start) {
    if ($runtimeMode -eq "source") {
      [void](Initialize-ElixirRuntime $elixirDir $launcher $mix $mise $logDir $elixirSetupTimeout)
    }
    $backendLaunch = Start-Backend $backendPlan $dashboardPlan.origin $elixirDir $launcher $mix $mise $logDir $backendTimeout $expectedContractFingerprint $artifactRuntime
    $backendPlan.status = "started"
    $backendPlan.pid = $backendLaunch.pid
    $backendPlan.source_revision = $backendLaunch.source_revision
    $backendPlan.contract_fingerprint = $backendLaunch.contract_fingerprint
    if ($runtimeMode -eq "artifact" -and [string]$dashboardPlan.status -eq "artifact_static") {
      $dashboardPlan.pid = $backendLaunch.pid
      if (-not (Test-HealthySymppDashboard $backendPlan.url) -or -not (Test-SymppDashboardMcpProxyMatches $backendPlan.url $expectedContractFingerprint)) {
        throw "artifact_dashboard_unavailable: verified artifact backend started, but its dashboard route is not healthy for the expected MCP contract."
      }
    }
  }

  if ($dashboardPlan.should_start) {
    try {
      $frontendInstall = Install-FrontendDependencies $assetsDir $logDir $frontendInstallTimeout
      $frontendLaunch = Start-Frontend $dashboardPlan $backendPlan.url $assetsDir $logDir $frontendTimeout
      $dashboardPlan.status = "started"
      $dashboardPlan.pid = $frontendLaunch.pid
    } catch {
      $frontendError = $_.Exception.Message
      $dashboardPlan.status = "failed"
      Write-Diagnostic "Symphony++ dashboard autostart failed; MCP bridge will continue. detail=$frontendError"
    }
  }
  if ($null -eq $frontendError -and $null -ne $dashboardPlan.PSObject.Properties["error"]) {
    $frontendError = $dashboardPlan.error
  }

  $runtimeSourceRevision = if ([string]::IsNullOrWhiteSpace([string]$backendPlan.source_revision)) { $expectedSourceRevision } else { [string]$backendPlan.source_revision }
  $runtimeContractFingerprint = if ([string]::IsNullOrWhiteSpace([string]$backendPlan.contract_fingerprint)) { $expectedContractFingerprint } else { [string]$backendPlan.contract_fingerprint }
  $runtimeKey = New-RuntimeKey $backendPlan.url $dashboardPlan.origin $runtimeContractFingerprint
  $state = [pscustomobject]@{
    generated_at = (Get-Date).ToString("o")
    repo_root = $repoRoot
    plugin_root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    mcp_transport = "stdio_to_http_bridge"
    runtime_key = $runtimeKey
    runtime_kind = if ($runtimeMode -eq "artifact") { "artifact" } elseif ($backendPlan.managed -eq $true) { "managed" } else { [string]$backendPlan.status }
    runtime_mode = $runtimeMode
    artifact = if ($artifactRuntime) {
      [pscustomobject]@{
        status = "ready"
        root = $artifactRuntime.root
        entrypoint = $artifactRuntime.entrypoint
        sha256 = $artifactRuntime.sha256
        platform = $artifactRuntime.platform
        manifest_path = $artifactRuntime.manifest_path
      }
    } else {
      [pscustomobject]@{
        status = $artifactProbe.status
        detail = $artifactProbe.detail
        platform = $artifactProbe.platform
        manifest_path = $artifactProbe.manifest_path
      }
    }
    backend = [pscustomobject]@{
      status = $backendPlan.status
      url = $backendPlan.url
      mcp_url = $backendPlan.mcp_url
      port = $backendPlan.port
      reused = $backendPlan.reused
      managed = $backendPlan.managed -eq $true
      pid = $backendPlan.pid
      expected_source_revision = $expectedSourceRevision
      source_revision = $backendPlan.source_revision
      expected_contract_fingerprint = $expectedContractFingerprint
      contract_fingerprint = $backendPlan.contract_fingerprint
      stdout_log = if ($backendLaunch) { $backendLaunch.stdout } else { $null }
      stderr_log = if ($backendLaunch) { $backendLaunch.stderr } else { $null }
    }
    frontend = [pscustomobject]@{
      status = $dashboardPlan.status
      origin = $dashboardPlan.origin
      url = $dashboardPlan.url
      port = $dashboardPlan.port
      reused = $dashboardPlan.reused
      managed = $dashboardPlan.managed -eq $true
      pid = $dashboardPlan.pid
      install_stdout_log = if ($frontendInstall) { $frontendInstall.stdout } else { $null }
      install_stderr_log = if ($frontendInstall) { $frontendInstall.stderr } else { $null }
      stdout_log = if ($frontendLaunch) { $frontendLaunch.stdout } else { $null }
      stderr_log = if ($frontendLaunch) { $frontendLaunch.stderr } else { $null }
      error = $frontendError
    }
    controls = [pscustomobject]@{
      backend_port_env = "SYMPP_BACKEND_PORT"
      dashboard_port_env = "SYMPP_DASHBOARD_PORT"
      backend_url_env = "SYMPP_BACKEND_URL"
      dashboard_origin_env = "SYMPP_DASHBOARD_ORIGIN"
      autostart_env = "SYMPP_AUTOSTART_SERVERS"
      bridge_mode_env = "SYMPP_MCP_BRIDGE_MODE"
    }
    superseded = if ($supersededStates.Count -gt 0) { $supersededStates[0] } else { $null }
    superseded_runtimes = $supersededStates
  }
  Write-RuntimeState $runtimeFile $state
  $bridgeLeasePath = New-BridgeLease $runtimeFile $backendPlan $dashboardPlan $runtimeKey

  $dashboardSummary = if ($dashboardPlan.url) { "$($dashboardPlan.url) [$($dashboardPlan.status)]" } else { $dashboardPlan.status }
  Write-Diagnostic "Symphony++ MCP bridge ready: backend=$($backendPlan.url) dashboard=$dashboardSummary runtime=$runtimeFile"
} finally {
  Exit-FileLock $startupLock
}
try {
  Invoke-HttpMcpBridge $backendPlan.mcp_url $bridgeTimeout
} finally {
  Remove-BridgeLease $bridgeLeasePath
  Stop-ManagedServersIfUnused $runtimeFile $runtimeKey
}
