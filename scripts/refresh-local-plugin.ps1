param(
  [string]$MarketplacePath,
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$HOME/.codex" }),
  [string]$PluginName = "symphony-plus-plus"
)

$ErrorActionPreference = "Stop"

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

  $reparsePoint = Get-ChildItem -LiteralPath $Target -Force -Recurse -Attributes ReparsePoint -ErrorAction Stop | Select-Object -First 1
  if ($null -ne $reparsePoint) {
    throw "Refusing to refresh plugin cache directory containing a reparse-point child. Remove the link manually and rerun refresh: $($reparsePoint.FullName)"
  }
}

function Assert-ExistingCachePathNotReparsePoint([string[]]$Paths) {
  foreach ($path in $Paths) {
    Assert-NotReparsePoint $path
  }
}

function Copy-PluginCacheTarget([string]$TargetRoot, [string]$SourceRoot, [string]$RepoRoot, [bool]$PreserveExistingRoot = $false) {
  Assert-SafeCacheTarget $TargetRoot $pluginCacheRoot
  Assert-NotReparsePoint $TargetRoot
  Assert-NoReparsePointDescendants $TargetRoot

  if ((Test-Path -LiteralPath $TargetRoot) -and -not $PreserveExistingRoot) {
    Remove-Item -LiteralPath $TargetRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null

  foreach ($item in @(".codex-plugin", ".mcp.json", "skills", "scripts", "README.md")) {
    $source = Join-Path $SourceRoot $item
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination $TargetRoot -Recurse -Force
    }
  }

  $sourceRootHintPath = Join-Path $TargetRoot ".sympp-source-root"
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($sourceRootHintPath, "$RepoRoot`n", $utf8NoBom)
}

function Test-CacheTargetHasMcpEntry([string]$TargetRoot) {
  $cachedManifestPath = Join-Path $TargetRoot ".codex-plugin/plugin.json"
  $cachedMcpPath = Join-Path $TargetRoot ".mcp.json"
  if (-not (Test-Path -LiteralPath $cachedManifestPath) -or -not (Test-Path -LiteralPath $cachedMcpPath)) {
    return $false
  }

  try {
    $cachedManifest = Get-Content -LiteralPath $cachedManifestPath -Raw | ConvertFrom-Json
    $cachedMcp = Get-Content -LiteralPath $cachedMcpPath -Raw | ConvertFrom-Json
    return $cachedManifest.mcpServers -eq "./.mcp.json" -and $null -ne $cachedMcp.mcpServers.symphony_plus_plus
  } catch {
    return $false
  }
}

function Assert-SafeVersionSegment([string]$Version) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Plugin manifest must include a non-empty version."
  }

  if ($Version.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Version.Contains("/") -or $Version.Contains("\")) {
    throw "Plugin manifest version is not safe for a cache directory name: $Version"
  }
}

$repoRoot = Resolve-StrictPath (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($MarketplacePath)) {
  $MarketplacePath = Join-Path $repoRoot ".agents\plugins\marketplace.json"
}

$sourceRoot = Resolve-StrictPath (Join-Path $repoRoot "plugins\$PluginName")
$marketplaceFile = Resolve-StrictPath $MarketplacePath
$marketplace = Get-Content -LiteralPath $marketplaceFile -Raw | ConvertFrom-Json
$marketplaceName = [string]$marketplace.name
if ([string]::IsNullOrWhiteSpace($marketplaceName)) {
  throw "Marketplace file must include a top-level name."
}

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

foreach ($existing in Get-ChildItem -LiteralPath $pluginCacheRoot -Directory -ErrorAction SilentlyContinue) {
  $existingPath = [System.IO.Path]::GetFullPath($existing.FullName)
  Assert-SafeCacheTarget $existingPath $pluginCacheRoot
  Assert-NotReparsePoint $existingPath

  if ($existing.Name -ne "local" -and $existing.Name -ne $manifestVersion -and -not (Test-CacheTargetHasMcpEntry $existingPath)) {
    Copy-PluginCacheTarget $existingPath $sourceRoot $repoRoot $true
    Write-Host "Repaired stale MCP-incomplete Codex plugin cache: $existingPath"
  }
}

Copy-PluginCacheTarget $localTargetRoot $sourceRoot $repoRoot
Copy-PluginCacheTarget $versionTargetRoot $sourceRoot $repoRoot

Write-Host "Refreshed local Codex plugin cache:"
Write-Host "  source: $sourceRoot"
Write-Host "  local target: $localTargetRoot"
Write-Host "  version target: $versionTargetRoot"
Write-Host ""
Write-Host "Restart or reload Codex to pick up refreshed plugin skills and MCP servers."
