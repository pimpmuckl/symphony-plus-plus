$ErrorActionPreference = "Stop"

function Test-SnapshotExcludedPathName([string]$Name) {
  return @(".git", ".hg", ".svn", "_build", "deps", "node_modules", ".elixir_ls") -contains $Name
}

function Copy-SnapshotPath([string]$Source, [string]$Target) {
  $item = Get-Item -LiteralPath $Source -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    return
  }

  if (-not $item.PSIsContainer) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
    Copy-Item -LiteralPath $item.FullName -Destination $Target -Force
    return
  }

  if (Test-SnapshotExcludedPathName $item.Name) {
    return
  }

  New-Item -ItemType Directory -Path $Target -Force | Out-Null
  foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
    if (-not (Test-SnapshotExcludedPathName $child.Name)) {
      Copy-SnapshotPath $child.FullName (Join-Path $Target $child.Name)
    }
  }
}

function Get-GitSnapshotRelativePaths([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return @()
  }

  try {
    $tracked = @(& $git.Source @("-C", $RepoRoot, "ls-files", "--", "elixir", "plugins", "scripts") 2>$null)
    if ($LASTEXITCODE -ne 0) {
      return @()
    }

    $untracked = @(& $git.Source @("-C", $RepoRoot, "ls-files", "--others", "--exclude-standard", "--", "elixir", "plugins", "scripts") 2>$null)
    if ($LASTEXITCODE -ne 0) {
      return @()
    }
  } catch {
    return @()
  }

  return @(
    @($tracked) + @($untracked) |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Where-Object {
        $name = [System.IO.Path]::GetFileName(([string]$_).Replace("/", [System.IO.Path]::DirectorySeparatorChar))
        -not (Test-SnapshotExcludedPathName $name)
      } |
      Sort-Object -Unique
  )
}

function Copy-GitSnapshotFiles([string]$RepoRoot, [string]$SnapshotRoot, [string[]]$RelativePaths) {
  foreach ($relativePath in $RelativePaths) {
    $normalizedRelativePath = ([string]$relativePath).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    $source = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $normalizedRelativePath))
    $target = [System.IO.Path]::GetFullPath((Join-Path $SnapshotRoot $normalizedRelativePath))
    if (Test-SnapshotExcludedPathName ([System.IO.Path]::GetFileName($source))) {
      continue
    }

    Assert-PathInside $source $RepoRoot "Git snapshot source path resolves outside repo root"
    Assert-PathInside $target $SnapshotRoot "Git snapshot target path resolves outside marketplace source snapshot"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      continue
    }

    $item = Get-Item -LiteralPath $source -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
      New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
      Copy-Item -LiteralPath $source -Destination $target -Force
    }
  }
}

function Sync-MarketplaceSourceSnapshot([string]$CodexHomePath, [string]$MarketplaceName, [string]$RepoRoot) {
  $marketplacesRoot = Join-And-Normalize $CodexHomePath @(".tmp", "marketplaces")
  $snapshotRoot = Join-And-Normalize $marketplacesRoot @($MarketplaceName)
  Assert-PathInside $snapshotRoot $marketplacesRoot "Resolved marketplace source snapshot is outside Codex marketplace snapshot root"
  Assert-ExistingCachePathNotReparsePoint @($marketplacesRoot, $snapshotRoot)

  if (Test-Path -LiteralPath $snapshotRoot) {
    Assert-NoReparsePointDescendants $snapshotRoot
    Remove-Item -LiteralPath $snapshotRoot -Recurse -Force
  }

  New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
  $gitSnapshotPaths = @(Get-GitSnapshotRelativePaths $RepoRoot)
  if ($gitSnapshotPaths.Count -gt 0) {
    Copy-GitSnapshotFiles $RepoRoot $snapshotRoot $gitSnapshotPaths
  } else {
    foreach ($entry in @("elixir", "plugins", "scripts")) {
      $source = Join-Path $RepoRoot $entry
      if (Test-Path -LiteralPath $source) {
        Copy-SnapshotPath $source (Join-Path $snapshotRoot $entry)
      }
    }
  }

  $installMarker = [ordered]@{
    generated_by = "refresh-local-plugin.ps1"
    source = "developer_checkout"
    revision = Get-RepoHeadRevision $RepoRoot
  }
  Write-JsonFileNoBom (Join-Path $snapshotRoot ".codex-marketplace-install.json") $installMarker
  Write-Host "Refreshed local Codex marketplace source snapshot:"
  Write-Host "  root: $snapshotRoot"
}
