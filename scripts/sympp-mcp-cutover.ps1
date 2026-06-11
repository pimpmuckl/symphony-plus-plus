[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
  [string]$CodexHome = $(if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME ".codex" } else { $env:CODEX_HOME }),
  [string]$SymppHome = $(if ([string]::IsNullOrWhiteSpace($env:SYMPP_HOME)) { Join-Path $HOME ".agents\splusplus" } else { $env:SYMPP_HOME }),
  [string]$MarketplaceName = "symphony-plus-plus",
  [string]$McpPluginName = "symphony-plus-plus-mcp",
  [string]$ExpectedSourceRevision,
  [int]$BackendPort = 19998,
  [int]$DashboardPort = 19999,
  [switch]$SkipMarketplaceUpgrade,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$script:SymppCutoverDryRun = [bool]$WhatIfPreference
if ($script:SymppCutoverDryRun) {
  $WhatIfPreference = $false
}

function Write-Section([string]$Title) {
  if (-not $Json) {
    Write-Host ""
    Write-Host "== $Title =="
  }
}

function ConvertTo-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Require-Directory([string]$Path, [string]$Label) {
  $fullPath = ConvertTo-FullPath $Path
  if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
    throw "$Label does not exist: $fullPath"
  }

  return $fullPath
}

function Require-File([string]$Path, [string]$Label) {
  $fullPath = ConvertTo-FullPath $Path
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "$Label does not exist: $fullPath"
  }

  return $fullPath
}

function Invoke-CapturedCommand([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = $null) {
  $previousLocation = $null
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $previousLocation = Get-Location
    Set-Location -LiteralPath $WorkingDirectory
  }

  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($previousLocation) {
      Set-Location -LiteralPath $previousLocation
    }
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Stdout = (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String)
    Stderr = (($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Out-String)
  }
}

function Invoke-CheckedCommand([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = $null, [string]$Label = $FilePath) {
  $result = Invoke-CapturedCommand $FilePath $Arguments $WorkingDirectory
  if ($result.ExitCode -ne 0) {
    $message = "$Label failed with exit code $($result.ExitCode)."
    if (-not [string]::IsNullOrWhiteSpace($result.Stdout)) {
      $message += "`nSTDOUT:`n$($result.Stdout)"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) {
      $message += "`nSTDERR:`n$($result.Stderr)"
    }
    throw $message
  }

  return $result
}

function Get-GitRevision([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    throw "git was not found on PATH."
  }

  $result = Invoke-CheckedCommand $git.Source @("-C", $RepoRoot, "rev-parse", "--verify", "HEAD") $RepoRoot "git rev-parse"
  $revision = ($result.Stdout -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim().ToLowerInvariant()
  if ($revision -notmatch "^[0-9a-f]{40}$") {
    throw "git returned an invalid source revision for $RepoRoot`: $revision"
  }

  return $revision
}

function Get-RevisionFromTextFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $content = (Get-Content -LiteralPath $Path -Raw).Trim().ToLowerInvariant()
  if ($content -match "^[0-9a-f]{40}$") {
    return $content
  }

  return $null
}

function Get-RevisionFromInstallMetadata([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $metadata = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  foreach ($propertyName in @("source_revision", "sourceRevision", "revision", "commit", "head")) {
    $property = $metadata.PSObject.Properties[$propertyName]
    if ($property -and $property.Value) {
      $value = ([string]$property.Value).Trim().ToLowerInvariant()
      if ($value -match "^[0-9a-f]{40}$") {
        return $value
      }
    }
  }

  return $null
}

function Resolve-InstalledSourceRevision([string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot) {
  try {
    return Get-GitRevision $MarketplaceSourceRoot
  } catch {
    # Installed marketplace caches may be packaged without .git. Match the
    # launcher contract and fall back to pinned non-secret revision markers.
  }

  foreach ($candidate in @(
      (Join-Path $MarketplaceSourceRoot ".codex-marketplace-install.json"),
      (Join-Path $MarketplaceSourceRoot ".sympp-source-revision"),
      (Join-Path $InstalledPluginRoot ".sympp-source-revision")
    )) {
    $revision = if ($candidate.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
      Get-RevisionFromInstallMetadata $candidate
    } else {
      Get-RevisionFromTextFile $candidate
    }
    if (-not [string]::IsNullOrWhiteSpace($revision)) {
      return $revision
    }
  }

  throw "Could not resolve the installed Symphony++ source revision from git, .codex-marketplace-install.json, or .sympp-source-revision."
}

function Normalize-ExpectedSourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -notmatch "^[0-9a-f]{40}$") {
    throw "ExpectedSourceRevision must be a 40-character git SHA."
  }

  return $normalized
}

function Invoke-MarketplaceUpgrade([string]$CodexHomePath) {
  $codex = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $codex) {
    throw "codex was not found on PATH; pass -SkipMarketplaceUpgrade only when the installed marketplace/cache is already refreshed."
  }

  $previousCodexHome = $env:CODEX_HOME
  try {
    $env:CODEX_HOME = $CodexHomePath
    return Invoke-CheckedCommand $codex.Source @("plugin", "marketplace", "upgrade") $HOME "codex plugin marketplace upgrade"
  } finally {
    $env:CODEX_HOME = $previousCodexHome
  }
}

function Resolve-InstalledMcpPluginRoot([string]$CacheRoot) {
  $pluginRoot = Join-Path $CacheRoot $McpPluginName
  $pluginRoot = Require-Directory $pluginRoot "Installed MCP plugin cache"
  $candidates = @(
    Get-ChildItem -LiteralPath $pluginRoot -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "scripts\start-sympp-mcp.cmd") }
  )
  if ($candidates.Count -eq 0) {
    throw "No installed $McpPluginName cache entry with scripts/start-sympp-mcp.cmd was found under $pluginRoot."
  }

  $sortable = @(
    foreach ($candidate in $candidates) {
      $version = $null
      $parsed = [version]::new(0, 0)
      if ([version]::TryParse($candidate.Name, [ref]$version)) {
        $parsed = $version
      }
      [pscustomobject]@{
        Path = $candidate.FullName
        Version = $parsed
        LastWriteTimeUtc = $candidate.LastWriteTimeUtc
      }
    }
  )

  return ($sortable | Sort-Object Version, LastWriteTimeUtc | Select-Object -Last 1).Path
}

function Get-ProcessCommandLines {
  return @(
    Get-CimInstance Win32_Process |
      Where-Object { $_.ProcessId -ne $PID } |
      ForEach-Object {
        [pscustomobject]@{
          ProcessId = [int]$_.ProcessId
          ParentProcessId = [int]$_.ParentProcessId
          Name = [string]$_.Name
          CommandLine = [string]$_.CommandLine
        }
      }
  )
}

function Get-ListeningPorts([int[]]$Ports) {
  return @(
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $Ports -contains $_.LocalPort } |
      Sort-Object LocalPort |
      ForEach-Object {
        [pscustomobject]@{
          LocalAddress = [string]$_.LocalAddress
          LocalPort = [int]$_.LocalPort
          OwningProcess = [int]$_.OwningProcess
        }
      }
  )
}

function Test-CommandLineContainsPath([string]$CommandLine, [string]$Path) {
  if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  $normalizedCommand = $CommandLine.Replace("/", "\")
  $normalizedPath = (ConvertTo-FullPath $Path).TrimEnd("\").Replace("/", "\")
  return $normalizedCommand.IndexOf($normalizedPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-SymppProcessKind($Process, [string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot) {
  $commandLine = [string]$Process.CommandLine
  $name = [string]$Process.Name

  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    return $null
  }

  if ((Test-CommandLineContainsPath $commandLine $InstalledPluginRoot) -and $commandLine -match "start-sympp-mcp") {
    return "installed_launcher"
  }

  if ($commandLine -match "start-sympp-mcp\.(cmd|ps1)") {
    return "launcher_bridge"
  }

  if ($commandLine -match "\bsympp\.(cockpit|mcp)\b") {
    return "elixir_runtime"
  }

  $assetsRoot = Join-Path $MarketplaceSourceRoot "elixir\assets"
  if ((Test-CommandLineContainsPath $commandLine $assetsRoot) -and $commandLine -match "(vite|node_modules)") {
    return "dashboard_vite"
  }

  if ((Test-CommandLineContainsPath $commandLine $MarketplaceSourceRoot) -and $commandLine -match "\b(mix|mise|erl|elixir)\b.*\bsympp\.(cockpit|mcp)\b") {
    return "marketplace_elixir_runtime"
  }

  if (($name -in @("cmd.exe", "pwsh.exe", "powershell.exe", "mise.exe", "erl.exe", "node.exe")) -and
      (Test-CommandLineContainsPath $commandLine $MarketplaceSourceRoot) -and
      ($commandLine -match "(sympp|vite|start-sympp-mcp)")) {
    return "marketplace_runtime_wrapper"
  }

  return $null
}

function Get-CandidateProcesses([string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot, [int[]]$Ports) {
  $processes = Get-ProcessCommandLines
  $listeners = Get-ListeningPorts $Ports
  $processByPid = @{}
  foreach ($process in $processes) {
    $processByPid[$process.ProcessId] = $process
  }

  $listenerByPid = @{}
  foreach ($listener in $listeners) {
    if (-not $listenerByPid.ContainsKey($listener.OwningProcess)) {
      $listenerByPid[$listener.OwningProcess] = [System.Collections.Generic.List[int]]::new()
    }
    [void]$listenerByPid[$listener.OwningProcess].Add($listener.LocalPort)
  }

  $safeProcessByPid = @{}
  $nonSymppListeners = @()
  foreach ($process in $processes) {
    $kind = Get-SymppProcessKind $process $MarketplaceSourceRoot $InstalledPluginRoot
    if ($kind) {
      $safeProcessByPid[$process.ProcessId] = [pscustomobject]@{
        Process = $process
        Kind = $kind
      }
    }
  }

  $candidatePidSet = [System.Collections.Generic.HashSet[int]]::new()
  foreach ($listener in $listeners) {
    if (-not $safeProcessByPid.ContainsKey($listener.OwningProcess)) {
      $process = $processByPid[$listener.OwningProcess]
      $nonSymppListeners += [pscustomobject]@{
        ProcessId = $listener.OwningProcess
        ParentProcessId = if ($process) { $process.ParentProcessId } else { $null }
        Name = if ($process) { $process.Name } else { $null }
        ListeningPorts = "$($listener.LocalPort)"
      }
      continue
    }

    $currentPid = $listener.OwningProcess
    while ($safeProcessByPid.ContainsKey($currentPid)) {
      [void]$candidatePidSet.Add($currentPid)
      $parentPid = $safeProcessByPid[$currentPid].Process.ParentProcessId
      if ($parentPid -eq $currentPid -or -not $safeProcessByPid.ContainsKey($parentPid)) {
        break
      }
      $currentPid = $parentPid
    }
  }

  $candidates = @(
    foreach ($candidateProcessId in $candidatePidSet) {
      $safe = $safeProcessByPid[$candidateProcessId]
      $listeningPorts = @()
      if ($listenerByPid.ContainsKey($candidateProcessId)) {
        $listeningPorts = @($listenerByPid[$candidateProcessId] | Sort-Object -Unique)
      }

      [pscustomobject]@{
        ProcessId = $safe.Process.ProcessId
        ParentProcessId = $safe.Process.ParentProcessId
        Name = $safe.Process.Name
        Kind = $safe.Kind
        ListeningPorts = ($listeningPorts -join ",")
        CommandLine = $safe.Process.CommandLine
      }
    }
  )

  return [pscustomobject]@{
    Candidates = @($candidates | Sort-Object ProcessId)
    NonSymppListeners = @($nonSymppListeners | Sort-Object ProcessId)
    Listeners = $listeners
  }
}

function Write-ProcessTable([object[]]$Rows, [string]$EmptyMessage) {
  if ($Rows.Count -eq 0) {
    Write-Host $EmptyMessage
    return
  }

  $Rows |
    Select-Object ProcessId, ParentProcessId, Name, Kind, ListeningPorts, CommandLine |
    Format-Table -AutoSize -Wrap
}

function Stop-CandidateProcesses([object[]]$Candidates) {
  $stopped = @()
  $stillRunning = @()

  foreach ($candidate in @($Candidates | Sort-Object ProcessId -Descending)) {
    $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
    if (-not $process) {
      continue
    }

    if ($PSCmdlet.ShouldProcess("PID $($candidate.ProcessId) $($candidate.Name) $($candidate.Kind)", "Stop verified Symphony++ runtime process")) {
      Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
      $stopped += $candidate
    }
  }

  Start-Sleep -Seconds 2

  foreach ($candidate in $Candidates) {
    $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
    if ($process) {
      $stillRunning += $candidate
    }
  }

  return [pscustomobject]@{
    Stopped = @($stopped | Sort-Object ProcessId)
    StillRunning = @($stillRunning | Sort-Object ProcessId)
  }
}

function Get-ProcessByPidFromInventory([int]$ProcessId) {
  return Get-ProcessCommandLines | Where-Object { $_.ProcessId -eq $ProcessId } | Select-Object -First 1
}

function Assert-RequiredPortsAvailable([int[]]$Ports) {
  $listeners = @(Get-ListeningPorts $Ports)
  if ($listeners.Count -eq 0) {
    return
  }

  $details = @(
    foreach ($listener in $listeners) {
      $process = Get-ProcessByPidFromInventory $listener.OwningProcess
      if ($process) {
        "port $($listener.LocalPort) pid $($listener.OwningProcess) $($process.Name)"
      } else {
        "port $($listener.LocalPort) pid $($listener.OwningProcess)"
      }
    }
  ) -join "; "

  throw "Required singleton ports are still occupied after stopping verified S++ candidates: $details"
}

function Wait-ListeningPort([int]$Port, [int]$TimeoutSeconds) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listener) {
      return [int]$listener.OwningProcess
    }
    Start-Sleep -Milliseconds 500
  } while ([DateTimeOffset]::UtcNow -lt $deadline)

  throw "Timed out waiting for port $Port to listen."
}

function Assert-ListenerKind([int]$ProcessId, [string[]]$ExpectedKinds, [string]$Label, [string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot) {
  $process = Get-ProcessByPidFromInventory $ProcessId
  if (-not $process) {
    throw "$Label listener PID $ProcessId was not found in the process table."
  }

  $kind = Get-SymppProcessKind $process $MarketplaceSourceRoot $InstalledPluginRoot
  if ($ExpectedKinds -notcontains $kind) {
    throw "$Label listener PID $ProcessId ($($process.Name)) did not match the expected S++ runtime kind. Expected $($ExpectedKinds -join ', '), got '$kind'."
  }
}

function Invoke-ElixirSetup([string]$MarketplaceSourceRoot) {
  $elixirDir = Require-Directory (Join-Path $MarketplaceSourceRoot "elixir") "Marketplace Elixir directory"
  $mise = Get-Command mise -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $mise) {
    throw "mise was not found on PATH; cannot prepare the installed marketplace Elixir runtime."
  }

  Invoke-CheckedCommand $mise.Source @("exec", "--", "mix", "deps.get", "--check-locked") $elixirDir "mix deps.get --check-locked" | Out-Null
  Invoke-CheckedCommand $mise.Source @("exec", "--", "mix", "compile") $elixirDir "mix compile" | Out-Null
}

function Start-Backend([string]$MarketplaceSourceRoot, [string]$SourceRevision, [int]$BackendPort, [int]$DashboardPort, [string]$LogDir) {
  $elixirDir = Require-Directory (Join-Path $MarketplaceSourceRoot "elixir") "Marketplace Elixir directory"
  $mise = Get-Command mise -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $mise) {
    throw "mise was not found on PATH; cannot start mix sympp.cockpit from the installed marketplace cache."
  }

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdout = Join-Path $LogDir "cutover-backend-$BackendPort-$stamp.out.log"
  $stderr = Join-Path $LogDir "cutover-backend-$BackendPort-$stamp.err.log"

  $previousSourceRevision = $env:SYMPP_SOURCE_REVISION
  try {
    $env:SYMPP_SOURCE_REVISION = $SourceRevision
    $process = Start-Process -FilePath $mise.Source `
      -ArgumentList @("exec", "--", "mix", "sympp.cockpit", "--host", "127.0.0.1", "--port", "$BackendPort", "--dashboard-origin", "http://127.0.0.1:$DashboardPort") `
      -WorkingDirectory $elixirDir `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -WindowStyle Hidden `
      -PassThru
  } finally {
    $env:SYMPP_SOURCE_REVISION = $previousSourceRevision
  }

  return [pscustomobject]@{
    ProcessId = $process.Id
    StdoutLog = $stdout
    StderrLog = $stderr
  }
}

function Ensure-NodeModules([string]$AssetsDir) {
  $vite = Join-Path $AssetsDir "node_modules\.bin\vite.cmd"
  if (Test-Path -LiteralPath $vite -PathType Leaf) {
    return $vite
  }

  $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $npm) {
    throw "Vite launcher was missing and npm was not found on PATH: $vite"
  }

  $result = Invoke-CheckedCommand $npm.Source @("install") $AssetsDir "npm install"
  return Require-File $vite "Vite launcher after npm install"
}

function Start-Dashboard([string]$MarketplaceSourceRoot, [int]$BackendPort, [int]$DashboardPort, [string]$LogDir) {
  $assetsDir = Require-Directory (Join-Path $MarketplaceSourceRoot "elixir\assets") "Marketplace dashboard assets directory"
  $vite = Ensure-NodeModules $assetsDir

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdout = Join-Path $LogDir "cutover-dashboard-$DashboardPort-$stamp.out.log"
  $stderr = Join-Path $LogDir "cutover-dashboard-$DashboardPort-$stamp.err.log"
  $command = "`"$vite`" --host 127.0.0.1 --port $DashboardPort --strictPort"

  $previousApiOrigin = $env:SYMPP_API_ORIGIN
  try {
    $env:SYMPP_API_ORIGIN = "http://127.0.0.1:$BackendPort"
    $process = Start-Process -FilePath "cmd.exe" `
      -ArgumentList @("/c", $command) `
      -WorkingDirectory $assetsDir `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -WindowStyle Hidden `
      -PassThru
  } finally {
    $env:SYMPP_API_ORIGIN = $previousApiOrigin
  }

  return [pscustomobject]@{
    ProcessId = $process.Id
    StdoutLog = $stdout
    StderrLog = $stderr
  }
}

function Invoke-InstalledWrapperInitialize([string]$InstalledPluginRoot, [string]$SymppHomePath, [string]$RuntimeFilePath) {
  $script = Require-File (Join-Path $InstalledPluginRoot "scripts\start-sympp-mcp.ps1") "Installed MCP launcher script"
  $powershell = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $powershell) {
    $powershell = Get-Command powershell -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if (-not $powershell) {
    throw "Neither pwsh nor powershell was found on PATH."
  }

  $request = @{
    jsonrpc = "2.0"
    id = "sympp-cutover-init"
    method = "initialize"
    params = @{
      protocolVersion = "2025-03-26"
      capabilities = @{}
      clientInfo = @{
        name = "sympp-mcp-cutover"
        version = "0.1.0"
      }
    }
  } | ConvertTo-Json -Depth 12 -Compress

  $previousErrorActionPreference = $ErrorActionPreference
  $previousSymppHome = $env:SYMPP_HOME
  $previousRuntimeFile = $env:SYMPP_RUNTIME_FILE
  try {
    $ErrorActionPreference = "Continue"
    $env:SYMPP_HOME = $SymppHomePath
    $env:SYMPP_RUNTIME_FILE = $RuntimeFilePath
    $output = @($request | & $powershell.Source -NoProfile -ExecutionPolicy Bypass -File $script 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    $env:SYMPP_HOME = $previousSymppHome
    $env:SYMPP_RUNTIME_FILE = $previousRuntimeFile
  }
  $stdout = (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String)
  $stderr = (($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Out-String)

  if ($exitCode -ne 0) {
    throw "Installed MCP wrapper initialize failed with exit code $($exitCode).`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
  }

  return [pscustomobject]@{
    Stdout = $stdout
    Stderr = $stderr
  }
}

function Update-RuntimeStatePids([string]$RuntimeFile, [int]$BackendPid, [int]$DashboardPid, [string]$SourceRevision, [int]$BackendPort, [int]$DashboardPort) {
  $runtimeFilePath = Require-File $RuntimeFile "Runtime state file"
  $state = Get-Content -LiteralPath $runtimeFilePath -Raw | ConvertFrom-Json
  $state.generated_at = (Get-Date).ToString("o")
  $state.runtime_kind = "external_loopback"
  $state.runtime_key = "source=$SourceRevision;backend=http://127.0.0.1:$BackendPort;dashboard=http://127.0.0.1:$DashboardPort"
  $state.backend.pid = $BackendPid
  $state.backend.port = $BackendPort
  $state.backend.url = "http://127.0.0.1:$BackendPort"
  $state.backend.mcp_url = "http://127.0.0.1:$BackendPort/mcp"
  $state.backend.status = "external_loopback"
  $state.backend.reused = $true
  $state.backend.managed = $false
  $state.backend.expected_source_revision = $SourceRevision
  $state.backend.source_revision = $SourceRevision
  $state.frontend.pid = $DashboardPid
  $state.frontend.port = $DashboardPort
  $state.frontend.origin = "http://127.0.0.1:$DashboardPort"
  $state.frontend.url = "http://127.0.0.1:$DashboardPort/sympp/board"
  $state.frontend.status = "external_loopback"
  $state.frontend.reused = $true
  $state.frontend.managed = $false
  if ($null -eq $state.superseded_runtimes) {
    $state.superseded_runtimes = @()
  }

  $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $runtimeFilePath -Encoding UTF8
  return $state
}

function Invoke-McpSmoke([string]$RepoRoot, [string]$SourceRevision, [int]$BackendPort) {
  $smokeScript = Require-File (Join-Path $PSScriptRoot "smoke-sympp-mcp-http.ps1") "MCP HTTP smoke script"
  $result = Invoke-CheckedCommand "powershell" @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $smokeScript,
    "-Url",
    "http://127.0.0.1:$BackendPort/mcp",
    "-RepoRoot",
    $RepoRoot,
    "-ExpectedSourceRevision",
    $SourceRevision,
    "-Json"
  ) $RepoRoot "smoke-sympp-mcp-http.ps1"

  return $result.Stdout
}

function Invoke-DashboardSmoke([int]$DashboardPort) {
  $url = "http://127.0.0.1:$DashboardPort/sympp/board"
  $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 15
  return [pscustomobject]@{
    Url = $url
    StatusCode = [int]$response.StatusCode
    Length = [int]$response.Content.Length
    HasRoot = ($response.Content -match '<div id="root"')
  }
}

$codexHomePath = Require-Directory $CodexHome "Codex home"
$symppHomePath = ConvertTo-FullPath $SymppHome
$logDir = Join-Path $symppHomePath "logs"
$runtimeFile = Join-Path $symppHomePath "runtime\codex-plugin.json"
$marketplaceSourceRoot = Require-Directory (Join-Path $codexHomePath ".tmp\marketplaces\$MarketplaceName") "Installed marketplace source root"
$cacheRoot = Require-Directory (Join-Path $codexHomePath "plugins\cache\$MarketplaceName") "Installed plugin cache root"
$installedPluginRoot = Resolve-InstalledMcpPluginRoot $cacheRoot
$allPorts = @($BackendPort, $DashboardPort) + @(20000..20120)
$sourceRevision = Normalize-ExpectedSourceRevision $ExpectedSourceRevision
$marketplaceUpgradeAlreadyRun = $false

if (-not $script:SymppCutoverDryRun) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-Section "Installed Symphony++ MCP Cutover"
if (-not $Json) {
  Write-Host "Codex home: $codexHomePath"
  Write-Host "Marketplace source: $marketplaceSourceRoot"
  Write-Host "Installed MCP plugin: $installedPluginRoot"
  Write-Host "Runtime file: $runtimeFile"
}

if (-not $script:SymppCutoverDryRun -and -not $SkipMarketplaceUpgrade -and -not [string]::IsNullOrWhiteSpace($sourceRevision)) {
  $currentMarketplaceRevision = Resolve-InstalledSourceRevision $marketplaceSourceRoot $installedPluginRoot
  if ($currentMarketplaceRevision -ne $sourceRevision) {
    Write-Section "Marketplace Upgrade Preflight"
    $preflightUpgradeFailed = $false
    try {
      if ($PSCmdlet.ShouldProcess("Codex marketplace $MarketplaceName", "Run pre-stop codex plugin marketplace upgrade")) {
        $preflightUpgrade = Invoke-MarketplaceUpgrade $codexHomePath
        $marketplaceUpgradeAlreadyRun = $true
        if (-not $Json -and -not [string]::IsNullOrWhiteSpace($preflightUpgrade.Stdout)) {
          Write-Host $preflightUpgrade.Stdout.Trim()
        }
      }
    } catch {
      $preflightUpgradeFailed = $true
      if (-not $Json) {
        Write-Host "Pre-stop marketplace upgrade failed; will retry after stopping verified S++ processes."
        Write-Host $_.Exception.Message
      }
    }

    $marketplaceSourceRoot = Require-Directory (Join-Path $codexHomePath ".tmp\marketplaces\$MarketplaceName") "Installed marketplace source root"
    $cacheRoot = Require-Directory (Join-Path $codexHomePath "plugins\cache\$MarketplaceName") "Installed plugin cache root"
    $installedPluginRoot = Resolve-InstalledMcpPluginRoot $cacheRoot
    $currentMarketplaceRevision = Resolve-InstalledSourceRevision $marketplaceSourceRoot $installedPluginRoot
    if ($currentMarketplaceRevision -ne $sourceRevision -and -not $preflightUpgradeFailed) {
      throw "Marketplace source revision mismatch before stopping runtime. Expected $sourceRevision but $marketplaceSourceRoot is at $currentMarketplaceRevision."
    }
  }
}

$initialInventory = Get-CandidateProcesses $marketplaceSourceRoot $installedPluginRoot $allPorts
Write-Section "Verified S++ Stop Candidates"
if (-not $Json) {
  Write-ProcessTable $initialInventory.Candidates "No verified S++ launcher/runtime processes are currently running."
  if ($initialInventory.NonSymppListeners.Count -gt 0) {
    Write-Host ""
    Write-Host "Non-S++ listeners on checked ports were not selected for stopping:"
    $initialInventory.NonSymppListeners |
      Select-Object ProcessId, ParentProcessId, Name, ListeningPorts |
      Format-Table -AutoSize -Wrap
  }
}

if ($script:SymppCutoverDryRun) {
  $summary = [pscustomobject]@{
    status = "what_if"
    message = "Dry run completed. No processes were stopped, no cache was upgraded, and no singleton was restarted."
    candidates = $initialInventory.Candidates
    nonSymppListeners = $initialInventory.NonSymppListeners
    marketplaceSourceRoot = $marketplaceSourceRoot
    installedPluginRoot = $installedPluginRoot
    runtimeFile = $runtimeFile
  }
  if ($Json) {
    $summary | ConvertTo-Json -Depth 20
  } else {
    Write-Host ""
    Write-Host $summary.message
  }
  exit 0
}

$stopResult = Stop-CandidateProcesses $initialInventory.Candidates
Write-Section "Stopped PIDs"
if (-not $Json) {
  Write-ProcessTable $stopResult.Stopped "No S++ processes needed to be stopped."
  if ($stopResult.StillRunning.Count -gt 0) {
    Write-Host ""
    Write-Host "S++ processes still running after stop attempt:"
    Write-ProcessTable $stopResult.StillRunning "None."
  }
}

if (-not $SkipMarketplaceUpgrade -and -not $marketplaceUpgradeAlreadyRun) {
  Write-Section "Marketplace Upgrade"
  if ($PSCmdlet.ShouldProcess("Codex marketplace $MarketplaceName", "Run codex plugin marketplace upgrade")) {
    $upgrade = Invoke-MarketplaceUpgrade $codexHomePath
    if (-not $Json -and -not [string]::IsNullOrWhiteSpace($upgrade.Stdout)) {
      Write-Host $upgrade.Stdout.Trim()
    }
  }

  $marketplaceSourceRoot = Require-Directory (Join-Path $codexHomePath ".tmp\marketplaces\$MarketplaceName") "Installed marketplace source root"
  $cacheRoot = Require-Directory (Join-Path $codexHomePath "plugins\cache\$MarketplaceName") "Installed plugin cache root"
  $installedPluginRoot = Resolve-InstalledMcpPluginRoot $cacheRoot
}

$sourceRevision = if ([string]::IsNullOrWhiteSpace($sourceRevision)) {
  Resolve-InstalledSourceRevision $marketplaceSourceRoot $installedPluginRoot
} else {
  $sourceRevision
}

$actualMarketplaceRevision = Resolve-InstalledSourceRevision $marketplaceSourceRoot $installedPluginRoot
if ($actualMarketplaceRevision -ne $sourceRevision) {
  throw "Marketplace source revision mismatch. Expected $sourceRevision but $marketplaceSourceRoot is at $actualMarketplaceRevision."
}

Write-Section "Installed Launcher Validation"
$validateCmd = Require-File (Join-Path $installedPluginRoot "scripts\start-sympp-mcp.cmd") "Installed MCP launcher command"
$validation = Invoke-CheckedCommand "cmd.exe" @("/d", "/s", "/c", "`"$validateCmd`" -ValidateOnly") $HOME "installed start-sympp-mcp.cmd -ValidateOnly"
if (-not $Json) {
  Write-Host $validation.Stdout.Trim()
}

Write-Section "Installed Runtime Setup"
Invoke-ElixirSetup $marketplaceSourceRoot
if (-not $Json) {
  Write-Host "Elixir dependencies and compiled runtime are ready."
}

Write-Section "Start Singleton"
$backendStart = $null
$dashboardStart = $null
Assert-RequiredPortsAvailable @($BackendPort, $DashboardPort)
if ($PSCmdlet.ShouldProcess("127.0.0.1:$BackendPort", "Start Symphony++ backend singleton from installed marketplace cache")) {
  $backendStart = Start-Backend $marketplaceSourceRoot $sourceRevision $BackendPort $DashboardPort $logDir
}
if ($PSCmdlet.ShouldProcess("127.0.0.1:$DashboardPort", "Start Symphony++ dashboard from installed marketplace cache")) {
  $dashboardStart = Start-Dashboard $marketplaceSourceRoot $BackendPort $DashboardPort $logDir
}

$backendPid = Wait-ListeningPort $BackendPort 60
$dashboardPid = Wait-ListeningPort $DashboardPort 60
Assert-ListenerKind $backendPid @("elixir_runtime", "marketplace_elixir_runtime", "marketplace_runtime_wrapper") "Backend" $marketplaceSourceRoot $installedPluginRoot
Assert-ListenerKind $dashboardPid @("dashboard_vite", "marketplace_runtime_wrapper") "Dashboard" $marketplaceSourceRoot $installedPluginRoot

if (-not $Json) {
  Write-Host "Backend listener: PID $backendPid on 127.0.0.1:$BackendPort"
  Write-Host "Dashboard listener: PID $dashboardPid on 127.0.0.1:$DashboardPort"
}

Write-Section "Refresh Runtime State"
$wrapperInit = Invoke-InstalledWrapperInitialize $installedPluginRoot $symppHomePath $runtimeFile
$runtimeState = Update-RuntimeStatePids $runtimeFile $backendPid $dashboardPid $sourceRevision $BackendPort $DashboardPort
if (-not $Json) {
  Write-Host "Runtime key: $($runtimeState.runtime_key)"
  Write-Host "Runtime kind: $($runtimeState.runtime_kind)"
}

Write-Section "Verification"
$finalInventory = Get-CandidateProcesses $marketplaceSourceRoot $installedPluginRoot $allPorts
$dynamicListeners = @(
  $finalInventory.Candidates |
    Where-Object {
      @([string]$_.ListeningPorts -split "," |
        Where-Object {
          $_ -match "^\d+$" -and [int]$_ -ge 20000 -and [int]$_ -le 20120
        }).Count -gt 0
    }
)
if ($dynamicListeners.Count -gt 0) {
  $dynamicSummary = @($dynamicListeners | ForEach-Object { "pid:$($_.ProcessId)/ports:$($_.ListeningPorts)" }) -join ", "
  throw "Unexpected dynamic S++ leak/listener ports remain in 20000-20120: $dynamicSummary"
}

$smokeJson = Invoke-McpSmoke $marketplaceSourceRoot $sourceRevision $BackendPort
$dashboardSmoke = Invoke-DashboardSmoke $DashboardPort
if (-not $dashboardSmoke.HasRoot) {
  throw "Dashboard route returned HTTP $($dashboardSmoke.StatusCode) but did not include the Vite root element."
}

if (-not $Json) {
  Write-Host "Dynamic ports 20000-20120: none"
  Write-Host "MCP smoke: passed"
  Write-Host "Dashboard smoke: HTTP $($dashboardSmoke.StatusCode), length $($dashboardSmoke.Length)"
  Write-Host ""
  Write-Host "Left-running S++ listener PIDs:"
  $finalInventory.Listeners |
    Where-Object { $_.LocalPort -in @($BackendPort, $DashboardPort) } |
    ForEach-Object {
      $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
      [pscustomobject]@{
        Port = $_.LocalPort
        ProcessId = $_.OwningProcess
        ProcessName = if ($process) { $process.ProcessName } else { $null }
        Path = if ($process) { $process.Path } else { $null }
      }
    } |
    Format-Table -AutoSize
}

$summary = [pscustomobject]@{
  status = "ok"
  message = "Installed Symphony++ MCP cutover completed."
  sourceRevision = $sourceRevision
  marketplaceSourceRoot = $marketplaceSourceRoot
  installedPluginRoot = $installedPluginRoot
  runtimeFile = $runtimeFile
  backend = @{
    port = $BackendPort
    pid = $backendPid
    startedProcessId = if ($backendStart) { $backendStart.ProcessId } else { $null }
    stdoutLog = if ($backendStart) { $backendStart.StdoutLog } else { $null }
    stderrLog = if ($backendStart) { $backendStart.StderrLog } else { $null }
  }
  dashboard = @{
    port = $DashboardPort
    pid = $dashboardPid
    startedProcessId = if ($dashboardStart) { $dashboardStart.ProcessId } else { $null }
    stdoutLog = if ($dashboardStart) { $dashboardStart.StdoutLog } else { $null }
    stderrLog = if ($dashboardStart) { $dashboardStart.StderrLog } else { $null }
    route = $dashboardSmoke
  }
  stoppedPids = @($stopResult.Stopped | ForEach-Object { $_.ProcessId })
  stillRunningStoppedCandidates = @($stopResult.StillRunning | ForEach-Object { $_.ProcessId })
  dynamicLeakPorts = @($dynamicListeners)
  mcpSmoke = $smokeJson | ConvertFrom-Json
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 20
} else {
  Write-Host "Cutover complete."
  Write-Host "Stopped PIDs: $(@($summary.stoppedPids) -join ', ')"
  Write-Host "Left running: backend PID $backendPid, dashboard PID $dashboardPid"
}
