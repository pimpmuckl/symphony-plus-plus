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

$codexHomePath = [System.IO.Path]::GetFullPath($CodexHome)
$cacheRoot = Join-And-Normalize $codexHomePath @("plugins", "cache")
$pluginCacheRoot = Join-And-Normalize $cacheRoot @($marketplaceName, $PluginName)
$targetRoot = Join-And-Normalize $pluginCacheRoot @("local")
Assert-PathInside $pluginCacheRoot $cacheRoot "Resolved plugin cache path is outside Codex plugin cache"

if (Test-Path -LiteralPath $targetRoot) {
  Remove-Item -LiteralPath $targetRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

foreach ($item in @(".codex-plugin", "skills", "README.md")) {
  $source = Join-Path $sourceRoot $item
  if (Test-Path -LiteralPath $source) {
    Copy-Item -LiteralPath $source -Destination $targetRoot -Recurse -Force
  }
}

Write-Host "Refreshed local Codex plugin cache:"
Write-Host "  source: $sourceRoot"
Write-Host "  target: $targetRoot"
Write-Host ""
Write-Host "Restart or reload Codex to pick up refreshed plugin skills."
