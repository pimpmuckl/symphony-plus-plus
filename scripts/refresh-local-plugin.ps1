param(
  [string]$MarketplacePath,
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$HOME/.codex" }),
  [string]$PluginName = "all",
  [switch]$ValidateInstalledCache
)

$ErrorActionPreference = "Stop"
$SymppPluginPackageNames = @("symphony-plus-plus", "symphony-plus-plus-mcp")

function Resolve-StrictPath([string]$Path) {
  return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Resolve-ConfiguredSourcePath([string]$SourcePath, [string]$MarketplaceFile, [string]$RepoRoot) {
  if ([System.IO.Path]::IsPathRooted($SourcePath)) {
    $rootedPath = [System.IO.Path]::GetFullPath($SourcePath)
    if (Test-Path -LiteralPath $rootedPath) {
      return $rootedPath
    }

    throw "Configured plugin source path does not exist: $rootedPath"
  }

  $repoRelative = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $SourcePath))
  if (Test-Path -LiteralPath $repoRelative) {
    return $repoRelative
  }

  $marketplaceRelative = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MarketplaceFile) $SourcePath))
  if (Test-Path -LiteralPath $marketplaceRelative) {
    return $marketplaceRelative
  }

  throw "Configured plugin source path '$SourcePath' was not found relative to repo root '$RepoRoot' or marketplace file '$MarketplaceFile'."
}

function Join-And-Normalize([string]$Base, [string[]]$Parts) {
  return [System.IO.Path]::GetFullPath((Join-Path -Path $Base -ChildPath ([System.IO.Path]::Combine($Parts))))
}

function Assert-PathInside([string]$Child, [string]$Parent, [string]$Message) {
  $parentWithSeparator = $Parent.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $Child.StartsWith($parentWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Message`: $Child"
  }
}

function Assert-SafeCacheTarget([string]$Target, [string]$PluginCacheRoot) {
  Assert-PathInside $Target $PluginCacheRoot "Resolved target cache path is outside this plugin cache"
}

function Assert-NotReparsePoint([string]$Target) {
  if (-not (Test-Path -LiteralPath $Target)) {
    return
  }

  $item = Get-Item -LiteralPath $Target -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to refresh reparse-point plugin cache directory. Remove the link manually and rerun refresh: $Target"
  }
}

function Assert-NoReparsePointDescendants([string]$Target) {
  if (-not (Test-Path -LiteralPath $Target)) {
    return
  }

  $reparsePoint = Get-ChildItem -LiteralPath $Target -Force -Recurse -ErrorAction Stop |
    Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
    Select-Object -First 1
  if ($null -ne $reparsePoint) {
    throw "Refusing to refresh plugin cache directory containing a reparse-point child. Remove the link manually and rerun refresh: $($reparsePoint.FullName)"
  }
}

function Assert-ExistingCachePathNotReparsePoint([string[]]$Paths) {
  foreach ($path in $Paths) {
    Assert-NotReparsePoint $path
  }
}

function Copy-PluginCacheTarget([string]$TargetRoot, [string]$SourceRoot, [string]$RepoRoot) {
  Assert-SafeCacheTarget $TargetRoot $pluginCacheRoot
  Assert-NotReparsePoint $TargetRoot
  Assert-NoReparsePointDescendants $TargetRoot

  New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null

  foreach ($item in @(".codex-plugin", ".mcp.json", "skills", "skills-default", "scripts", "README.md")) {
    $source = Join-Path $SourceRoot $item
    if (Test-Path -LiteralPath $source) {
      $target = Join-Path $TargetRoot $item
      Assert-NotReparsePoint $target
      Assert-NoReparsePointDescendants $target
      Copy-Item -LiteralPath $source -Destination $TargetRoot -Recurse -Force
    }
  }

  $sourceRootHintPath = Join-Path $TargetRoot ".sympp-source-root"
  Assert-NotReparsePoint $sourceRootHintPath
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($sourceRootHintPath, "$RepoRoot`n", $utf8NoBom)
}

function Assert-SafeVersionSegment([string]$Version) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Plugin manifest must include a non-empty version."
  }

  if ($Version.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Version.Contains("/") -or $Version.Contains("\")) {
    throw "Plugin manifest version is not safe for a cache directory name: $Version"
  }
}

function Assert-RequiredJsonValue($Value, [string]$Message) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    throw $Message
  }
}

function Resolve-DocumentedMcpServerMap($McpConfig, [string]$McpConfigPath) {
  $propertyNames = @($McpConfig.PSObject.Properties.Name)
  if ($propertyNames -contains "mcpServers") {
    throw "Plugin .mcp.json must use a documented shape: direct server map or wrapped mcp_servers, not mcpServers: $McpConfigPath"
  }

  if ($propertyNames -contains "mcp_servers") {
    return $McpConfig.mcp_servers
  }

  return $McpConfig
}

function Assert-CachePluginConfig([string]$TargetRoot, [string]$ExpectedVersion) {
  $targetManifestPath = Join-Path $TargetRoot ".codex-plugin/plugin.json"
  $targetManifest = Get-Content -LiteralPath $targetManifestPath -Raw | ConvertFrom-Json
  if ($targetManifest.name -ne $PluginName) {
    throw "Installed plugin manifest name mismatch in $targetManifestPath."
  }
  if ($targetManifest.version -ne $ExpectedVersion) {
    throw "Installed plugin manifest version mismatch in $targetManifestPath."
  }
  $manifestHasMcpServers = @($targetManifest.PSObject.Properties.Name) -contains "mcpServers"
  if ($PluginName -eq "symphony-plus-plus" -and $manifestHasMcpServers) {
    throw "Default installed plugin manifest must not declare mcpServers; keep generic S++ MCP opt-in instead: $targetManifestPath"
  }
  if ($PluginName -eq "symphony-plus-plus-mcp" -and (-not $manifestHasMcpServers -or $targetManifest.mcpServers -ne "./.mcp.json")) {
    throw "Opt-in MCP plugin manifest must declare mcpServers './.mcp.json': $targetManifestPath"
  }

  $mcpConfigPath = [System.IO.Path]::GetFullPath((Join-Path $TargetRoot ".mcp.json"))
  Assert-PathInside $mcpConfigPath $TargetRoot "Installed plugin reference .mcp.json path resolves outside this cache"
  if (-not (Test-Path -LiteralPath $mcpConfigPath)) {
    throw "Installed plugin reference .mcp.json path does not exist: $mcpConfigPath"
  }

  $mcpConfig = Get-Content -LiteralPath $mcpConfigPath -Raw | ConvertFrom-Json
  $serverMap = Resolve-DocumentedMcpServerMap $mcpConfig $mcpConfigPath
  $server = $serverMap.symphony_plus_plus
  if ($null -eq $server) {
    throw "Installed MCP config does not define symphony_plus_plus in a documented MCP config shape: $mcpConfigPath"
  }
  if ($server.type -ne "stdio") {
    throw "Installed MCP server type must be stdio: $mcpConfigPath"
  }
  if ($server.command -ne "pwsh") {
    throw "Installed MCP server command must be pwsh: $mcpConfigPath"
  }
  if ($server.cwd -ne ".") {
    throw "Installed MCP server cwd must remain cache-relative '.': $mcpConfigPath"
  }

  $args = @($server.args | ForEach-Object { [string]$_ })
  $expectedArgs = @(
    "-NoProfile",
    "-Command",
    '$env:PSExecutionPolicyPreference=''Bypass''; & ''scripts/start-sympp-mcp.ps1'''
  )
  if ($args.Count -ne $expectedArgs.Count) {
    throw "Installed MCP server args must have $($expectedArgs.Count) tokens: $mcpConfigPath"
  }

  for ($index = 0; $index -lt $expectedArgs.Count; $index++) {
    if ($args[$index] -ne $expectedArgs[$index]) {
      throw "Installed MCP server arg[$index] mismatch in $mcpConfigPath."
    }
  }
}

function Invoke-InstalledCacheValidation([string]$TargetRoot, [string]$Label, [string]$ExpectedVersion) {
  Assert-CachePluginConfig $TargetRoot $ExpectedVersion

  Push-Location -LiteralPath $TargetRoot
  try {
    & pwsh @(
      "-NoProfile",
      "-Command",
      "`$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1' -ValidateOnly"
    )
    if ($LASTEXITCODE -ne 0) {
      throw "Installed plugin MCP wrapper validation failed for $Label cache with exit code $LASTEXITCODE."
    }

    & pwsh @(
      "-NoProfile",
      "-Command",
      "`$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/sympp-solo.ps1' -ValidateOnly"
    )
    if ($LASTEXITCODE -ne 0) {
      throw "Installed plugin Solo Session wrapper validation failed for $Label cache with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }

  Write-Host "Validated installed Symphony++ plugin cache:"
  Write-Host "  cache: $Label"
  Write-Host "  root: $TargetRoot"
}

$repoRoot = Resolve-StrictPath (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($MarketplacePath)) {
  $MarketplacePath = Join-Path $repoRoot ".agents\plugins\marketplace.json"
}

$marketplaceFile = Resolve-StrictPath $MarketplacePath
$marketplace = Get-Content -LiteralPath $marketplaceFile -Raw | ConvertFrom-Json
$marketplaceName = [string]$marketplace.name
if ([string]::IsNullOrWhiteSpace($marketplaceName)) {
  throw "Marketplace file must include a top-level name."
}

if ($PluginName -in @("all", "*")) {
  $selectedPluginNames = @(
    @($marketplace.plugins) |
      Where-Object { $SymppPluginPackageNames -contains $_.name } |
      ForEach-Object { [string]$_.name } |
      Sort-Object -Unique
  )
  if ($selectedPluginNames.Count -eq 0) {
    throw "No Symphony++ plugins were found in $marketplaceFile."
  }

  foreach ($selectedPluginName in $selectedPluginNames) {
    if ($ValidateInstalledCache) {
      & $PSCommandPath -MarketplacePath $marketplaceFile -CodexHome $CodexHome -PluginName $selectedPluginName -ValidateInstalledCache
    } else {
      & $PSCommandPath -MarketplacePath $marketplaceFile -CodexHome $CodexHome -PluginName $selectedPluginName
    }
  }

  exit 0
}

$sourceRoot = Resolve-StrictPath (Join-Path $repoRoot "plugins\$PluginName")
$plugin = @($marketplace.plugins) | Where-Object { $_.name -eq $PluginName } | Select-Object -First 1
if (-not $plugin) {
  throw "Plugin '$PluginName' was not found in $marketplaceFile."
}
if ($plugin.source.source -ne "local") {
  throw "Plugin '$PluginName' is not a local marketplace plugin."
}

$configuredSourceRoot = Resolve-ConfiguredSourcePath ([string]$plugin.source.path) $marketplaceFile $repoRoot
if (-not ([System.IO.Path]::GetFullPath($configuredSourceRoot).TrimEnd("\", "/").Equals($sourceRoot.TrimEnd("\", "/"), [System.StringComparison]::OrdinalIgnoreCase))) {
  throw "Plugin '$PluginName' marketplace path resolves to $configuredSourceRoot, not this checkout source $sourceRoot."
}

$manifestPath = Join-Path $sourceRoot ".codex-plugin/plugin.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Missing plugin manifest at $manifestPath."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.name -ne $PluginName) {
  throw "Plugin manifest name '$($manifest.name)' does not match requested plugin '$PluginName'."
}
$manifestVersion = [string]$manifest.version
Assert-SafeVersionSegment $manifestVersion

$codexHomePath = [System.IO.Path]::GetFullPath($CodexHome)
$pluginsRoot = Join-And-Normalize $codexHomePath @("plugins")
$cacheRoot = Join-And-Normalize $codexHomePath @("plugins", "cache")
$marketplaceCacheRoot = Join-And-Normalize $cacheRoot @($marketplaceName)
$pluginCacheRoot = Join-And-Normalize $cacheRoot @($marketplaceName, $PluginName)
Assert-PathInside $pluginCacheRoot $cacheRoot "Resolved plugin cache path is outside Codex plugin cache"
Assert-ExistingCachePathNotReparsePoint @($codexHomePath, $pluginsRoot, $cacheRoot, $marketplaceCacheRoot, $pluginCacheRoot)

$localTargetRoot = Join-And-Normalize $pluginCacheRoot @("local")
$versionTargetRoot = Join-And-Normalize $pluginCacheRoot @($manifestVersion)

New-Item -ItemType Directory -Path $pluginCacheRoot -Force | Out-Null

Copy-PluginCacheTarget $localTargetRoot $sourceRoot $repoRoot
Copy-PluginCacheTarget $versionTargetRoot $sourceRoot $repoRoot

if ($ValidateInstalledCache) {
  Invoke-InstalledCacheValidation $localTargetRoot "local" $manifestVersion
  Invoke-InstalledCacheValidation $versionTargetRoot $manifestVersion $manifestVersion
}

Write-Host "Refreshed local Codex plugin cache:"
Write-Host "  source: $sourceRoot"
Write-Host "  local target: $localTargetRoot"
Write-Host "  version target: $versionTargetRoot"
Write-Host ""
Write-Host "Restart or reload Codex to pick up refreshed plugin skills and MCP servers."
