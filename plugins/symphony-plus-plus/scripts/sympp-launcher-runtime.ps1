$ErrorActionPreference = "Stop"

function Resolve-SymppOptionalPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-SymppPluginHome {
  $configured = Resolve-SymppOptionalPath $env:SYMPP_HOME
  if ($configured) {
    return $configured
  }

  if (-not [string]::IsNullOrWhiteSpace($HOME)) {
    return [System.IO.Path]::GetFullPath((Join-Path $HOME ".agents/splusplus"))
  }

  $profileHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  if (-not [string]::IsNullOrWhiteSpace($profileHome)) {
    return [System.IO.Path]::GetFullPath((Join-Path $profileHome ".agents/splusplus"))
  }

  return [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ".agents/splusplus"))
}

function Normalize-SymppSourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{40}$") {
    return $normalized
  }

  return $null
}

function Get-SymppGitHeadRevision([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return $null
  }

  try {
    $output = @(& $git.Source @("-C", $RepoRoot, "rev-parse", "--verify", "HEAD") 2>$null)
    if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
      return Normalize-SymppSourceRevision ([string]$output[0])
    }
  } catch {
  }

  return $null
}

function Get-SymppMarketplaceInstallRevision([string]$RepoRoot) {
  $installPath = Join-Path $RepoRoot ".codex-marketplace-install.json"
  if (-not (Test-Path -LiteralPath $installPath)) {
    return $null
  }

  try {
    $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
    return Normalize-SymppSourceRevision ([string]$install.revision)
  } catch {
    return $null
  }
}

function Resolve-SymppSourceRevision([string]$RepoRoot) {
  $gitRevision = Get-SymppGitHeadRevision $RepoRoot
  if ($gitRevision) {
    return $gitRevision
  }

  return Get-SymppMarketplaceInstallRevision $RepoRoot
}

function Get-SymppStablePathKey([string]$Value) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = $sha256.ComputeHash($bytes)
    return (($hash | Select-Object -First 6 | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $sha256.Dispose()
  }
}

function Resolve-SymppDefaultLauncher([string]$ElixirDir, [string]$MiseCommand) {
  if ((Test-Path -LiteralPath (Join-Path $ElixirDir "mise.toml")) -and (Get-Command $MiseCommand -ErrorAction SilentlyContinue)) {
    return "mise"
  }

  return "direct"
}

function Resolve-SymppDefaultMixBuildRoot([string]$RepoRoot, [string]$Launcher, [string]$Purpose) {
  $sourceKey = Resolve-SymppSourceRevision $RepoRoot
  if (-not $sourceKey) {
    $sourceKey = "unknown"
  }

  $shortSourceKey = $sourceKey.Substring(0, [Math]::Min(12, $sourceKey.Length))
  $pathKey = Get-SymppStablePathKey ([System.IO.Path]::GetFullPath($RepoRoot))
  $launcherKey = $Launcher -replace "[^A-Za-z0-9_.-]", "_"
  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppPluginHome) "build/$Purpose/$launcherKey/$shortSourceKey-$pathKey"))
}

function Set-SymppDefaultMixBuildRoot([string]$RepoRoot, [string]$Launcher, [string]$Purpose) {
  if (-not [string]::IsNullOrWhiteSpace($env:MIX_BUILD_ROOT)) {
    return
  }

  $buildRoot = Resolve-SymppDefaultMixBuildRoot $RepoRoot $Launcher $Purpose
  New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
  $env:MIX_BUILD_ROOT = $buildRoot
  [Environment]::SetEnvironmentVariable("MIX_BUILD_ROOT", $buildRoot, "Process")
}
