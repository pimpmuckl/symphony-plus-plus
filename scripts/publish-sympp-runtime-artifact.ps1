[CmdletBinding()]
param(
  [string]$ManifestPath,
  [string]$Channel = "stable",
  [string]$PublishedArtifactUrl = "",
  [string]$PublishedManifestUrl = "",
  [string]$ChannelOutputPath = "artifacts/sympp-runtime-channel.json",
  [switch]$DryRun,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Usage {
  @"
Validates a built Symphony++ runtime artifact manifest before advancing a release channel.

Publishing is intentionally separate from building. Non-dry-run channel output
requires already-published artifact and manifest URLs, so marketplace users
cannot be pointed at a local or unvalidated artifact.

Usage:
  scripts/publish-sympp-runtime-artifact.ps1 -ManifestPath <manifest.json> -PublishedArtifactUrl <url> -PublishedManifestUrl <url> [-Channel stable]
"@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  throw "ManifestPath is required."
}

function Require-Url([string]$Value, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Label is required for release-channel advancement."
  }

  $uri = [Uri]$Value
  if ($uri.Scheme -notin @("https", "http") -or [string]::IsNullOrWhiteSpace($uri.Host)) {
    throw "$Label must be an http(s) URL."
  }
}

function Require-Property($Object, [string]$Name, [string]$Label) {
  if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
    throw "$Label is missing required property '$Name'."
  }

  $Object.$Name
}

function Write-JsonFile([string]$Path, $Value) {
  $json = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

$manifestFullPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Get-Content -LiteralPath $manifestFullPath -Raw | ConvertFrom-Json

if ((Require-Property $manifest "status" "Artifact manifest") -ne "built") {
  throw "Artifact manifest status must be 'built'."
}

$revision = [string](Require-Property $manifest "source_revision" "Artifact manifest")
if ($revision -notmatch '^[0-9a-f]{40}$') {
  throw "Artifact manifest source_revision must be a 40-character SHA."
}

$artifact = Require-Property $manifest "artifact" "Artifact manifest"
$artifactFile = [string](Require-Property $artifact "file" "Artifact manifest artifact")
$expectedSha = ([string](Require-Property $artifact "sha256" "Artifact manifest artifact")).ToLowerInvariant()
if ($expectedSha -notmatch '^[0-9a-f]{64}$') {
  throw "Artifact manifest artifact.sha256 must be a SHA256 hex digest."
}

$artifactPath = Join-Path (Split-Path -Parent $manifestFullPath) $artifactFile
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
  throw "Artifact package referenced by manifest is missing: $artifactPath"
}

$actualSha = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha -ne $expectedSha) {
  throw "Artifact package SHA256 mismatch. Expected $expectedSha, got $actualSha."
}

if ($DryRun) {
  Write-Host "Dry run: validated $manifestFullPath and $artifactPath for channel '$Channel'."
  exit 0
}

Require-Url $PublishedArtifactUrl "PublishedArtifactUrl"
Require-Url $PublishedManifestUrl "PublishedManifestUrl"

$channelDoc = [ordered]@{
  schema_version = 1
  channel = $Channel
  advanced_at = (Get-Date).ToUniversalTime().ToString("o")
  source_revision = $revision
  platform = [string](Require-Property $manifest "platform" "Artifact manifest")
  artifact = [ordered]@{
    url = $PublishedArtifactUrl
    sha256 = $expectedSha
    size_bytes = $artifact.size_bytes
  }
  manifest = [ordered]@{
    url = $PublishedManifestUrl
    sha256 = (Get-FileHash -LiteralPath $manifestFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  launcher_contract = $manifest.launcher_contract
}

$channelPath = if ([System.IO.Path]::IsPathRooted($ChannelOutputPath)) { $ChannelOutputPath } else { Join-Path (Split-Path -Parent $PSScriptRoot) $ChannelOutputPath }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $channelPath) | Out-Null
Write-JsonFile $channelPath $channelDoc
Write-Host "Wrote release channel manifest $channelPath"
