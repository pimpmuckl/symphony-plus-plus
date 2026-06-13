$ErrorActionPreference = "Stop"

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

    if ($server.url -eq "http://127.0.0.1:19998/mcp") {
      return "ok"
    }

    return "non_default_http_url"
  }
  if ($server.type -ne "stdio") {
    return "invalid_type"
  }
  if ($server.command -ne "cmd.exe") {
    return "unexpected_command"
  }
  if ($server.cwd -ne ".") {
    return "invalid_cwd"
  }

  $args = @($server.args)
  $hasCmdLaunch = @($args | Where-Object { [string]$_ -eq "/c" }).Count -gt 0
  $hasStartScript = @($args | Where-Object { [string]$_ -match "scripts[\\/]start-sympp-mcp\.cmd" }).Count -gt 0
  if (-not $hasCmdLaunch -or -not $hasStartScript) {
    return "invalid_args"
  }

  return "ok"
}

function Test-DiagnosticWindowsPlatform {
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Get-DiagnosticWindowsProcessorArchitecture {
  $arch = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432", "Process")
  if ([string]::IsNullOrWhiteSpace($arch)) {
    $arch = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Process")
  }
  if (-not [string]::IsNullOrWhiteSpace($arch)) {
    return $arch
  }

  try {
    $runtimeArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    if (-not [string]::IsNullOrWhiteSpace($runtimeArch)) {
      return $runtimeArch
    }
  } catch {
  }

  if ([IntPtr]::Size -eq 8) {
    return "AMD64"
  }

  return "x86"
}

function Convert-DiagnosticProcessorArchitectureToTargetArch([string]$Architecture) {
  if ([string]::IsNullOrWhiteSpace($Architecture)) {
    return $null
  }

  switch ($Architecture.Trim().ToLowerInvariant()) {
    "amd64" { return "x86_64" }
    "x64" { return "x86_64" }
    "arm64" { return "aarch64" }
    "aarch64" { return "aarch64" }
    "x86" { return "x86" }
    "ia64" { return "ia64" }
    default { return $null }
  }
}

function Get-DiagnosticRuntimePlatformKey {
  $os = if (Test-DiagnosticWindowsPlatform) {
    "windows"
  } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
    "linux"
  } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
    "macos"
  } else {
    $null
  }

  $architecture = if (Test-DiagnosticWindowsPlatform) {
    Get-DiagnosticWindowsProcessorArchitecture
  } else {
    try {
      [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    } catch {
      $null
    }
  }
  $arch = Convert-DiagnosticProcessorArchitectureToTargetArch $architecture

  if ([string]::IsNullOrWhiteSpace($os) -or [string]::IsNullOrWhiteSpace($arch)) {
    return $null
  }

  return "$os-$arch"
}

function Resolve-DiagnosticPluginHome {
  $configured = Resolve-OptionalFullPath $env:SYMPP_HOME
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path $HOME ".agents/splusplus"))
}

function Get-DiagnosticJsonPropertyValue($Object, [string[]]$Names) {
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

function Test-DiagnosticRuntimeArtifactPlatformMatches($Artifact, [string]$Platform) {
  $artifactPlatform = [string](Get-DiagnosticJsonPropertyValue $Artifact @("platform", "target", "platform_key"))
  if (-not [string]::IsNullOrWhiteSpace($artifactPlatform)) {
    return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactPlatform.Trim(), $Platform)
  }

  $os = [string](Get-DiagnosticJsonPropertyValue $Artifact @("os", "target_os"))
  $arch = [string](Get-DiagnosticJsonPropertyValue $Artifact @("arch", "architecture", "target_arch"))
  if ([string]::IsNullOrWhiteSpace($os) -or [string]::IsNullOrWhiteSpace($arch)) {
    return $false
  }

  $artifactPlatform = "$($os.Trim().ToLowerInvariant())-$($arch.Trim().ToLowerInvariant())"
  return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactPlatform, $Platform)
}

function Normalize-DiagnosticSourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{40}$") {
    return $normalized
  }

  return $null
}

function Normalize-DiagnosticMcpContractFingerprint([string]$Fingerprint) {
  if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
    return $null
  }

  $normalized = $Fingerprint.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{64}$") {
    return $normalized
  }

  return $null
}

function Test-DiagnosticRuntimeArtifactRevisionMatches($Artifact, [string]$ExpectedSourceRevision, [string]$ManifestSourceRevision) {
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $true
  }

  $artifactRevision = Normalize-DiagnosticSourceRevision ([string](Get-DiagnosticJsonPropertyValue $Artifact @("source_revision", "revision", "git_revision")))
  if (-not $artifactRevision) {
    $artifactRevision = Normalize-DiagnosticSourceRevision $ManifestSourceRevision
  }

  return $artifactRevision -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactRevision, $ExpectedSourceRevision)
}

function Test-DiagnosticRuntimeArtifactContractMatches($Artifact, [string]$ExpectedContractFingerprint, [string]$ManifestContractFingerprint) {
  $artifactContract = Normalize-DiagnosticMcpContractFingerprint ([string](Get-DiagnosticJsonPropertyValue $Artifact @("mcp_contract_fingerprint", "contract_fingerprint")))
  if (-not $artifactContract) {
    $artifactContract = Normalize-DiagnosticMcpContractFingerprint $ManifestContractFingerprint
  }

  if (-not $artifactContract) {
    return [string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)
  }

  return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactContract, $ExpectedContractFingerprint)
}

function Assert-DiagnosticRelativeArtifactPath([string]$Path, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label must be present in the Symphony++ runtime artifact manifest."
  }

  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("..")) {
    throw "$Label must be a relative path inside the extracted Symphony++ runtime artifact."
  }
}

function Resolve-DiagnosticRuntimeArtifactEntrypoint($Artifact) {
  $entrypoint = [string](Get-DiagnosticJsonPropertyValue $Artifact @("entrypoint", "backend_entrypoint", "command"))
  if ([string]::IsNullOrWhiteSpace($entrypoint)) {
    if (Test-DiagnosticWindowsPlatform) {
      $entrypoint = "bin/symphony_elixir.bat"
    } else {
      $entrypoint = "bin/symphony_elixir"
    }
  }

  Assert-DiagnosticRelativeArtifactPath $entrypoint "artifact entrypoint"
  return $entrypoint.Replace("\", "/")
}

function Resolve-DiagnosticRuntimeArtifactSourceUri($Artifact, [string]$ManifestPath) {
  $value = [string](Get-DiagnosticJsonPropertyValue $Artifact @("url", "download_url", "uri", "path"))
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "artifact_missing: selected Symphony++ runtime artifact does not declare url, download_url, uri, or path."
  }

  if ([System.Uri]::IsWellFormedUriString($value, [System.UriKind]::Absolute)) {
    return $value
  }

  $manifestDir = Split-Path -Parent $ManifestPath
  return [System.IO.Path]::GetFullPath((Join-Path $manifestDir $value))
}

function Assert-DiagnosticRuntimeArtifactSourceUsable([string]$SourceUri) {
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

function Test-DiagnosticRuntimeArtifactCacheReady([string]$CacheRoot, [string]$Entrypoint, [string]$Sha256) {
  $extractRoot = Join-Path $CacheRoot "runtime"
  $markerPath = Join-Path $extractRoot ".sympp-artifact.json"
  $entrypointPath = Join-Path $extractRoot $Entrypoint
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

function Get-DiagnosticExpectedMcpContractFingerprint([string]$Root) {
  $scriptPath = Join-Path $Root "scripts/start-sympp-mcp.ps1"
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return $null
  }

  $scriptText = Get-Content -LiteralPath $scriptPath -Raw
  $match = [regex]::Match($scriptText, '\$ExpectedMcpContractFingerprint\s*=\s*"([0-9a-fA-F]{64})"')
  if (-not $match.Success) {
    return $null
  }

  return Normalize-DiagnosticMcpContractFingerprint $match.Groups[1].Value
}

function Get-DiagnosticPinnedRevision([string]$Root) {
  $path = Join-Path $Root ".sympp-source-revision"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $null
  }

  $revision = (Get-Content -LiteralPath $path -Raw).Trim().ToLowerInvariant()
  if ($revision -match "^[0-9a-f]{40}$") {
    return $revision
  }

  return $null
}

function Test-DiagnosticEnvEnabled([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $false
  }

  return $value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
}

function Get-DiagnosticGitHeadRevision([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git -or -not (Test-SourceCheckoutRoot $RepoRoot)) {
    return $null
  }

  try {
    $output = @(& $git.Source @("-C", $RepoRoot, "rev-parse", "--verify", "HEAD") 2>$null)
    if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
      return Normalize-DiagnosticSourceRevision ([string]$output[0])
    }
  } catch {
  }

  return $null
}

function Get-DiagnosticMarketplaceInstallRevision([string]$RepoRoot) {
  if (-not (Test-SourceCheckoutRoot $RepoRoot)) {
    return $null
  }

  $installPath = Join-Path $RepoRoot ".codex-marketplace-install.json"
  if (-not (Test-Path -LiteralPath $installPath -PathType Leaf)) {
    return $null
  }

  try {
    $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
    return Normalize-DiagnosticSourceRevision ([string]$install.revision)
  } catch {
    return $null
  }
}

function Resolve-DiagnosticRuntimeArtifactSourceRoot([string]$Root, [string]$SourceHint) {
  $sourceRoot = Get-SourceCheckoutFromPluginRoot $Root
  if ($sourceRoot) {
    return $sourceRoot
  }

  $sourceRoot = Get-MarketplaceSourceRootFromCachePackage ([pscustomobject]@{ root = $Root })
  if ($sourceRoot) {
    return $sourceRoot
  }

  $hintRoot = Resolve-OptionalFullPath $SourceHint
  if (Test-SourceCheckoutRoot $hintRoot) {
    return $hintRoot
  }

  return $null
}

function Test-DiagnosticRuntimeArtifactSourceFallbackAllowed([string]$Root, [string]$SourceRoot) {
  if (Get-SourceCheckoutFromPluginRoot $Root) {
    return $true
  }

  if (Test-SourceCheckoutRoot $SourceRoot) {
    return $true
  }

  return (Test-DiagnosticEnvEnabled "SYMPP_DEVELOPER_MODE") -or
    (Test-DiagnosticEnvEnabled "SYMPP_SOURCE_FALLBACK") -or
    (Test-DiagnosticEnvEnabled "SYMPP_ALLOW_SOURCE_COMPILE")
}

function Resolve-DiagnosticRuntimeArtifactExpectedRevision([string]$Root, [string]$SourceRoot) {
  $pinnedRevision = Get-DiagnosticPinnedRevision $Root
  if ($pinnedRevision) {
    return $pinnedRevision
  }

  $gitRevision = Get-DiagnosticGitHeadRevision $SourceRoot
  if ($gitRevision) {
    return $gitRevision
  }

  return Get-DiagnosticMarketplaceInstallRevision $SourceRoot
}

function Get-DiagnosticRuntimeArtifactStatus([string]$Root, [string]$ExpectedRevision = $null) {
  $manifestPath = @(
    Join-Path $Root ".sympp-runtime-artifacts.json"
    Join-Path $Root "assets/sympp-runtime-artifacts.json"
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

  $platform = Get-DiagnosticRuntimePlatformKey
  if (-not $manifestPath) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "manifest_missing"; platform = $platform; manifest_path = $null }
  }

  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{ status = "artifact_manifest_invalid"; detail = $_.Exception.Message; platform = $platform; manifest_path = $manifestPath }
  }

  $expectedRevision = Normalize-DiagnosticSourceRevision $ExpectedRevision
  $expectedContract = Get-DiagnosticExpectedMcpContractFingerprint $Root
  $manifestRevision = Normalize-DiagnosticSourceRevision ([string](Get-DiagnosticJsonPropertyValue $manifest @("source_revision", "revision", "git_revision")))
  $manifestContract = Normalize-DiagnosticMcpContractFingerprint ([string](Get-DiagnosticJsonPropertyValue $manifest @("mcp_contract_fingerprint", "contract_fingerprint")))
  $artifacts = @(Get-DiagnosticJsonPropertyValue $manifest @("artifacts", "runtime_artifacts"))
  $artifact = @(
    foreach ($candidate in $artifacts) {
      if ((Test-DiagnosticRuntimeArtifactPlatformMatches $candidate $platform) -and
          (Test-DiagnosticRuntimeArtifactRevisionMatches $candidate $expectedRevision $manifestRevision) -and
          (Test-DiagnosticRuntimeArtifactContractMatches $candidate $expectedContract $manifestContract)) {
        $candidate
      }
    }
  ) | Select-Object -First 1

  if ($null -eq $artifact) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "matching_artifact_missing"; platform = $platform; manifest_path = $manifestPath }
  }

  $sha256 = [string](Get-DiagnosticJsonPropertyValue $artifact @("sha256", "sha256sum", "digest"))
  if ([string]::IsNullOrWhiteSpace($sha256) -or $sha256.Trim().ToLowerInvariant() -notmatch "^[0-9a-f]{64}$") {
    return [pscustomobject]@{ status = "artifact_verification_failed"; detail = "sha256_missing_or_invalid"; platform = $platform; manifest_path = $manifestPath }
  }

  $sha256 = $sha256.Trim().ToLowerInvariant()
  try {
    $entrypoint = Resolve-DiagnosticRuntimeArtifactEntrypoint $artifact
  } catch {
    return [pscustomobject]@{ status = "artifact_verification_failed"; detail = $_.Exception.Message; platform = $platform; manifest_path = $manifestPath }
  }

  $revision = $expectedRevision
  $version = [string](Get-DiagnosticJsonPropertyValue (Get-JsonFile (Join-Path $Root ".codex-plugin/plugin.json")) @("version"))
  $revisionKey = if ($revision) {
    $revision.Substring(0, [Math]::Min(12, $revision.Length))
  } elseif (-not [string]::IsNullOrWhiteSpace($version)) {
    $version -replace "[^A-Za-z0-9_.-]", "_"
  } else {
    "unknown"
  }
  $cacheRoot = [System.IO.Path]::GetFullPath((Join-Path (Resolve-DiagnosticPluginHome) "artifacts/mcp/$platform/$revisionKey/$($sha256.Substring(0, 16))"))

  if (Test-DiagnosticRuntimeArtifactCacheReady $cacheRoot $entrypoint $sha256) {
    return [pscustomobject]@{ status = "ready"; detail = "cache_ready"; platform = $platform; manifest_path = $manifestPath; cache_root = $cacheRoot }
  }

  $archivePath = Join-Path $cacheRoot "artifact.zip"
  if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    $actual = Get-FileSha256Hex $archivePath
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $sha256)) {
      return [pscustomobject]@{ status = "artifact_verification_failed"; detail = "cached_archive_sha256_mismatch"; platform = $platform; manifest_path = $manifestPath; cache_root = $cacheRoot }
    }

    return [pscustomobject]@{ status = "artifact_selected"; detail = "archive_cached"; platform = $platform; manifest_path = $manifestPath; cache_root = $cacheRoot }
  }

  try {
    $sourceUri = Resolve-DiagnosticRuntimeArtifactSourceUri $artifact $manifestPath
    Assert-DiagnosticRuntimeArtifactSourceUsable $sourceUri
  } catch {
    return [pscustomobject]@{ status = "artifact_verification_failed"; detail = $_.Exception.Message; platform = $platform; manifest_path = $manifestPath; cache_root = $cacheRoot }
  }

  return [pscustomobject]@{ status = "artifact_selected"; detail = "download_required"; platform = $platform; manifest_path = $manifestPath; cache_root = $cacheRoot }
}
