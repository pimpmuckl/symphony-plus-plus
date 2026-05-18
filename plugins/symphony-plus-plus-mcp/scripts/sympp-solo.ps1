param(
  [switch]$Help,
  [switch]$ValidateOnly,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$SoloArgs
)

$ErrorActionPreference = "Stop"

function Write-Usage {
  Write-Host "Runs the Symphony++ Solo Session CLI from any current repository."
  Write-Host ""
  Write-Host "Usage:"
  Write-Host "  pwsh plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1 -Help"
  Write-Host "  pwsh plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1 -ValidateOnly"
  Write-Host "  pwsh plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1 attach --repo <repo> --base-branch <branch> --workspace-path <abs-path> --caller-id <id> [--database <sqlite-path>]"
  Write-Host ""
  Write-Host "Environment:"
  Write-Host "  SYMPP_REPO_ROOT   Optional repo checkout root. Required when the plugin runs from installed cache without a source hint."
  Write-Host "  SYMPP_DATABASE    Optional SQLite ledger path passed to mix sympp.solo when --database is not already present. Relative paths resolve against the caller workspace. When omitted, mix sympp.solo uses the shared local Symphony++ default ledger."
  Write-Host "  SYMPP_LAUNCHER    Optional launcher: 'direct' or 'mise'. Defaults to 'direct'."
  Write-Host "  SYMPP_MIX         Optional mix executable path or name for direct launcher. Defaults to 'mix'."
  Write-Host "  SYMPP_MISE        Optional mise executable path or name for mise launcher. Defaults to 'mise'."
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

  throw "Cannot infer the Symphony++ checkout. Run scripts/refresh-local-plugin.ps1 from the repo or set SYMPP_REPO_ROOT to the repository root before running the Solo Session wrapper."
}

function Resolve-CallerWorkspace {
  $cwd = [System.IO.Path]::GetFullPath((Get-Location).Path)
  $git = Get-Command "git" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $gitRoot = (& git -C $cwd rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitRoot)) {
      return [System.IO.Path]::GetFullPath(([string]$gitRoot).Trim())
    }
  }

  return $cwd
}

function Test-IsWindowsAbsolutePath([string]$Path) {
  return $Path -match "^[A-Za-z]:[\\/]"
}

function Test-IsUriLikeDatabase([string]$Path) {
  return $Path -match "^[A-Za-z][A-Za-z0-9+.-]*:" -and -not (Test-IsWindowsAbsolutePath $Path)
}

function Resolve-DatabasePath([string]$Path, [string]$CallerWorkspace) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith(":") -or (Test-IsUriLikeDatabase $Path)) {
    return $Path
  }

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $CallerWorkspace $Path))
}

function Resolve-DatabaseArgs([string[]]$InputArgs, [string]$CallerWorkspace) {
  $resolved = @()
  for ($index = 0; $index -lt $InputArgs.Count; $index++) {
    $arg = $InputArgs[$index]
    if ($arg -eq "--database" -and ($index + 1) -lt $InputArgs.Count) {
      $resolved += $arg
      $resolved += Resolve-DatabasePath $InputArgs[$index + 1] $CallerWorkspace
      $index += 1
    } elseif ($arg.StartsWith("--database=")) {
      $value = $arg.Substring("--database=".Length)
      $resolved += "--database=$(Resolve-DatabasePath $value $CallerWorkspace)"
    } else {
      $resolved += $arg
    }
  }

  return $resolved
}

function Test-IsMiseShim([string]$Path) {
  $normalized = $Path.Replace("\", "/").ToLowerInvariant()
  return ($normalized -match "/mise/" -or $normalized -match "/\.mise/") -and $normalized -match "/shims?/"
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

function Test-HasDatabaseArg([string[]]$InputArgs) {
  foreach ($arg in $InputArgs) {
    if ($arg -eq "--database" -or $arg.StartsWith("--database=")) {
      return $true
    }
  }

  return $false
}

if ($Help) {
  Write-Usage
  exit 0
}

$repoRoot = Resolve-RepoRoot
$callerWorkspace = Resolve-CallerWorkspace
$resolvedSoloArgs = Resolve-DatabaseArgs -InputArgs $SoloArgs -CallerWorkspace $callerWorkspace
$elixirDir = Join-Path $repoRoot "elixir"
$soloTaskPath = Join-Path $elixirDir "lib/mix/tasks/sympp.solo.ex"
$launcher = if ([string]::IsNullOrWhiteSpace($env:SYMPP_LAUNCHER)) { "direct" } else { $env:SYMPP_LAUNCHER.Trim().ToLowerInvariant() }
$mix = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MIX)) { "mix" } else { $env:SYMPP_MIX }
$mise = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MISE)) { "mise" } else { $env:SYMPP_MISE }

$script:FinalExitCode = 0

Push-Location -LiteralPath $elixirDir
try {
  Assert-LauncherAvailable

  if ($ValidateOnly) {
    if (-not (Test-Path -LiteralPath $soloTaskPath)) {
      throw "Resolved Symphony++ checkout is missing the Solo Session Mix task: $soloTaskPath"
    }

    $validationExitCode = Test-LauncherVersion
    if ($validationExitCode -ne 0) {
      throw "Selected Symphony++ Solo Session launcher failed validation with exit code $validationExitCode."
    }

    Write-Host "Symphony++ Solo Session wrapper validation passed."
    Write-Host "  repoRoot: $repoRoot"
    Write-Host "  elixirDir: $elixirDir"
    Write-Host "  launcher: $launcher"
    $script:FinalExitCode = 0
  } else {
    $soloCommandArgs = @("sympp.solo") + $resolvedSoloArgs
    if (-not (Test-HasDatabaseArg -InputArgs $resolvedSoloArgs)) {
      if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
        $soloCommandArgs += @("--database", (Resolve-DatabasePath $env:SYMPP_DATABASE $callerWorkspace))
      }
    }
    Invoke-Launcher -LauncherArgs $soloCommandArgs
    $script:FinalExitCode = $script:LauncherExitCode
  }
} finally {
  Pop-Location
}

exit $script:FinalExitCode
