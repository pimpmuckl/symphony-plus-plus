param(
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$HOME/.codex" }),
  [string]$MarketplaceName = "*",
  [string]$RepoRoot,
  [switch]$SelfTest,
  [switch]$Doctor,
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

function Quote-PowerShellLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Test-SourceCheckoutRoot([string]$Path) {
  $fullPath = Resolve-OptionalFullPath $Path
  if (-not $fullPath) {
    return $false
  }

  return (Test-Path -LiteralPath (Join-Path $fullPath "elixir/mix.exs")) -and
    (Test-Path -LiteralPath (Join-Path $fullPath "scripts/refresh-local-plugin.ps1")) -and
    (Test-Path -LiteralPath (Join-Path $fullPath "scripts/smoke-sympp-mcp-http.ps1"))
}

function Get-SourceCheckoutFromPluginRoot([string]$PluginRoot) {
  if ([string]::IsNullOrWhiteSpace($PluginRoot)) {
    return $null
  }

  $candidate = Split-Path (Split-Path $PluginRoot -Parent) -Parent
  if (Test-SourceCheckoutRoot $candidate) {
    return Resolve-OptionalFullPath $candidate
  }

  return $null
}

function Get-SourceCheckoutFromCurrentDirectory {
  try {
    $candidate = (Get-Location).ProviderPath
  } catch {
    return $null
  }

  while (-not [string]::IsNullOrWhiteSpace($candidate)) {
    if (Test-SourceCheckoutRoot $candidate) {
      return Resolve-OptionalFullPath $candidate
    }

    $parent = Split-Path $candidate -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
      break
    }
    $candidate = $parent
  }

  return $null
}

function Test-PackageCanProvideSourceRootHint($Package) {
  if ($null -eq $Package) {
    return $false
  }

  if ($Package.package_name -eq "symphony-plus-plus") {
    return Test-DefaultPackageReady $Package
  }

  if ($Package.package_name -eq "symphony-plus-plus-mcp") {
    return Test-McpCompanionPackageReady $Package
  }

  return $false
}

function Get-UsableSourceHintRoots($Packages) {
  return @(
    $Packages |
      Where-Object { Test-PackageCanProvideSourceRootHint $_ } |
      ForEach-Object { Resolve-OptionalFullPath $_.source_root_hint } |
      Where-Object { Test-SourceCheckoutRoot $_ } |
      Sort-Object -Unique
  )
}

function New-SourceCheckoutStatus([string]$Status, [string]$Root, [string]$Note = $null) {
  return [pscustomobject]@{
    status = $Status
    root = $Root
    note = $Note
  }
}

function Resolve-ReadinessSourceCheckout([string]$PluginRoot, [string]$ProvidedRepoRoot, $PreferredPackages) {
  if (Test-SourceCheckoutRoot $ProvidedRepoRoot) {
    return New-SourceCheckoutStatus "repo_root_parameter" (Resolve-OptionalFullPath $ProvidedRepoRoot)
  }

  $sourceCheckoutRoot = Get-SourceCheckoutFromPluginRoot $PluginRoot
  if ($sourceCheckoutRoot) {
    return New-SourceCheckoutStatus "source_plugin_root" $sourceCheckoutRoot
  }

  $sourceCheckoutRoot = Get-SourceCheckoutFromCurrentDirectory
  if ($sourceCheckoutRoot) {
    return New-SourceCheckoutStatus "current_working_directory" $sourceCheckoutRoot
  }

  $preferredHintRoots = Get-UsableSourceHintRoots $PreferredPackages
  if ($preferredHintRoots.Count -eq 1) {
    return New-SourceCheckoutStatus "installed_cache_source_root_hint" (@($preferredHintRoots)[0])
  }

  if ($preferredHintRoots.Count -gt 1) {
    return New-SourceCheckoutStatus "ambiguous_selected_installed_cache_source_root_hints" $null "Selected installed caches point at multiple usable source roots; rerun this doctor with -RepoRoot <path-to-symphony-plus-plus-checkout>."
  }

  return New-SourceCheckoutStatus "not_found" $null "No Symphony++ source checkout could be inferred; rerun this doctor with -RepoRoot <path-to-symphony-plus-plus-checkout>."
}

function New-SourceScriptCommand([string]$SourceCheckoutRoot, [string]$RelativeScript, [string]$Arguments = $null) {
  if ([string]::IsNullOrWhiteSpace($SourceCheckoutRoot)) {
    return $null
  }

  $scriptPath = [System.IO.Path]::GetFullPath((Join-Path $SourceCheckoutRoot $RelativeScript))
  $command = "& $(Quote-PowerShellLiteral $scriptPath)"
  if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
    $command = "$command $Arguments"
  }

  return $command
}

function New-CockpitCommand([string]$SourceCheckoutRoot) {
  if ([string]::IsNullOrWhiteSpace($SourceCheckoutRoot)) {
    return $null
  }

  $elixirRoot = [System.IO.Path]::GetFullPath((Join-Path $SourceCheckoutRoot "elixir"))
  return "Set-Location $(Quote-PowerShellLiteral $elixirRoot); mix sympp.cockpit"
}

function New-SourceCheckoutAction([string]$Code, [string]$Lane, [string]$Message, $SourceCheckout, [string]$Command) {
  if (-not [string]::IsNullOrWhiteSpace($Command)) {
    return New-ReadinessAction $Code $Lane $Message $Command
  }

  $note = if ($null -ne $SourceCheckout -and -not [string]::IsNullOrWhiteSpace([string]$SourceCheckout.note)) {
    [string]$SourceCheckout.note
  } else {
    "No Symphony++ source checkout could be inferred; rerun this doctor with -RepoRoot <path-to-symphony-plus-plus-checkout>."
  }

  return New-ReadinessAction $Code $Lane "$Message $note"
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

  $quoted = Quote-PowerShellLiteral "C:\Symphony Roots\O'Hara"
  if ($quoted -ne "'C:\Symphony Roots\O''Hara'") {
    throw "Quote-PowerShellLiteral did not emit a valid single-quoted literal."
  }

  $sourceCommand = New-SourceScriptCommand "C:\Symphony Roots\Repo" "scripts/smoke-sympp-mcp-http.ps1" "-Json"
  if ($sourceCommand -ne "& 'C:\Symphony Roots\Repo\scripts\smoke-sympp-mcp-http.ps1' -Json") {
    throw "New-SourceScriptCommand did not emit an absolute PowerShell invocation."
  }

  $missingSourceAction = New-SourceCheckoutAction "verify_http_mcp" "workrequest_mcp" "Verify the local HTTP MCP daemon." ([pscustomobject]@{ note = "No checkout." }) $null
  if ($missingSourceAction.PSObject.Properties["command"] -or $missingSourceAction.message -notmatch "No checkout") {
    throw "New-SourceCheckoutAction should omit commands and explain missing source roots."
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
    symphony_default_plugin_enabled = Get-PluginEnabledFromEntries $entries "symphony-plus-plus" $MarketplaceName
    symphony_mcp_companion_plugin_enabled = Get-PluginEnabledFromEntries $entries "symphony-plus-plus-mcp" $MarketplaceName
    global_sympp_mcp_entry = [bool]($lines | Where-Object { $_ -match '^\[mcp_servers\.symphony_plus_plus\]' } | Select-Object -First 1)
  }
}

function Get-PluginEnabledFromEntries($Entries, [string]$PluginName, [string]$MarketplaceName) {
  $matchingEntries = @(
    $Entries |
      Where-Object {
        $_.plugin_name -eq $PluginName -and
        ($MarketplaceName -eq "*" -or $_.marketplace_name -eq $MarketplaceName)
      }
  )

  if (@($matchingEntries | Where-Object { $_.enabled -eq $true }).Count -gt 0) {
    return $true
  }
  if (@($matchingEntries | Where-Object { $_.enabled -eq $false }).Count -gt 0) {
    return $false
  }

  return $null
}

function New-ReadinessAction([string]$Code, [string]$Lane, [string]$Message, [string]$Command = $null) {
  $action = [ordered]@{
    code = $Code
    lane = $Lane
    message = $Message
  }
  if (-not [string]::IsNullOrWhiteSpace($Command)) {
    $action["command"] = $Command
  }

  return [pscustomobject]$action
}

function New-ReadinessWarning([string]$Code, [string]$Message) {
  return [pscustomobject]@{
    code = $Code
    message = $Message
  }
}

function Get-ActivationConfigKey([string]$PluginName, [string]$MarketplaceName) {
  if ([string]::IsNullOrWhiteSpace($MarketplaceName) -or $MarketplaceName -eq "*") {
    return "$PluginName@<marketplace>"
  }

  return "$PluginName@$MarketplaceName"
}

function Test-ActivationMarketplaceAmbiguous($CachePackages, [string]$MarketplaceName) {
  if ($MarketplaceName -ne "*") {
    return $false
  }

  $marketplaces = @(
    $CachePackages |
      Where-Object { $SymppPluginPackageNames -contains $_.package_name } |
      ForEach-Object { [string]$_.marketplace_name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique
  )

  return $marketplaces.Count -gt 1
}

function Get-PreferredActivationPackage($CachePackages, [string]$PackageName, [string]$MarketplaceName) {
  $packages = @(
    $CachePackages |
      Where-Object {
        $_.package_name -eq $PackageName -and
        ($MarketplaceName -eq "*" -or $_.marketplace_name -eq $MarketplaceName)
      } |
      ForEach-Object {
        $isReady = if ($PackageName -eq "symphony-plus-plus") {
          Test-DefaultPackageReady $_
        } elseif ($PackageName -eq "symphony-plus-plus-mcp") {
          Test-McpCompanionPackageReady $_
        } else {
          $false
        }
        $readyPriority = if ($isReady) { 0 } else { 1 }
        $priority = if ($_.label -eq "local") {
          0
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$_.manifest_version) -and $_.label -eq $_.manifest_version) {
          1
        } else {
          2
        }
        $parsedVersion = $null
        $versionSortKey = if ([System.Version]::TryParse([string]$_.manifest_version, [ref]$parsedVersion)) {
          $parsedVersion
        } else {
          [System.Version]::new(0, 0)
        }

        [pscustomobject]@{
          ready_priority = $readyPriority
          priority = $priority
          version_sort_key = $versionSortKey
          package = $_
        }
      } |
      Sort-Object ready_priority, priority, @{ Expression = { [string]$_.package.marketplace_name } }, @{ Expression = { $_.version_sort_key }; Descending = $true }, @{ Expression = { [string]$_.package.label }; Descending = $true }
  )

  if ($packages.Count -eq 0) {
    return $null
  }

  return $packages[0].package
}

function Get-PreferredActivationSourceHintPackage($CachePackages, [string]$PackageName, [string]$MarketplaceName) {
  $packages = @(
    $CachePackages |
      Where-Object {
        $_.package_name -eq $PackageName -and
        ($MarketplaceName -eq "*" -or $_.marketplace_name -eq $MarketplaceName) -and
        (Test-PackageCanProvideSourceRootHint $_) -and
        (Test-SourceCheckoutRoot (Resolve-OptionalFullPath $_.source_root_hint))
      } |
      ForEach-Object {
        $priority = if ($_.label -eq "local") {
          0
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$_.manifest_version) -and $_.label -eq $_.manifest_version) {
          1
        } else {
          2
        }
        $parsedVersion = $null
        $versionSortKey = if ([System.Version]::TryParse([string]$_.manifest_version, [ref]$parsedVersion)) {
          $parsedVersion
        } else {
          [System.Version]::new(0, 0)
        }

        [pscustomobject]@{
          priority = $priority
          version_sort_key = $versionSortKey
          package = $_
        }
      } |
      Sort-Object priority, @{ Expression = { [string]$_.package.marketplace_name } }, @{ Expression = { $_.version_sort_key }; Descending = $true }, @{ Expression = { [string]$_.package.label }; Descending = $true }
  )

  if ($packages.Count -eq 0) {
    return $null
  }

  return $packages[0].package
}

function Get-ActivationSourceHintPackages($CachePackages, [string]$MarketplaceName) {
  return @(
    foreach ($packageName in $SymppPluginPackageNames) {
      Get-PreferredActivationSourceHintPackage $CachePackages $packageName $MarketplaceName
    }
  )
}

function Test-DefaultPackageReady($Package) {
  return $null -ne $Package -and
    $Package.package_name -eq "symphony-plus-plus" -and
    $Package.manifest_exists -eq $true -and
    [string]::IsNullOrWhiteSpace([string]$Package.manifest_parse_error) -and
    $Package.default_plugin_lifecycle_status -eq "skill_only"
}

function Test-McpCompanionPackageReady($Package) {
  return $null -ne $Package -and
    $Package.package_name -eq "symphony-plus-plus-mcp" -and
    $Package.manifest_exists -eq $true -and
    [string]::IsNullOrWhiteSpace([string]$Package.manifest_parse_error) -and
    $Package.default_plugin_lifecycle_status -eq "opt_in_mcp_plugin_bundles_mcp" -and
    $Package.reference_mcp_server_status -eq "ok"
}

function Get-ReadinessSummary($CachePackages, $Config, [string]$MarketplaceName, $SourceCheckout, [string]$CodexHomePath) {
  $marketplaceAmbiguous = Test-ActivationMarketplaceAmbiguous $CachePackages $MarketplaceName
  $defaultPackage = if ($marketplaceAmbiguous) { $null } else { Get-PreferredActivationPackage $CachePackages "symphony-plus-plus" $MarketplaceName }
  $companionPackage = if ($marketplaceAmbiguous) { $null } else { Get-PreferredActivationPackage $CachePackages "symphony-plus-plus-mcp" $MarketplaceName }
  $defaultMarketplace = if ($null -ne $defaultPackage -and -not [string]::IsNullOrWhiteSpace([string]$defaultPackage.marketplace_name)) {
    [string]$defaultPackage.marketplace_name
  } elseif ($MarketplaceName -ne "*") {
    $MarketplaceName
  } else {
    $null
  }
  $companionMarketplace = if ($null -ne $companionPackage -and -not [string]::IsNullOrWhiteSpace([string]$companionPackage.marketplace_name)) {
    [string]$companionPackage.marketplace_name
  } elseif ($MarketplaceName -ne "*") {
    $MarketplaceName
  } else {
    $defaultMarketplace
  }

  $configExists = $Config.exists -eq $true
  $defaultEnabled = if ($configExists) { Get-PluginEnabledFromEntries $Config.symphony_plugin_entries "symphony-plus-plus" $defaultMarketplace } else { $null }
  $companionEnabled = if ($configExists) { Get-PluginEnabledFromEntries $Config.symphony_plugin_entries "symphony-plus-plus-mcp" $companionMarketplace } else { $null }
  $defaultReady = Test-DefaultPackageReady $defaultPackage
  $companionReady = Test-McpCompanionPackageReady $companionPackage
  $companionProvidesSoloSkills = $companionReady -and $companionEnabled -eq $true
  $sourceRoot = if ($null -ne $SourceCheckout) { [string]$SourceCheckout.root } else { $null }
  $refreshCodexHomeArg = if ([string]::IsNullOrWhiteSpace($CodexHomePath)) { "" } else { "-CodexHome $(Quote-PowerShellLiteral $CodexHomePath) " }
  $defaultRefreshMarketplaceArg = if ([string]::IsNullOrWhiteSpace($defaultMarketplace)) { "" } else { "-MarketplaceName $(Quote-PowerShellLiteral $defaultMarketplace) " }
  $companionRefreshMarketplaceArg = if ([string]::IsNullOrWhiteSpace($companionMarketplace)) { "" } else { "-MarketplaceName $(Quote-PowerShellLiteral $companionMarketplace) " }
  $actions = @()
  $warnings = @()

  if (-not $configExists) {
    $actions += New-ReadinessAction "create_codex_config" "config" "Create or restore the Codex config at $($Config.path) before plugin enablement can be diagnosed."
  }
  if ($marketplaceAmbiguous) {
    $actions += New-ReadinessAction "rerun_with_marketplace" "config" "Multiple Symphony++ plugin marketplaces are installed; rerun this doctor with -MarketplaceName <marketplace> before using package-specific repair actions."
  }

  $defaultStatus = if (-not $configExists) {
    "config_missing"
  } elseif ($companionProvidesSoloSkills) {
    "ready_via_mcp_companion"
  } elseif (-not $defaultReady) {
    "default_plugin_cache_missing_or_invalid"
  } elseif ($defaultEnabled -ne $true) {
    "default_plugin_not_enabled"
  } else {
    "ready"
  }

  if (-not $marketplaceAmbiguous -and -not $defaultReady -and -not $companionProvidesSoloSkills) {
    $actions += New-SourceCheckoutAction "refresh_default_plugin_cache" "solo_session" "Refresh the skill-only Symphony++ plugin cache." $SourceCheckout (New-SourceScriptCommand $sourceRoot "scripts/refresh-local-plugin.ps1" "$($refreshCodexHomeArg)$($defaultRefreshMarketplaceArg)-PluginName symphony-plus-plus -ValidateInstalledCache")
  } elseif (-not $marketplaceAmbiguous -and $configExists -and $defaultEnabled -ne $true -and -not $companionProvidesSoloSkills) {
    $defaultConfigKey = Get-ActivationConfigKey "symphony-plus-plus" $defaultMarketplace
    $actions += New-ReadinessAction "enable_default_plugin" "solo_session" "Enable the default skill-only plugin for Solo Session planning: [plugins.`"$defaultConfigKey`"] enabled = true."
  }

  $companionStatus = if (-not $configExists) {
    "config_missing"
  } elseif (-not $companionReady) {
    if ($null -eq $companionPackage) {
      "companion_cache_missing"
    } else {
      "companion_config_invalid"
    }
  } elseif ($companionEnabled -ne $true) {
    "companion_installed_not_enabled"
  } elseif ($companionPackage.http_mcp_reachability_status -eq "mcp_endpoint_available") {
    "ready"
  } elseif ($companionPackage.http_mcp_reachability_status -eq "unreachable") {
    "endpoint_unreachable"
  } else {
    [string]$companionPackage.http_mcp_reachability_status
  }

  if (-not $marketplaceAmbiguous -and -not $companionReady) {
    $actions += New-SourceCheckoutAction "refresh_mcp_companion_cache" "workrequest_mcp" "Refresh the opt-in MCP companion cache and validate its HTTP .mcp.json." $SourceCheckout (New-SourceScriptCommand $sourceRoot "scripts/refresh-local-plugin.ps1" "$($refreshCodexHomeArg)$($companionRefreshMarketplaceArg)-PluginName symphony-plus-plus-mcp -ValidateInstalledCache")
  } elseif (-not $marketplaceAmbiguous -and $configExists -and $companionEnabled -ne $true) {
    $companionConfigKey = Get-ActivationConfigKey "symphony-plus-plus-mcp" $companionMarketplace
    $actions += New-ReadinessAction "enable_mcp_companion" "workrequest_mcp" "Enable the opt-in MCP companion only in a dedicated S++ config/session: [plugins.`"$companionConfigKey`"] enabled = true."
    $actions += New-ReadinessAction "restart_codex_session" "workrequest_mcp" "Restart or reload that dedicated Codex session so plugin MCP servers register before the model starts."
  } elseif (-not $marketplaceAmbiguous -and $companionStatus -eq "endpoint_unreachable") {
    $actions += New-SourceCheckoutAction "start_cockpit" "workrequest_mcp" "Start the local Symphony++ cockpit/HTTP MCP daemon." $SourceCheckout (New-CockpitCommand $sourceRoot)
    $actions += New-SourceCheckoutAction "verify_http_mcp" "workrequest_mcp" "Verify the local HTTP MCP daemon independently of Codex plugin loading." $SourceCheckout (New-SourceScriptCommand $sourceRoot "scripts/smoke-sympp-mcp-http.ps1")
  } elseif (-not $marketplaceAmbiguous -and $companionStatus -eq "ready") {
    $actions += New-ReadinessAction "verify_codex_session" "workrequest_mcp" "If the current Codex session still lacks symphony_plus_plus tools, restart or reload the dedicated MCP-enabled session; this doctor verifies config, cache, and daemon readiness, not the already-open model tool list."
  }

  if ($Config.global_sympp_mcp_entry -eq $true) {
    $warnings += New-ReadinessWarning "global_sympp_mcp_entry_present" "A top-level [mcp_servers.symphony_plus_plus] entry is present. Keep this out of generic worker/review configs unless every session using that config should see S++ MCP."
    $actions += New-ReadinessAction "relocate_global_sympp_mcp_entry" "config" "Remove the top-level [mcp_servers.symphony_plus_plus] entry from generic configs, or move S++ MCP activation into a dedicated plugin-enabled S++ config/session."
  }

  $soloReady = $defaultStatus -eq "ready" -or $defaultStatus -eq "ready_via_mcp_companion"
  $overallStatus = if (-not $configExists) {
    "config_missing"
  } elseif ($marketplaceAmbiguous) {
    "multiple_marketplaces_need_selection"
  } elseif ($Config.global_sympp_mcp_entry -eq $true) {
    "global_footgun_present"
  } elseif ($soloReady -and $companionStatus -eq "ready") {
    "healthy_local_workrequest_mcp"
  } elseif ($defaultStatus -eq "ready" -and $companionStatus -eq "companion_installed_not_enabled") {
    "solo_ready_mcp_companion_not_enabled"
  } elseif ($companionStatus -eq "endpoint_unreachable") {
    "mcp_companion_endpoint_unreachable"
  } elseif ($companionStatus -eq "companion_installed_not_enabled") {
    "mcp_companion_not_enabled"
  } elseif ($defaultStatus -eq "ready") {
    "solo_ready_mcp_not_ready"
  } else {
    "needs_repair"
  }

  return [pscustomobject]@{
    overall_status = $overallStatus
    marketplace_name = if ($MarketplaceName -eq "*" -and $defaultMarketplace -eq $companionMarketplace -and -not [string]::IsNullOrWhiteSpace($defaultMarketplace)) { $defaultMarketplace } else { $MarketplaceName }
    source_checkout = $SourceCheckout
    solo_session = [pscustomobject]@{
      status = $defaultStatus
      plugin_config_key = Get-ActivationConfigKey "symphony-plus-plus" $defaultMarketplace
      plugin_enabled = $defaultEnabled
      cache_label = if ($null -ne $defaultPackage) { $defaultPackage.label } else { $null }
      cache_lifecycle = if ($null -ne $defaultPackage) { $defaultPackage.default_plugin_lifecycle_status } else { $null }
    }
    workrequest_mcp = [pscustomobject]@{
      status = $companionStatus
      companion_config_key = Get-ActivationConfigKey "symphony-plus-plus-mcp" $companionMarketplace
      companion_plugin_enabled = $companionEnabled
      cache_label = if ($null -ne $companionPackage) { $companionPackage.label } else { $null }
      cache_lifecycle = if ($null -ne $companionPackage) { $companionPackage.default_plugin_lifecycle_status } else { $null }
      reference_mcp_server_status = if ($null -ne $companionPackage) { $companionPackage.reference_mcp_server_status } else { $null }
      http_mcp_reachability_status = if ($null -ne $companionPackage) { $companionPackage.http_mcp_reachability_status } else { $null }
      url = "http://127.0.0.1:4057/mcp"
    }
    next_actions = @($actions)
    warnings = @($warnings)
    session_visibility_note = "This doctor verifies source/cache/config and the local HTTP daemon. It cannot inspect tools already registered inside an open Codex model session; restart or reload the dedicated MCP-enabled session after config/cache changes."
    generic_review_boundary = "Keep symphony-plus-plus-mcp out of generic worker, worker_smart, review-suite, and codex review configs; use a dedicated S++ MCP-enabled config/session instead."
  }
}

function Write-DoctorSummary($Summary) {
  $readiness = $Summary.readiness
  Write-Host "Symphony++ activation doctor"
  Write-Host "  overall: $($readiness.overall_status)"
  Write-Host "  codex_home: $($Summary.codex_home)"
  Write-Host "  marketplace: $($readiness.marketplace_name)"
  Write-Host "  source checkout: $($readiness.source_checkout.status) $($readiness.source_checkout.root)"
  if (-not [string]::IsNullOrWhiteSpace([string]$readiness.source_checkout.note)) {
    Write-Host "  source note: $($readiness.source_checkout.note)"
  }
  Write-Host "  config: $($Summary.codex_config.path)"
  Write-Host ""
  Write-Host "Solo Session skill package"
  Write-Host "  status: $($readiness.solo_session.status)"
  Write-Host "  config key: $($readiness.solo_session.plugin_config_key)"
  Write-Host "  enabled: $($readiness.solo_session.plugin_enabled)"
  Write-Host "  cache: $($readiness.solo_session.cache_label) / $($readiness.solo_session.cache_lifecycle)"
  Write-Host ""
  Write-Host "WorkRequest MCP companion"
  Write-Host "  status: $($readiness.workrequest_mcp.status)"
  Write-Host "  config key: $($readiness.workrequest_mcp.companion_config_key)"
  Write-Host "  enabled: $($readiness.workrequest_mcp.companion_plugin_enabled)"
  Write-Host "  cache: $($readiness.workrequest_mcp.cache_label) / $($readiness.workrequest_mcp.cache_lifecycle)"
  Write-Host "  server: $($readiness.workrequest_mcp.reference_mcp_server_status)"
  Write-Host "  endpoint: $($readiness.workrequest_mcp.http_mcp_reachability_status)"
  Write-Host "  url: $($readiness.workrequest_mcp.url)"
  Write-Host ""

  if (@($readiness.warnings).Count -gt 0) {
    Write-Host "Warnings:"
    foreach ($warning in @($readiness.warnings)) {
      Write-Host "  - [$($warning.code)] $($warning.message)"
    }
    Write-Host ""
  }

  if (@($readiness.next_actions).Count -gt 0) {
    Write-Host "Next actions:"
    foreach ($action in @($readiness.next_actions)) {
      Write-Host "  - [$($action.code)] $($action.message)"
      if ($action.PSObject.Properties["command"]) {
        Write-Host "    $($action.command)"
      }
    }
  } else {
    Write-Host "Next actions: none"
  }

  Write-Host ""
  Write-Host "Session visibility: $($readiness.session_visibility_note)"
  Write-Host ""
  Write-Host "Boundary: $($readiness.generic_review_boundary)"
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

$readinessSourcePackages = @(
  if (-not (Test-ActivationMarketplaceAmbiguous $cachePackages $MarketplaceName)) {
    Get-ActivationSourceHintPackages $cachePackages $MarketplaceName
  }
) | Where-Object { $null -ne $_ }
$sourceCheckout = Resolve-ReadinessSourceCheckout $pluginRoot $RepoRoot $readinessSourcePackages
$summary | Add-Member -NotePropertyName source_checkout -NotePropertyValue $sourceCheckout
$summary | Add-Member -NotePropertyName readiness -NotePropertyValue (Get-ReadinessSummary $summary.installed_cache $summary.codex_config $MarketplaceName $sourceCheckout $codexHomePath)

if ($Json) {
  $summary | ConvertTo-Json -Depth 8
  exit 0
}

if ($Doctor) {
  Write-DoctorSummary $summary
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
Write-Host "  readiness: $($summary.readiness.overall_status)"
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
