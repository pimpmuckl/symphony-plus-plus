$ErrorActionPreference = "Stop"

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
  $artifactRevision = Normalize-SymppSourceRevision ([string](Get-JsonPropertyValue $Artifact @("source_revision", "revision", "git_revision")))
  if (-not $artifactRevision) {
    $artifactRevision = Normalize-SymppSourceRevision $ManifestSourceRevision
  }

  if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $null -ne $artifactRevision
  }

  return $artifactRevision -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactRevision, $ExpectedSourceRevision)
}

function Resolve-SymppArtifactSourceRevision($Artifact, [string]$ManifestSourceRevision) {
  $artifactRevision = Normalize-SymppSourceRevision ([string](Get-JsonPropertyValue $Artifact @("source_revision", "revision", "git_revision")))
  if ($artifactRevision) {
    return $artifactRevision
  }

  return Normalize-SymppSourceRevision $ManifestSourceRevision
}

function Test-SymppArtifactContractMatches($Artifact, [string]$ExpectedContractFingerprint, [string]$ManifestContractFingerprint) {
  $artifactContract = Normalize-McpContractFingerprint ([string](Get-JsonPropertyValue $Artifact @("mcp_contract_fingerprint", "contract_fingerprint")))
  if (-not $artifactContract) {
    $artifactContract = Normalize-McpContractFingerprint $ManifestContractFingerprint
  }

  if (-not $artifactContract) {
    return [string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)
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

  $manifestSourceRevision = Normalize-SymppSourceRevision ([string](Get-JsonPropertyValue $manifest @("source_revision", "revision", "git_revision")))
  $sourceRevision = if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) { Resolve-SymppArtifactSourceRevision $artifact $manifestSourceRevision } else { $ExpectedSourceRevision }
  if ([string]::IsNullOrWhiteSpace($sourceRevision)) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "source_revision_missing"; platform = $platform; manifest_path = $manifest.manifest_path; runtime = $null }
  }

  $sha256 = Normalize-SymppSha256 ([string](Get-JsonPropertyValue $artifact @("sha256", "sha256sum", "digest")))
  if (-not $sha256) {
    throw "artifact_verification_failed: selected Symphony++ runtime artifact does not declare a valid sha256."
  }

  $pluginVersion = Get-SymppPluginVersion $PluginRoot
  $entrypoint = Resolve-SymppArtifactEntrypoint $artifact
  $cacheRoot = Resolve-SymppArtifactCacheRoot $platform $sourceRevision $pluginVersion $sha256
  $extractRoot = Join-Path $cacheRoot "runtime"
  $archivePath = Join-Path $cacheRoot "artifact.zip"

  if ($ValidateOnly) {
    $ready = Test-SymppArtifactCacheReady $extractRoot $entrypoint $sha256
    $archiveReady = $false
    if (-not $ready -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
      try {
        Assert-SymppArtifactArchiveVerified $archivePath $sha256
        $archiveReady = $true
      } catch {
        $archiveReady = $false
      }
    }
    if (-not $ready -and -not $archiveReady) {
      $sourceUri = Resolve-SymppArtifactSourceUri $artifact $manifest.manifest_path
      Assert-SymppArtifactSourceUsable $sourceUri
    }
    return [pscustomobject]@{
      status = $(if ($ready) { "ready" } else { "artifact_selected" })
      detail = $(if ($ready) { "cache_ready" } elseif ($archiveReady) { "archive_cached" } else { "download_required" })
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
      if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $sourceUri = Resolve-SymppArtifactSourceUri $artifact $manifest.manifest_path
        Assert-SymppArtifactSourceUsable $sourceUri
        Write-Diagnostic "artifact_downloading: downloading Symphony++ runtime artifact for $platform."
        Copy-SymppArtifactArchive $sourceUri $archivePath
      }
      try {
        Assert-SymppArtifactArchiveVerified $archivePath $sha256
      } catch {
        $sourceUri = Resolve-SymppArtifactSourceUri $artifact $manifest.manifest_path
        Assert-SymppArtifactSourceUsable $sourceUri
        Write-Diagnostic "artifact_redownloading: cached Symphony++ runtime artifact failed verification; downloading again. detail=$($_.Exception.Message)"
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Copy-SymppArtifactArchive $sourceUri $archivePath
      }
      Assert-SymppArtifactArchiveVerified $archivePath $sha256
      Expand-SymppArtifactArchive $archivePath $extractRoot $entrypoint $sha256 $platform $sourceRevision $pluginVersion $manifest.manifest_path
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
      source_revision = $sourceRevision
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
      if ([string]::IsNullOrWhiteSpace($sourceRevision) -and -not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $sourceRevision = Resolve-SymppSourceRevision $RepoRoot $PluginRoot
        Set-SymppSourceRevisionEnvironment $sourceRevision
      }
    }
  } elseif ($ArtifactProbe.status -eq "artifact_unavailable" -and $SourceFallbackAllowed) {
    Write-Diagnostic "source_fallback_compiling: artifact probe failed under source fallback control. detail=$($ArtifactProbe.detail)"
  } elseif (-not $SourceFallbackAllowed) {
    Write-Diagnostic "$($ArtifactProbe.status): $($ArtifactProbe.detail)"
    Write-Diagnostic "source_fallback_disabled: set SYMPP_SOURCE_FALLBACK=1 or SYMPP_DEVELOPER_MODE=1 to compile from a source checkout."
    throw "source_fallback_disabled: no verified Symphony++ runtime artifact is ready for this installed launcher."
  }

  return [pscustomobject]@{
    artifact_runtime = $artifactRuntime
    runtime_mode = $runtimeMode
    expected_source_revision = $sourceRevision
  }
}
