param(
  [switch]$Help,
  [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "sympp-launcher-runtime.ps1")

function Write-Usage {
  Write-Host "Starts the generic Symphony++ MCP stdio server for the Codex plugin."
  Write-Host ""
  Write-Host "Environment:"
  Write-Host "  SYMPP_REPO_ROOT   Optional repo checkout root. Required when the plugin runs from installed cache."
  Write-Host "  SYMPP_DATABASE    Optional SQLite ledger override passed to mix sympp.mcp. When omitted, mix sympp.mcp prefers %USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3 and falls back under temp/relative .agents\splusplus if home is unavailable."
  Write-Host "  SYMPP_LAUNCHER    Optional launcher: 'direct' or 'mise'. Defaults to 'mise' when elixir/mise.toml is present and mise is available; otherwise 'direct'."
  Write-Host "  SYMPP_MIX         Optional mix executable path or name for direct launcher. Defaults to 'mix'."
  Write-Host "  SYMPP_MISE        Optional mise executable path or name for mise launcher. Defaults to 'mise'."
  Write-Host "  MIX_BUILD_ROOT    Optional Mix build-root override. Defaults under %USERPROFILE%\.agents\splusplus\build\mcp for plugin launcher runs."
  Write-Host ""
  Write-Host "The local refresh script writes a non-secret .sympp-source-root hint into the installed cache."
}

function Resolve-OptionalPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-RepoRoot {
  $configuredRoot = Resolve-OptionalPath $env:SYMPP_REPO_ROOT
  if ($configuredRoot) {
    if (Test-Path -LiteralPath (Join-Path $configuredRoot "elixir/mix.exs")) {
      return $configuredRoot
    }

    throw "SYMPP_REPO_ROOT does not look like a Symphony++ checkout with elixir/mix.exs: $configuredRoot"
  }

  $pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
  $sourceRootHintPath = Join-Path $pluginRoot ".sympp-source-root"
  if (Test-Path -LiteralPath $sourceRootHintPath) {
    $hintText = (Get-Content -LiteralPath $sourceRootHintPath -Raw).Trim().TrimStart([char]0xFEFF)
    $hintedRoot = Resolve-OptionalPath $hintText
    if ($hintedRoot -and (Test-Path -LiteralPath (Join-Path $hintedRoot "elixir/mix.exs"))) {
      return $hintedRoot
    }

    throw "Installed plugin source-root hint is invalid. Refresh the plugin cache or set SYMPP_REPO_ROOT."
  }

  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
  if (Test-Path -LiteralPath (Join-Path $sourceCandidate "elixir/mix.exs")) {
    return $sourceCandidate
  }

  throw "Cannot infer the Symphony++ checkout. Run scripts/refresh-local-plugin.ps1 from the repo or set SYMPP_REPO_ROOT to the repository root before starting the plugin MCP server."
}

if ($Help) {
  Write-Usage
  exit 0
}

$repoRoot = Resolve-RepoRoot
$elixirDir = Join-Path $repoRoot "elixir"
$mix = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MIX)) { "mix" } else { $env:SYMPP_MIX }
$mise = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MISE)) { "mise" } else { $env:SYMPP_MISE }
$launcher = if ([string]::IsNullOrWhiteSpace($env:SYMPP_LAUNCHER)) { Resolve-SymppDefaultLauncher $elixirDir $mise } else { $env:SYMPP_LAUNCHER.Trim().ToLowerInvariant() }
$defaultMixBuildRoot = Resolve-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp"
if (-not $ValidateOnly) {
  Set-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp"
}
$mcpArgs = @("sympp.mcp", "--mode", "stdio", "--repo-root", $repoRoot)

if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
  $mcpArgs += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
}

function Invoke-Launcher([string[]]$LauncherArgs) {
  switch ($launcher) {
    "direct" {
      & $mix @LauncherArgs
      $script:LauncherExitCode = $LASTEXITCODE
      return
    }
    "mise" {
      & $mise @("exec", "--", "mix") @LauncherArgs
      $script:LauncherExitCode = $LASTEXITCODE
      return
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Test-IsMiseShim([string]$Path) {
  $normalized = $Path.Replace("\", "/").ToLowerInvariant()
  return ($normalized -match "/mise/" -or $normalized -match "/\\.mise/") -and $normalized -match "/shims?/"
}

function Resolve-MixCommand {
  $command = Get-Command $mix -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw "Could not find mix executable '$mix'. Install Elixir or set SYMPP_MIX."
  }

  $source = if ($command.Source) { [string]$command.Source } else { [string]$command.Path }
  if (Test-IsMiseShim $source) {
    throw "Direct launcher resolved mix to a mise shim: $source. Set SYMPP_MIX to a non-mise Mix executable, or set SYMPP_LAUNCHER=mise after trusting the checkout's mise config."
  }
}

function Test-LauncherVersion {
  switch ($launcher) {
    "direct" {
      & $mix "--version" | Out-Host
      return $LASTEXITCODE
    }
    "mise" {
      & $mise @("exec", "--", "mix", "--version") | Out-Host
      return $LASTEXITCODE
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Assert-LauncherAvailable {
  switch ($launcher) {
    "direct" {
      Resolve-MixCommand
    }
    "mise" {
      if (-not (Get-Command $mise -ErrorAction SilentlyContinue)) {
        throw "Could not find mise executable '$mise'. Install mise or set SYMPP_MISE."
      }
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$launcher'. Use 'direct' or 'mise'."
    }
  }
}

Set-Location -LiteralPath $elixirDir
Assert-LauncherAvailable

if ($ValidateOnly) {
  $validationExitCode = Test-LauncherVersion
  if ($validationExitCode -ne 0) {
    throw "Selected Symphony++ MCP launcher failed validation with exit code $validationExitCode."
  }

  Write-Host "Symphony++ generic MCP wrapper validation passed."
  Write-Host "  repoRoot: $repoRoot"
  Write-Host "  elixirDir: $elixirDir"
  Write-Host "  launcher: $launcher"
  Write-Host "  mixBuildRoot: $defaultMixBuildRoot"
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    Write-Host "  database: $([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE))"
  }
  exit 0
}

Invoke-Launcher -LauncherArgs $mcpArgs
exit $script:LauncherExitCode
