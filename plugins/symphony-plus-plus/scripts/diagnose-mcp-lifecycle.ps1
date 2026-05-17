param(
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$HOME/.codex" }),
  [string]$MarketplaceName = "*",
  [string]$RepoRoot,
  [switch]$SelfTest,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$SymppPluginPackageNames = @("symphony-plus-plus", "symphony-plus-plus-mcp")

function Resolve-OptionalFullPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Normalize-ComparablePath([string]$Path) {
  $fullPath = Resolve-OptionalFullPath $Path
  if (-not $fullPath) {
    return $null
  }

  return $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar).ToLowerInvariant()
}

function Sanitize-CommandLine([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) {
    return ""
  }

  $sanitized = $CommandLine
  $redactions = @(
    @{
      Pattern = '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s"'']+'
      Replacement = '${1}<redacted>'
    },
    @{
      Pattern = '(?i)(\bbearer\s+)[^\s"'']+'
      Replacement = '${1}<redacted>'
    },
    @{
      Pattern = '(?i)((?:--?|/)(?:api[-_]?key|token|secret|password|authorization|bearer)(?:\s+|=))(?:"[^"]*"|''[^'']*''|\S+)'
      Replacement = '${1}<redacted>'
    },
    @{
      Pattern = '(?i)(\b(?:api[-_]?key|token|secret|key|authorization|bearer|password)\b\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|\S+)'
      Replacement = '${1}<redacted>'
    }
  )

  foreach ($redaction in $redactions) {
    $sanitized = $sanitized -replace $redaction.Pattern, $redaction.Replacement
  }

  $sanitized = $sanitized -replace "\s+", " "
  if ($sanitized.Length -gt 240) {
    return $sanitized.Substring(0, 240) + "...<truncated>"
  }

  return $sanitized
}

function Invoke-SelfTest {
  $cases = @(
    @{ Command = 'tool --token abc123 --api-key=sk-live'; Secrets = @("abc123", "sk-live") },
    @{ Command = 'curl -H "Authorization: Bearer ey.secret" https://example.invalid'; Secrets = @("ey.secret") },
    @{ Command = 'runner /password hunter2 token=plain secret:"quoted-value"'; Secrets = @("hunter2", "plain", "quoted-value") },
    @{ Command = 'worker bearer abc.def.ghi --authorization "Bearer nested-secret"'; Secrets = @("abc.def.ghi", "nested-secret") }
  )

  foreach ($case in $cases) {
    $sanitized = Sanitize-CommandLine $case.Command
    foreach ($secret in $case.Secrets) {
      if ($sanitized.Contains($secret)) {
        throw "Sanitize-CommandLine leaked '$secret' for command: $($case.Command)"
      }
    }
  }

  Write-Host "Sanitize-CommandLine self-test passed."
}

function Get-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{
      __parse_error = $_.Exception.Message
    }
  }
}

function Get-JsonParseError($JsonObject) {
  if ($null -eq $JsonObject) {
    return $null
  }

  $property = $JsonObject.PSObject.Properties["__parse_error"]
  if ($property) {
    return [string]$property.Value
  }

  return $null
}

function Test-JsonProperty($JsonObject, [string]$Name) {
  if ($null -eq $JsonObject -or (Get-JsonParseError $JsonObject)) {
    return $false
  }

  return @($JsonObject.PSObject.Properties.Name) -contains $Name
}

function Get-McpShape($McpConfig) {
  if ($null -eq $McpConfig) {
    return "missing"
  }
  if (Get-JsonParseError $McpConfig) {
    return "parse_error"
  }

  $properties = @($McpConfig.PSObject.Properties.Name)
  if ($properties -contains "mcpServers") {
    return "wrapped_mcpServers"
  }
  if ($properties -contains "mcp_servers") {
    return "wrapped_mcp_servers"
  }

  return "direct_server_map"
}

function Get-McpServerMap($McpConfig) {
  if ($null -eq $McpConfig -or (Get-JsonParseError $McpConfig)) {
    return $null
  }

  $properties = @($McpConfig.PSObject.Properties.Name)
  if ($properties -contains "mcp_servers") {
    return $McpConfig.mcp_servers
  }
  if ($properties -contains "mcpServers") {
    return $McpConfig.mcpServers
  }

  return $McpConfig
}
function Test-LoopbackMcpUri([System.Uri]$Uri) {
  return $Uri.Scheme -eq "http" -and
    $Uri.AbsolutePath -eq "/mcp" -and
    ($Uri.Host -eq "127.0.0.1" -or $Uri.Host -eq "localhost" -or $Uri.Host -eq "::1" -or $Uri.Host -eq "[::1]")
}

function Get-HttpMcpReachabilityStatus($Server) {
  if ($null -eq $Server -or -not (@($Server.PSObject.Properties.Name) -contains "url")) {
    return "not_applicable"
  }

  try {
    $uri = [System.Uri]::new([string]$Server.url)
  } catch {
    return "invalid_url"
  }

  if (-not (Test-LoopbackMcpUri $uri)) {
    return "non_loopback_or_non_mcp_url"
  }

  try {
    $response = Invoke-WebRequest -Uri $uri.AbsoluteUri -Method Get -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
    return "unexpected_http_status_$([int]$response.StatusCode)"
  } catch {
    $response = $_.Exception.Response
    if ($null -ne $response) {
      $statusCode = [int]$response.StatusCode
      if ($statusCode -eq 405) {
        return "mcp_endpoint_available"
      }

      return "unexpected_http_status_$statusCode"
    }

    return "unreachable"
  }
}

function Get-SymppMcpServerStatus($McpConfig) {
  $serverMap = Get-McpServerMap $McpConfig
  if ($null -eq $serverMap) {
    return "not_configured"
  }

  $server = $serverMap.symphony_plus_plus
  if ($null -eq $server) {
    return "missing"
  }
  if (@($server.PSObject.Properties.Name) -contains "url") {
    foreach ($stdioProperty in @("type", "command", "args", "cwd")) {
      if (@($server.PSObject.Properties.Name) -contains $stdioProperty) {
        return "invalid_mixed_http_stdio"
      }
    }

    try {
      $uri = [System.Uri]::new([string]$server.url)
    } catch {
      return "invalid_url"
    }

    if (-not (Test-LoopbackMcpUri $uri)) {
      return "invalid_url"
    }

    if ($server.url -eq "http://127.0.0.1:4057/mcp") {
      return "ok"
    }

    return "non_default_http_url"
  }
  if ($server.type -ne "stdio") {
    return "invalid_type"
  }
  if ($server.command -ne "pwsh") {
    return "unexpected_command"
  }
  if ($server.cwd -ne ".") {
    return "invalid_cwd"
  }

  $args = @($server.args)
  $hasNoProfile = @($args | Where-Object { [string]$_ -eq "-NoProfile" }).Count -gt 0
  $hasStartScript = @($args | Where-Object { [string]$_ -match "scripts[\\/]start-sympp-mcp\.ps1" }).Count -gt 0
  if (-not $hasNoProfile -or -not $hasStartScript) {
    return "invalid_args"
  }

  return "ok"
}

function Get-PluginPackageSummary([string]$Root, [string]$Label, [string]$PackageMarketplaceName) {
  $manifestPath = Join-Path $Root ".codex-plugin/plugin.json"
  $manifestExists = Test-Path -LiteralPath $manifestPath
  $manifest = Get-JsonFile $manifestPath
  $manifestParseError = Get-JsonParseError $manifest
  $manifestName = if ($manifest -and -not $manifestParseError) { [string]$manifest.name } else { $null }
  $manifestHasMcpServers = Test-JsonProperty $manifest "mcpServers"
  $manifestMcpServersValue = if ($manifestHasMcpServers) { [string]$manifest.mcpServers } else { $null }
  $mcpPath = if ($manifestHasMcpServers -and -not [string]::IsNullOrWhiteSpace($manifestMcpServersValue)) {
    [System.IO.Path]::GetFullPath((Join-Path $Root ([string]$manifest.mcpServers)))
  } else {
    Join-Path $Root ".mcp.json"
  }
  $rootMcpExists = Test-Path -LiteralPath (Join-Path $Root ".mcp.json")
  $mcp = Get-JsonFile $mcpPath
  $mcpParseError = Get-JsonParseError $mcp
  $serverMap = Get-McpServerMap $mcp
  $server = if ($null -ne $serverMap) { $serverMap.symphony_plus_plus } else { $null }
  $sourceHintPath = Join-Path $Root ".sympp-source-root"
  $sourceHint = if (Test-Path -LiteralPath $sourceHintPath) {
    (Get-Content -LiteralPath $sourceHintPath -Raw).Trim().TrimStart([char]0xFEFF)
  } else {
    $null
  }
  $mcpServerStatus = Get-SymppMcpServerStatus $mcp
  $isOptInMcpPackage = $manifestName -eq "symphony-plus-plus-mcp"
  $packageNameFromRoot = Split-Path (Split-Path $Root -Parent) -Leaf
  $isDefaultPackage = $manifestName -eq "symphony-plus-plus" -or $packageNameFromRoot -eq "symphony-plus-plus"
  $defaultPackageBundlesMcp = $isDefaultPackage -and (-not $isOptInMcpPackage) -and ($manifestHasMcpServers -or $rootMcpExists)
  $defaultPluginLifecycleStatus = if (-not $manifestExists) {
    "missing_manifest"
  } elseif ($manifestParseError) {
    "manifest_parse_error"
  } elseif ($manifestHasMcpServers -and $isOptInMcpPackage) {
    "opt_in_mcp_plugin_bundles_mcp"
  } elseif ($defaultPackageBundlesMcp) {
    "incompatible_default_plugin_bundles_mcp"
  } else {
    "skill_only"
  }

  [pscustomobject]@{
    label = $Label
    package_name = if ($manifestName) { $manifestName } else { Split-Path (Split-Path $Root -Parent) -Leaf }
    marketplace_name = $PackageMarketplaceName
    root = $Root
    exists = Test-Path -LiteralPath $Root
    manifest_exists = $manifestExists
    manifest_version = if ($manifest -and -not $manifestParseError) { [string]$manifest.version } else { $null }
    manifest_mcpServers_declared = $manifestHasMcpServers
    manifest_mcpServers = $manifestMcpServersValue
    manifest_parse_error = $manifestParseError
    default_plugin_lifecycle_status = $defaultPluginLifecycleStatus
    mcp_path_exists = Test-Path -LiteralPath $mcpPath
    mcp_shape = Get-McpShape $mcp
    mcp_parse_error = $mcpParseError
    reference_mcp_server_status = $mcpServerStatus
    http_mcp_reachability_status = Get-HttpMcpReachabilityStatus $server
    symphony_plus_plus_server = if (-not $manifestExists) { "missing_manifest" } elseif ($manifestParseError) { "manifest_parse_error" } elseif ($manifestHasMcpServers -and $isOptInMcpPackage) { $mcpServerStatus } elseif ($defaultPackageBundlesMcp) { "incompatible_default_plugin_bundles_mcp" } else { $mcpServerStatus }
    has_start_script = Test-Path -LiteralPath (Join-Path $Root "scripts/start-sympp-mcp.ps1")
    source_root_hint = $sourceHint
  }
}

function Get-CompanionMcpSourcePackages([string]$DefaultPluginRoot) {
  $sourceSibling = Join-Path (Split-Path $DefaultPluginRoot -Parent) "symphony-plus-plus-mcp"
  if (Test-Path -LiteralPath (Join-Path $sourceSibling ".codex-plugin/plugin.json")) {
    $sourceSiblingPackage = Get-PluginPackageSummary $sourceSibling "source" "source"
    if ($sourceSiblingPackage.package_name -eq "symphony-plus-plus-mcp" -and -not [string]::IsNullOrWhiteSpace([string]$sourceSiblingPackage.manifest_version)) {
      return @($sourceSiblingPackage)
    }
  }

  $defaultCacheRoot = Split-Path $DefaultPluginRoot -Parent
  if ((Split-Path $defaultCacheRoot -Leaf) -ne "symphony-plus-plus") {
    return @()
  }

  $marketplaceRoot = Split-Path $defaultCacheRoot -Parent
  $companionCacheRoot = Join-Path $marketplaceRoot "symphony-plus-plus-mcp"
  $sameLabel = Split-Path $DefaultPluginRoot -Leaf
  $localManifestPath = Join-Path (Join-Path $companionCacheRoot "local") ".codex-plugin/plugin.json"
  $sameLabelManifestPath = Join-Path (Join-Path $companionCacheRoot $sameLabel) ".codex-plugin/plugin.json"
  $defaultSourceHintPath = Join-Path $DefaultPluginRoot ".sympp-source-root"
  $hasSameLabelCompanion = Test-Path -LiteralPath $sameLabelManifestPath
  $hasGeneratedDefaultHint = Test-Path -LiteralPath $defaultSourceHintPath
  $hasLocalCompanion = Test-Path -LiteralPath $localManifestPath
  $localPackage = if ($hasLocalCompanion) {
    $candidatePackage = Get-PluginPackageSummary (Join-Path $companionCacheRoot "local") "source" "source"
    if ($candidatePackage.package_name -eq "symphony-plus-plus-mcp" -and -not [string]::IsNullOrWhiteSpace([string]$candidatePackage.manifest_version)) {
      $candidatePackage
    } else {
      $null
    }
  } else {
    $null
  }
  $sameLabelPackage = if ($hasSameLabelCompanion) {
    $candidatePackage = Get-PluginPackageSummary (Join-Path $companionCacheRoot $sameLabel) "source" "source"
    if ($candidatePackage.package_name -eq "symphony-plus-plus-mcp" -and -not [string]::IsNullOrWhiteSpace([string]$candidatePackage.manifest_version)) {
      $candidatePackage
    } else {
      $null
    }
  } else {
    $null
  }

  if ($null -eq $sameLabelPackage -and -not ($hasGeneratedDefaultHint -and $null -ne $localPackage)) {
    return @()
  }

  $packages = @()
  if ($null -ne $localPackage -and (Test-LocalCompanionCanOverrideSameLabel $localPackage $sameLabelPackage)) {
    $packages += $localPackage
  }
  if ($null -ne $sameLabelPackage) {
    $packages += $sameLabelPackage
  }

  return $packages
}

function Get-InstalledDefaultPluginMarketplaceName([string]$DefaultPluginRoot) {
  $defaultCacheRoot = Split-Path $DefaultPluginRoot -Parent
  if ((Split-Path $defaultCacheRoot -Leaf) -ne "symphony-plus-plus") {
    return $null
  }

  return Split-Path (Split-Path $defaultCacheRoot -Parent) -Leaf
}

function Get-CurrentManifestVersionsByPackageName($SourcePackages) {
  $versions = @{}
  foreach ($package in @($SourcePackages)) {
    if (
      $null -ne $package -and
      -not [string]::IsNullOrWhiteSpace([string]$package.package_name) -and
      -not [string]::IsNullOrWhiteSpace([string]$package.manifest_version)
    ) {
      $packageName = [string]$package.package_name
      if (-not $versions.ContainsKey($packageName)) {
        $versions[$packageName] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
      }

      [void]$versions[$packageName].Add([string]$package.manifest_version)
    }
  }

  return $versions
}

function Compare-ManifestVersionStrings([string]$Left, [string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
    return $null
  }

  $leftVersion = $null
  $rightVersion = $null
  if ([System.Version]::TryParse($Left, [ref]$leftVersion) -and [System.Version]::TryParse($Right, [ref]$rightVersion)) {
    return $leftVersion.CompareTo($rightVersion)
  }

  if ($Left.Equals($Right, [System.StringComparison]::OrdinalIgnoreCase)) {
    return 0
  }

  return $null
}

function Test-LocalCompanionCanOverrideSameLabel($LocalPackage, $SameLabelPackage) {
  if ($null -eq $SameLabelPackage) {
    return $true
  }

  $comparison = Compare-ManifestVersionStrings ([string]$LocalPackage.manifest_version) ([string]$SameLabelPackage.manifest_version)
  return $null -ne $comparison -and $comparison -ge 0
}

function Get-InstalledCompanionMcpVersionCandidatePackages($CachePackages, [string[]]$AllowedMarketplaces) {
  $packages = @(
    $CachePackages |
      Where-Object {
        $_.package_name -eq "symphony-plus-plus-mcp" -and
        $_.label -ne "local" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.manifest_version) -and
        ($AllowedMarketplaces.Count -eq 0 -or $AllowedMarketplaces -contains $_.marketplace_name)
      }
  )
  if ($AllowedMarketplaces.Count -eq 0) {
    $distinctMarketplaces = @($packages | ForEach-Object { [string]$_.marketplace_name } | Sort-Object -Unique)
    if ($distinctMarketplaces.Count -gt 1) {
      return @()
    }
  }

  $distinctVersions = @($packages | ForEach-Object { [string]$_.manifest_version } | Sort-Object -Unique)
  if ($distinctVersions.Count -eq 1) {
    return $packages
  }

  return @()
}

function Test-CachePackageCanScopeProcesses($Package) {
  if ($Package.package_name -eq "symphony-plus-plus" -and $Package.default_plugin_lifecycle_status -eq "skill_only") {
    return $false
  }

  if ($Package.default_plugin_lifecycle_status -eq "incompatible_default_plugin_bundles_mcp") {
    return $Package.reference_mcp_server_status -eq "ok"
  }

  if ($Package.default_plugin_lifecycle_status -eq "opt_in_mcp_plugin_bundles_mcp") {
    return $Package.reference_mcp_server_status -eq "ok"
  }

  return $false
}

function Test-CachePackageIsCurrentForProcessScope($Package, $CurrentManifestVersionsByPackageName) {
  $currentManifestVersions = if ($null -ne $CurrentManifestVersionsByPackageName) {
    $CurrentManifestVersionsByPackageName[[string]$Package.package_name]
  } else {
    $null
  }

  if ($Package.label -eq "local") {
    if ($Package.package_name -ne "symphony-plus-plus-mcp") {
      return $true
    }

    return $null -ne $currentManifestVersions -and $currentManifestVersions.Contains([string]$Package.manifest_version)
  }

  if ($null -ne $currentManifestVersions -and $currentManifestVersions.Contains([string]$Package.label)) {
    return $true
  }

  return $false
}

function Test-VersionedOptInSuppressedByLocal($Package, $LocalPackagesByMarketplace) {
  if ($Package.package_name -ne "symphony-plus-plus-mcp" -or $Package.label -eq "local") {
    return $false
  }

  $marketplaceName = [string]$Package.marketplace_name
  if (-not $LocalPackagesByMarketplace.ContainsKey($marketplaceName)) {
    return $false
  }

  $localPackage = $LocalPackagesByMarketplace[$marketplaceName]
  $comparison = Compare-ManifestVersionStrings ([string]$localPackage.manifest_version) ([string]$Package.manifest_version)
  if ($null -ne $comparison -and $comparison -gt 0) {
    return $true
  }

  if ($null -ne $comparison -and $comparison -eq 0) {
    $localRoot = Normalize-ComparablePath $localPackage.source_root_hint
    $packageRoot = Normalize-ComparablePath $Package.source_root_hint
    return -not [string]::IsNullOrWhiteSpace($localRoot) -and $localRoot -eq $packageRoot
  }

  return $false
}

function Get-RepoRootFromCommand([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) {
    return $null
  }

  $match = [regex]::Match($CommandLine, '--repo-root\s+(?:"([^"]+)"|(\S+))')
  if (-not $match.Success) {
    return $null
  }

  if ($match.Groups[1].Success) {
    return $match.Groups[1].Value.Trim().Trim('"').Trim("'")
  }

  return $match.Groups[2].Value.Trim().Trim('"').Trim("'")
}

function Test-ProcessMatchesAnyRepoRoot($Process, [string[]]$RepoRootFilters) {
  if ($RepoRootFilters.Count -eq 0) {
    return $false
  }

  $processRepoRoot = Normalize-ComparablePath (Get-RepoRootFromCommand $Process.CommandLine)
  return $processRepoRoot -and $RepoRootFilters -contains $processRepoRoot
}

function Find-AncestorLauncherProcessIds($Processes, $ProcessById, $LauncherProcessIds) {
  $found = [System.Collections.Generic.HashSet[int]]::new()

  foreach ($process in $Processes) {
    $parentProcessId = [int]$process.ParentProcessId
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    while ($parentProcessId -and $visited.Add($parentProcessId)) {
      if ($LauncherProcessIds.Contains($parentProcessId)) {
        [void]$found.Add($parentProcessId)
        break
      }

      if (-not $ProcessById.ContainsKey($parentProcessId)) {
        break
      }

      $parent = $ProcessById[$parentProcessId]
      $parentProcessId = [int]$parent.ParentProcessId
    }
  }

  foreach ($processId in $found) {
    $processId
  }
}

function Get-PluginConfigSummary([string]$ConfigPath, [string]$MarketplaceName) {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return [pscustomobject]@{
      path = $ConfigPath
      exists = $false
      symphony_plugin_enabled = $null
      global_sympp_mcp_entry = $false
    }
  }

  $lines = Get-Content -LiteralPath $ConfigPath
  $entries = @()
  $sectionPattern = if ($MarketplaceName -eq "*") {
    '^\[plugins\."(symphony-plus-plus(?:-mcp)?)@([^"]+)"\]'
  } else {
    '^\[plugins\."(symphony-plus-plus(?:-mcp)?)@(' + [regex]::Escape($MarketplaceName) + ')"\]'
  }
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match $sectionPattern) {
      $entryPluginName = $Matches[1]
      $entryMarketplaceName = $Matches[2]
      $entryEnabled = $null
      for ($next = $index + 1; $next -lt $lines.Count; $next++) {
        if ($lines[$next] -match '^\s*\[') {
          break
        }

        if ($lines[$next] -match '^\s*enabled\s*=\s*(true|false)\s*(?:#.*)?$') {
          $entryEnabled = [System.Boolean]::Parse($Matches[1])
          break
        }
      }

      $entries += [pscustomobject]@{
        plugin_name = $entryPluginName
        marketplace_name = $entryMarketplaceName
        enabled = $entryEnabled
      }
    }
  }

  $enabledEntries = @($entries | Where-Object { $_.enabled -eq $true })
  $disabledEntries = @($entries | Where-Object { $_.enabled -eq $false })
  $selectedEnabled = if ($enabledEntries.Count -gt 0) {
    $true
  } elseif ($disabledEntries.Count -eq $entries.Count -and $entries.Count -gt 0) {
    $false
  } else {
    $null
  }

  [pscustomobject]@{
    path = $ConfigPath
    exists = $true
    symphony_plugin_enabled = $selectedEnabled
    symphony_plugin_entries = @($entries)
    global_sympp_mcp_entry = [bool]($lines | Where-Object { $_ -match '^\[mcp_servers\.symphony_plus_plus\]' } | Select-Object -First 1)
  }
}

$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$repoRootWasProvided = -not [string]::IsNullOrWhiteSpace($RepoRoot)
$RepoRoot = Resolve-OptionalFullPath $RepoRoot
if ($repoRootWasProvided -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot "elixir/mix.exs"))) {
  throw "RepoRoot does not look like a Symphony++ checkout with elixir/mix.exs: $RepoRoot"
}
$repoRootFilter = Normalize-ComparablePath $RepoRoot

if ($SelfTest) {
  Invoke-SelfTest
  exit 0
}

$codexHomePath = Resolve-OptionalFullPath $CodexHome
$sourcePackage = Get-PluginPackageSummary $pluginRoot "source" "source"
$cacheBaseRoot = Join-Path $codexHomePath "plugins/cache"
$cacheRoots = @()
if ($MarketplaceName -eq "*") {
  if (Test-Path -LiteralPath $cacheBaseRoot) {
    $cacheRoots = @(
      Get-ChildItem -LiteralPath $cacheBaseRoot -Directory |
      ForEach-Object {
        $marketplaceDir = $_
        foreach ($pluginPackageName in $SymppPluginPackageNames) {
          $candidate = Join-Path $marketplaceDir.FullName $pluginPackageName
          if (Test-Path -LiteralPath $candidate) {
            [pscustomobject]@{ marketplace_name = $marketplaceDir.Name; plugin_name = $pluginPackageName; root = $candidate }
          }
        }
      }
    )
  }
} else {
  $cacheRoots = @(
    foreach ($pluginPackageName in $SymppPluginPackageNames) {
      [pscustomobject]@{
        marketplace_name = $MarketplaceName
        plugin_name = $pluginPackageName
        root = Join-Path $cacheBaseRoot (Join-Path $MarketplaceName $pluginPackageName)
      }
    }
  )
}

$cachePackages = @()
foreach ($cacheRoot in $cacheRoots) {
  if (Test-Path -LiteralPath $cacheRoot.root) {
    $cachePackages += @(
      Get-ChildItem -LiteralPath $cacheRoot.root -Directory |
      Sort-Object Name |
      ForEach-Object { Get-PluginPackageSummary $_.FullName $_.Name $cacheRoot.marketplace_name }
    )
  }
}

$sourcePackages = @($sourcePackage)
$companionMcpSourcePackages = @(Get-CompanionMcpSourcePackages $pluginRoot)
$sourcePackages += $companionMcpSourcePackages
if ($companionMcpSourcePackages.Count -eq 0) {
  $installedSourceMarketplaceName = Get-InstalledDefaultPluginMarketplaceName $pluginRoot
  $allowedFallbackMarketplaces = if ($MarketplaceName -ne "*") {
    @($MarketplaceName)
  } elseif (-not [string]::IsNullOrWhiteSpace($installedSourceMarketplaceName)) {
    @($installedSourceMarketplaceName)
  } else {
    @()
  }
  $sourcePackages += @(Get-InstalledCompanionMcpVersionCandidatePackages $cachePackages $allowedFallbackMarketplaces)
}
$currentManifestVersionsByPackageName = Get-CurrentManifestVersionsByPackageName $sourcePackages

$processScopeCachePackages = @(
  $cachePackages |
    Where-Object {
    (Test-CachePackageIsCurrentForProcessScope $_ $currentManifestVersionsByPackageName) -and
    (Test-CachePackageCanScopeProcesses $_)
    }
)
$hasOptInMcpProcessScopePackage = @(
  $processScopeCachePackages |
    Where-Object { $_.package_name -eq "symphony-plus-plus-mcp" }
).Count -gt 0
$localOptInMcpProcessScopePackages = @{}
foreach ($package in @($processScopeCachePackages | Where-Object { $_.package_name -eq "symphony-plus-plus-mcp" -and $_.label -eq "local" })) {
  $localOptInMcpProcessScopePackages[[string]$package.marketplace_name] = $package
}

$cacheRepoRootFilters = @(
  $processScopeCachePackages |
  Where-Object {
    -not (
      $hasOptInMcpProcessScopePackage -and
      $_.package_name -eq "symphony-plus-plus" -and
      $_.default_plugin_lifecycle_status -eq "skill_only" -and
      $_.reference_mcp_server_status -eq "not_configured"
    ) -and -not (
      Test-VersionedOptInSuppressedByLocal $_ $localOptInMcpProcessScopePackages
    )
  } |
  ForEach-Object { Normalize-ComparablePath $_.source_root_hint } |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
  Sort-Object -Unique
)
$processRepoRootFilters = if ($repoRootFilter) {
  @($repoRootFilter)
} elseif ($cacheRepoRootFilters.Count -eq 1) {
  @($cacheRepoRootFilters[0])
} else {
  @()
}
$processScanScope = if ($repoRootFilter) {
  "repo_root_parameter"
} elseif ($processRepoRootFilters.Count -gt 0) {
  "installed_cache_source_root_hints"
} elseif ($cacheRepoRootFilters.Count -gt 1) {
  "skipped_ambiguous_cache_source_root_hints"
} else {
  "skipped_no_repo_root_scope"
}
$processScanSupported = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$processScanNote = if (-not $processScanSupported) {
  "Win32_Process process inventory is only available on Windows."
} elseif ($cacheRepoRootFilters.Count -gt 1 -and $processRepoRootFilters.Count -eq 0) {
  "Skipped scoped live process scan because selected installed caches point at multiple source roots; pass -RepoRoot to audit one checkout."
} elseif ($processRepoRootFilters.Count -eq 0) {
  "Skipped live process scan because no -RepoRoot value or installed-cache source-root hints were available for the selected Codex home and marketplace."
} else {
  $null
}
$shouldScanProcesses = $processScanSupported -and $processRepoRootFilters.Count -gt 0
$allProcesses = if ($shouldScanProcesses) {
  @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate)
} else {
  @()
}
$processById = @{}
foreach ($process in $allProcesses) {
  $processById[[int]$process.ProcessId] = $process
}
$allLauncherProcesses = @($allProcesses | Where-Object { $_.Name -match "^(pwsh|powershell)(\.exe)?$" -and $_.CommandLine -match "start-sympp-mcp\.ps1" })
$allCmdProcesses = @($allProcesses | Where-Object { $_.Name -eq "cmd.exe" -and $_.CommandLine -match "mix\.bat.*sympp\.mcp --mode stdio" })
$allMiseProcesses = @($allProcesses | Where-Object { $_.Name -match "^mise(\.exe)?$" -and $_.CommandLine -match "exec.*mix.*sympp\.mcp --mode stdio" })
$allErlProcesses = @($allProcesses | Where-Object { $_.Name -eq "erl.exe" -and $_.CommandLine -match "sympp\.mcp --mode stdio" })

$cmdProcesses = @($allCmdProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
$miseProcesses = @($allMiseProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
$erlProcesses = @($allErlProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
$allLauncherProcessIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($process in $allLauncherProcesses) {
  [void]$allLauncherProcessIds.Add([int]$process.ProcessId)
}
$launcherProcessIds = [System.Collections.Generic.HashSet[int]]::new()
if ($processRepoRootFilters.Count -gt 0) {
  $directLauncherProcesses = @($allLauncherProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
  foreach ($process in $directLauncherProcesses) {
    [void]$launcherProcessIds.Add([int]$process.ProcessId)
  }
  $filterAnchorProcesses = @($cmdProcesses) + @($miseProcesses) + @($erlProcesses)
  foreach ($processId in @(Find-AncestorLauncherProcessIds $filterAnchorProcesses $processById $allLauncherProcessIds)) {
    [void]$launcherProcessIds.Add([int]$processId)
  }
}
$launcherProcesses = @($allLauncherProcesses | Where-Object { $launcherProcessIds.Contains([int]$_.ProcessId) })
$unattributedLauncherProcesses = if ($repoRootFilter -and $processRepoRootFilters.Count -gt 0) {
  @($allLauncherProcesses | Where-Object { -not $launcherProcessIds.Contains([int]$_.ProcessId) })
} else {
  @()
}

$repoRoots = @(
  $erlProcesses |
  ForEach-Object { Get-RepoRootFromCommand $_.CommandLine } |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
  Group-Object |
  Sort-Object Name |
  ForEach-Object { [pscustomobject]@{ repo_root = $_.Name; erl_processes = $_.Count } }
)

$launcherParents = @(
  $launcherProcesses |
  Group-Object ParentProcessId |
  Sort-Object Name |
  ForEach-Object {
    $parentProcessId = [int]$_.Name
    $parent = $allProcesses | Where-Object { $_.ProcessId -eq $parentProcessId } | Select-Object -First 1
    [pscustomobject]@{
      parent_pid = $parentProcessId
      launcher_count = $_.Count
      parent_name = if ($parent) { $parent.Name } else { $null }
      parent_command = if ($parent) { Sanitize-CommandLine $parent.CommandLine } else { $null }
    }
  }
)

$unattributedLauncherParents = @(
  $unattributedLauncherProcesses |
  Group-Object ParentProcessId |
  Sort-Object Name |
  ForEach-Object {
    $parentProcessId = [int]$_.Name
    $parent = $allProcesses | Where-Object { $_.ProcessId -eq $parentProcessId } | Select-Object -First 1
    [pscustomobject]@{
      parent_pid = $parentProcessId
      launcher_count = $_.Count
      parent_name = if ($parent) { $parent.Name } else { $null }
      parent_command = if ($parent) { Sanitize-CommandLine $parent.CommandLine } else { $null }
    }
  }
)

$summary = [pscustomobject]@{
  generated_at = (Get-Date).ToString("o")
  codex_home = $codexHomePath
  marketplace_name = $MarketplaceName
  repo_root_filter = $RepoRoot
  process_scan_supported = $processScanSupported
  process_scan_scope = $processScanScope
  process_repo_root_filters = @($processRepoRootFilters)
  process_scan_note = $processScanNote
  source_package = $sourcePackage
  installed_cache = @($cachePackages)
  codex_config = Get-PluginConfigSummary (Join-Path $codexHomePath "config.toml") $MarketplaceName
  live_process_counts = [pscustomobject]@{
    start_sympp_mcp_pwsh = $launcherProcesses.Count
    start_sympp_mcp_pwsh_unattributed = $unattributedLauncherProcesses.Count
    mix_cmd_sympp_mcp = $cmdProcesses.Count
    mise_sympp_mcp = $miseProcesses.Count
    erl_sympp_mcp = $erlProcesses.Count
  }
  live_repo_roots = @($repoRoots)
  launcher_parents = @($launcherParents)
  unattributed_launcher_parents = @($unattributedLauncherParents)
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 8
  exit 0
}

Write-Host "Symphony++ plugin MCP lifecycle diagnostic"
Write-Host "  generated_at: $($summary.generated_at)"
Write-Host "  codex_home: $($summary.codex_home)"
Write-Host "  marketplace_name: $($summary.marketplace_name)"
Write-Host "  process_scan_supported: $($summary.process_scan_supported)"
Write-Host "  process_scan_scope: $($summary.process_scan_scope)"
if ($summary.process_scan_note) {
  Write-Host "  process_scan_note: $($summary.process_scan_note)"
}
Write-Host "  plugin_enabled: $($summary.codex_config.symphony_plugin_enabled)"
Write-Host "  global_sympp_mcp_entry: $($summary.codex_config.global_sympp_mcp_entry)"
Write-Host "  source_mcp_shape: $($summary.source_package.mcp_shape)"
Write-Host "  live start-sympp-mcp pwsh: $($summary.live_process_counts.start_sympp_mcp_pwsh)"
Write-Host "  live unattributed start-sympp-mcp pwsh: $($summary.live_process_counts.start_sympp_mcp_pwsh_unattributed)"
Write-Host "  live mix.bat sympp.mcp cmd: $($summary.live_process_counts.mix_cmd_sympp_mcp)"
Write-Host "  live mise exec mix sympp.mcp: $($summary.live_process_counts.mise_sympp_mcp)"
Write-Host "  live erl sympp.mcp: $($summary.live_process_counts.erl_sympp_mcp)"
Write-Host ""
Write-Host "Installed cache:"
foreach ($package in $summary.installed_cache) {
  Write-Host "  $($package.marketplace_name)/$($package.package_name)/$($package.label): version=$($package.manifest_version) lifecycle=$($package.default_plugin_lifecycle_status) shape=$($package.mcp_shape) server=$($package.symphony_plus_plus_server) http=$($package.http_mcp_reachability_status) source=$($package.source_root_hint)"
}
Write-Host ""
Write-Host "Live repo roots:"
foreach ($root in $summary.live_repo_roots) {
  Write-Host "  $($root.repo_root): erl=$($root.erl_processes)"
}
Write-Host ""
Write-Host "Launcher parents:"
foreach ($parent in $summary.launcher_parents) {
  Write-Host "  pid=$($parent.parent_pid) count=$($parent.launcher_count) name=$($parent.parent_name) cmd=$($parent.parent_command)"
}
Write-Host ""
Write-Host "Unattributed launcher parents:"
foreach ($parent in $summary.unattributed_launcher_parents) {
  Write-Host "  pid=$($parent.parent_pid) count=$($parent.launcher_count) name=$($parent.parent_name) cmd=$($parent.parent_command)"
}
