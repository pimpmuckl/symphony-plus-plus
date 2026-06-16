$ErrorActionPreference = "Stop"

function Invoke-ElixirSetupCommand([string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string[]]$MixArgs, [string]$LogPrefix, [string]$LogDir, [int]$TimeoutSec) {
  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $MixArgs

  $launch = Start-LoggedProcess $command.file $command.args $ElixirDir @{} $LogPrefix $LogDir
  $completed = $false
  try {
    $completed = $launch.process.WaitForExit($TimeoutSec * 1000)
    if (-not $completed) {
      throw "Timed out after $TimeoutSec seconds."
    }

    if ($launch.process.ExitCode -ne 0) {
      throw "Exited with code $($launch.process.ExitCode)."
    }

    return $launch
  } catch {
    if (-not $completed) {
      Stop-LoggedProcess $launch
    }

    throw "$LogPrefix failed. detail=$($_.Exception.Message) stdout_log=$($launch.stdout) stderr_log=$($launch.stderr)"
  }
}

function Initialize-ElixirRuntime([string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec) {
  Write-Diagnostic "source_fallback_compiling: ensuring Symphony++ Elixir dependencies are available in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("deps.get", "--check-locked") "elixir-deps" $LogDir $TimeoutSec

  Write-Diagnostic "source_fallback_compiling: compiling Symphony++ Elixir runtime in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("compile") "elixir-compile" $LogDir $TimeoutSec
}

function Resolve-ArtifactWorkflowPath($ArtifactRuntime, [string]$ElixirDir) {
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_WORKFLOW_FILE)) {
    $candidate = [System.IO.Path]::GetFullPath($env:SYMPP_WORKFLOW_FILE)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  if ($null -ne $ArtifactRuntime -and -not [string]::IsNullOrWhiteSpace([string]$ArtifactRuntime.workflow)) {
    $candidate = [System.IO.Path]::GetFullPath([string]$ArtifactRuntime.workflow)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  $artifactWorkflow = Join-Path ([string]$ArtifactRuntime.root) "WORKFLOW.md"
  if (Test-Path -LiteralPath $artifactWorkflow -PathType Leaf) {
    return [System.IO.Path]::GetFullPath($artifactWorkflow)
  }

  if (-not [string]::IsNullOrWhiteSpace($ElixirDir)) {
    $sourceWorkflow = Join-Path $ElixirDir "WORKFLOW.md"
    if (Test-Path -LiteralPath $sourceWorkflow -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($sourceWorkflow)
    }
  }

  throw "artifact_workflow_missing: verified artifact runtime requires a WORKFLOW.md path. Set SYMPP_WORKFLOW_FILE or include WORKFLOW.md in the runtime artifact."
}

function Get-ArtifactRuntimeArgList($ArtifactRuntime) {
  $args = @()
  foreach ($arg in @($ArtifactRuntime.runtime_args)) {
    if ($null -ne $arg -and -not [string]::IsNullOrWhiteSpace([string]$arg)) {
      $args += [string]$arg
    }
  }

  return $args
}

function Test-ArtifactWorkflowAvailable($ArtifactRuntime, [string]$ElixirDir) {
  if ((Get-ArtifactRuntimeArgList $ArtifactRuntime).Count -gt 0) {
    return $true
  }

  $entrypointName = (Split-Path -Leaf ([string]$ArtifactRuntime.entrypoint)).ToLowerInvariant()
  if ($entrypointName -like "*.bat" -or $entrypointName -like "*.cmd") {
    return $true
  }

  if ($null -ne $ArtifactRuntime -and -not [string]::IsNullOrWhiteSpace([string]$ArtifactRuntime.workflow)) {
    return Test-Path -LiteralPath ([string]$ArtifactRuntime.workflow) -PathType Leaf
  }

  try {
    [void](Resolve-ArtifactWorkflowPath $ArtifactRuntime $ElixirDir)
    return $true
  } catch {
    return $false
  }
}

function Expand-ArtifactRuntimeArg([string]$Arg, [string]$Workflow, [string]$RuntimeLogRoot, $Plan, [string]$DashboardOrigin) {
  $expanded = $Arg
  $expanded = $expanded.Replace("{workflow}", $Workflow).Replace("{{workflow}}", $Workflow)
  $expanded = $expanded.Replace("{logs_root}", $RuntimeLogRoot).Replace("{{logs_root}}", $RuntimeLogRoot)
  $expanded = $expanded.Replace("{port}", [string]$Plan.port).Replace("{{port}}", [string]$Plan.port)
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $expanded = $expanded.Replace("{dashboard_origin}", $DashboardOrigin).Replace("{{dashboard_origin}}", $DashboardOrigin)
  }

  return $expanded
}

function Resolve-ArtifactRuntimeArgs($ArtifactRuntime, [string]$Workflow, [string]$RuntimeLogRoot, $Plan, [string]$DashboardOrigin, [string]$EntrypointName) {
  $manifestArgs = Get-ArtifactRuntimeArgList $ArtifactRuntime
  if ($manifestArgs.Count -gt 0) {
    $expandedArgs = @()
    foreach ($arg in $manifestArgs) {
      $expandedArgs += Expand-ArtifactRuntimeArg ([string]$arg) $Workflow $RuntimeLogRoot $Plan $DashboardOrigin
    }

    return $expandedArgs
  }

  if ($entrypointName -like "*.ps1") {
    return @(
      "-IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails",
      "-Workflow", $workflow,
      "-LogsRoot", $runtimeLogRoot,
      "-Port", [string]$Plan.port
    )
  }
  if ($entrypointName -like "*.sh") {
    return @(
      "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
      "--workflow", $workflow,
      "--logs-root", $runtimeLogRoot,
      "--port", [string]$Plan.port
    )
  }
  if ($entrypointName -like "*.bat" -or $entrypointName -like "*.cmd") {
    return @()
  }

  throw "artifact_entrypoint_unsupported: verified artifact runtime entrypoint must be start-runtime.ps1, start-runtime.sh, or a Windows command wrapper."
}

function Get-ArtifactBackendCommand($ArtifactRuntime, $Plan, [string]$DashboardOrigin, [string]$ElixirDir, [string]$LogDir) {
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    throw "artifact_database_unsupported: verified artifact runtime wrapper does not support SYMPP_DATABASE. Use explicit source fallback for custom ledger paths."
  }

  $manifestArgs = Get-ArtifactRuntimeArgList $ArtifactRuntime
  $runtimeLogRoot = Join-Path $LogDir "artifact-runtime"
  $entrypoint = [string]$ArtifactRuntime.entrypoint
  $entrypointName = (Split-Path -Leaf $entrypoint).ToLowerInvariant()
  $workflow = if ($manifestArgs.Count -gt 0 -or $entrypointName -like "*.bat" -or $entrypointName -like "*.cmd") { [string]$ArtifactRuntime.workflow } else { Resolve-ArtifactWorkflowPath $ArtifactRuntime $ElixirDir }
  $environment = @{
    SYMPP_RUNTIME_ARTIFACT = "1"
    SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED = "1"
    SYMPP_LOGS_ROOT = $runtimeLogRoot
    SYMPP_BACKEND_PORT = [string]$Plan.port
  }
  if (-not [string]::IsNullOrWhiteSpace($workflow)) {
    $environment["SYMPP_WORKFLOW_FILE"] = $workflow
  }
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $environment["SYMPP_DASHBOARD_ORIGIN"] = $DashboardOrigin
  }

  $args = Resolve-ArtifactRuntimeArgs $ArtifactRuntime $workflow $runtimeLogRoot $Plan $DashboardOrigin $entrypointName

  return [pscustomobject]@{
    file = $entrypoint
    args = $args
    working_directory = [string]$ArtifactRuntime.root
    environment = $environment
  }
}

function Start-Backend($Plan, [string]$DashboardOrigin, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec, [string]$ExpectedContractFingerprint, $ArtifactRuntime = $null) {
  $args = @("sympp.cockpit", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $args += @("--dashboard-origin", $DashboardOrigin)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $args += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  if ($null -ne $ArtifactRuntime) {
    $command = Get-ArtifactBackendCommand $ArtifactRuntime $Plan $DashboardOrigin $ElixirDir $LogDir
  } else {
    Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
    $sourceCommand = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $args
    $command = [pscustomobject]@{
      file = $sourceCommand.file
      args = $sourceCommand.args
      working_directory = $ElixirDir
      environment = @{}
    }
  }

  $launch = Start-LoggedProcess $command.file $command.args $command.working_directory $command.environment "backend-$($Plan.port)" $LogDir
  $ready = Wait-Until { Test-HealthySymppBackend $Plan.url } $TimeoutSec
  if (-not $ready) {
    $portOwners = @(Get-TcpPortOwners ([int]$Plan.port))
    $portDetail = "portOwners=$(Format-PortOwners $portOwners)"
    if ($launch.process.HasExited) {
      throw "Symphony++ backend exited before becoming healthy at $($Plan.url). $portDetail stderr_log=$($launch.stderr)"
    }

    Stop-LoggedProcess $launch
    throw "Symphony++ backend did not become healthy at $($Plan.url) within $TimeoutSec seconds. $portDetail stderr_log=$($launch.stderr)"
  }

  $health = Get-SymppBackendHealthWithRetry $Plan.url
  if (-not (Test-BackendContractMatches $health $ExpectedContractFingerprint)) {
    Stop-LoggedProcess $launch
    throw "Symphony++ backend at $($Plan.url) reported MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $health.contract_fingerprint), expected $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). stderr_log=$($launch.stderr)"
  }

  $listenerPid = Get-ManagedListenerPid "backend" ([int]$Plan.port)
  return [pscustomobject]@{
    pid = if ($listenerPid) { $listenerPid } else { $launch.process.Id }
    stdout = $launch.stdout
    stderr = $launch.stderr
    source_revision = if ($health.healthy) { $health.source_revision } else { $null }
    contract_fingerprint = if ($health.healthy) { $health.contract_fingerprint } else { $null }
  }
}

function Test-FrontendDependenciesAvailable([string]$AssetsDir) {
  foreach ($candidate in @(
      "node_modules/.bin/vite.cmd",
      "node_modules/.bin/vite.ps1",
      "node_modules/.bin/vite"
    )) {
    if (Test-Path -LiteralPath (Join-Path $AssetsDir $candidate)) {
      return $true
    }
  }

  return $false
}

function Install-FrontendDependencies([string]$AssetsDir, [string]$LogDir, [int]$TimeoutSec) {
  if (Test-FrontendDependenciesAvailable $AssetsDir) {
    return $null
  }

  $npm = Resolve-NpmCommand
  $args = if (Test-Path -LiteralPath (Join-Path $AssetsDir "package-lock.json")) {
    @("ci", "--no-audit", "--no-fund")
  } else {
    @("install", "--no-audit", "--no-fund")
  }

  Write-Diagnostic "Installing Symphony++ dashboard dependencies in $AssetsDir because Vite is missing."
  $launch = Start-LoggedProcess $npm $args $AssetsDir @{} "frontend-install" $LogDir
  $completed = $false
  try {
    $completed = $launch.process.WaitForExit($TimeoutSec * 1000)
    if (-not $completed) {
      throw "Timed out after $TimeoutSec seconds."
    }

    if ($launch.process.ExitCode -ne 0) {
      throw "Exited with code $($launch.process.ExitCode)."
    }

    return $launch
  } catch {
    if (-not $completed) {
      Stop-LoggedProcess $launch
    }

    throw "frontend-install failed. detail=$($_.Exception.Message) stdout_log=$($launch.stdout) stderr_log=$($launch.stderr)"
  }
}

function Start-Frontend($Plan, [string]$BackendUrl, [string]$AssetsDir, [string]$LogDir, [int]$TimeoutSec) {
  $npm = Resolve-NpmCommand
  $args = @("run", "dev", "--", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  $launch = Start-LoggedProcess $npm $args $AssetsDir @{ SYMPP_API_ORIGIN = $BackendUrl } "frontend-$($Plan.port)" $LogDir
  $ready = Wait-Until { Test-HealthySymppDashboard $Plan.origin } $TimeoutSec
  if (-not $ready) {
    if ($launch.process.HasExited) {
      throw "Symphony++ dashboard exited before becoming healthy. stderr: $($launch.stderr)"
    }

    Stop-LoggedProcess $launch
    throw "Symphony++ dashboard did not become healthy at $($Plan.origin) within $TimeoutSec seconds. logs: $($launch.stderr)"
  }

  $listenerPid = Get-ManagedListenerPid "frontend" ([int]$Plan.port)
  return [pscustomobject]@{
    pid = if ($listenerPid) { $listenerPid } else { $launch.process.Id }
    stdout = $launch.stdout
    stderr = $launch.stderr
  }
}

function Get-RequestIdForError([string]$Line) {
  try {
    $payload = $Line | ConvertFrom-Json
    if ($payload.PSObject.Properties["id"]) {
      return $payload.id
    }
  } catch {
  }

  return $null
}

function Write-JsonRpcErrorLine([object]$Id, [int]$Code, [string]$Message, [object]$Data = $null) {
  $errorObject = @{
    jsonrpc = "2.0"
    id = $Id
    error = @{
      code = $Code
      message = $Message
    }
  }
  if ($null -ne $Data) {
    $errorObject.error["data"] = $Data
  }

  [Console]::Out.WriteLine(($errorObject | ConvertTo-Json -Depth 12 -Compress))
  [Console]::Out.Flush()
}

function Write-McpResponseLine([string]$Content) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    return
  }

  $line = $Content.Trim() -replace "(`r`n|`n|`r)", ""
  if (-not [string]::IsNullOrWhiteSpace($line)) {
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
  }
}

function Invoke-HttpMcpBridge([string]$McpUrl, [int]$TimeoutSec) {
  $sessionId = $null
  $protocolVersion = $null
  while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
      break
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $requestProtocolVersion = Get-InitializeProtocolVersion $line
    $response = Invoke-McpPost $McpUrl $line $sessionId $protocolVersion $TimeoutSec
    $nextSessionId = Get-ResponseHeaderValue $response.headers "Mcp-Session-Id"
    if (-not [string]::IsNullOrWhiteSpace($nextSessionId)) {
      $sessionId = $nextSessionId
    }

    if (-not $response.ok) {
      Write-JsonRpcErrorLine (Get-RequestIdForError $line) -32000 "Symphony++ HTTP MCP bridge request failed." @{
        statusCode = $response.statusCode
        detail = $response.error
      }
      continue
    }

    if (-not [string]::IsNullOrWhiteSpace($requestProtocolVersion)) {
      $responseProtocolVersion = Get-ResponseProtocolVersion @($response.content_lines)
      if (-not [string]::IsNullOrWhiteSpace($responseProtocolVersion)) {
        $protocolVersion = $responseProtocolVersion
      } else {
        $protocolVersion = $requestProtocolVersion
      }
    }

    foreach ($contentLine in @($response.content_lines)) {
      Write-McpResponseLine $contentLine
    }
  }
}

function Invoke-DirectStdioMcp([string]$RepoRoot, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, $ArtifactRuntime = $null) {
  $mcpArgs = @("sympp.mcp", "--mode", "stdio")
  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $mcpArgs += @("--repo-root", $RepoRoot)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $mcpArgs += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  if ($null -ne $ArtifactRuntime) {
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals([string]$ArtifactRuntime.command_contract, "runtime_wrapper")) {
      throw "artifact_direct_stdio_unsupported: verified artifact runtimes start the HTTP backend wrapper; use SYMPP_MCP_BRIDGE_MODE=http."
    }

    Set-Location -LiteralPath ([string]$ArtifactRuntime.root)
    & ([string]$ArtifactRuntime.entrypoint) @($mcpArgs)
    exit $LASTEXITCODE
  }

  Set-Location -LiteralPath $ElixirDir
  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $mcpArgs
  & $command.file @($command.args)
  exit $LASTEXITCODE
}
