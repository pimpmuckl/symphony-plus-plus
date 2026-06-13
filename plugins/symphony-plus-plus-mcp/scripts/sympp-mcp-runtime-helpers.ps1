$ErrorActionPreference = "Stop"

function Stop-ManagedServersIfUnused([string]$RuntimeFile, [string]$RuntimeKey) {
  $lock = Enter-FileLock (Resolve-StartupLockFile $RuntimeFile) 30
  try {
    $activeLeases = @(Get-ActiveBridgeLeases $RuntimeFile)
    if ((Test-ActiveLegacyBridgeLease $activeLeases) -or (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases $RuntimeKey)) {
      return
    }

    $state = Read-RuntimeState $RuntimeFile
    if ($null -eq $state) {
      return
    }

    $stateKey = Get-RuntimeStateKey $state
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($stateKey, $RuntimeKey)) {
      [void](Stop-CurrentManagedRuntimeStateEntries $state $activeLeases)
    }
    $supersededStates = Stop-SupersededRuntimeStatesIfUnused $RuntimeFile (Get-SupersededRuntimeStates $state)
    Set-SupersededRuntimeStates $state $supersededStates

    Write-RuntimeState $RuntimeFile $state
  } finally {
    Exit-FileLock $lock
  }
}

function Start-LoggedProcess([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [hashtable]$Environment, [string]$LogPrefix, [string]$LogDir) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdoutPath = Join-Path $LogDir "$LogPrefix-$stamp.out.log"
  $stderrPath = Join-Path $LogDir "$LogPrefix-$stamp.err.log"
  $startCommand = Get-StartProcessCommand $FilePath $ArgumentList
  $startArgumentList = if ($null -ne $startCommand.PSObject.Properties["argument_string"]) {
    [string]$startCommand.argument_string
  } else {
    Join-ProcessArgumentList @($startCommand.args)
  }

  $oldEnvironment = @{}
  foreach ($key in @($Environment.Keys)) {
    $oldEnvironment[$key] = [Environment]::GetEnvironmentVariable([string]$key, "Process")
    [Environment]::SetEnvironmentVariable([string]$key, [string]$Environment[$key], "Process")
  }

  try {
    $startArgs = @{
      FilePath = $startCommand.file
      ArgumentList = $startArgumentList
      WorkingDirectory = $WorkingDirectory
      RedirectStandardOutput = $stdoutPath; RedirectStandardError = $stderrPath; PassThru = $true
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $startArgs["WindowStyle"] = "Hidden" }
    $process = Start-Process @startArgs
  } finally {
    foreach ($key in @($Environment.Keys)) {
      [Environment]::SetEnvironmentVariable([string]$key, $oldEnvironment[$key], "Process")
    }
  }

  return [pscustomobject]@{
    process = $process
    stdout = $stdoutPath
    stderr = $stderrPath
  }
}

function Stop-LoggedProcess($Launch) {
  if ($null -eq $Launch -or $null -eq $Launch.process -or $Launch.process.HasExited) {
    return
  }

  Stop-Process -Id $Launch.process.Id -Force -ErrorAction SilentlyContinue
  try {
    [void]$Launch.process.WaitForExit(5000)
  } catch {
  }
}

function Wait-Until([scriptblock]$Predicate, [int]$TimeoutSec) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if (& $Predicate) {
      return $true
    }
    Start-Sleep -Milliseconds 500
  }

  return $false
}

function New-ReusedBackendPlan([string]$Status, [string]$Url, $Health, [bool]$Managed, $ProcessId) {
  $url = $Url.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    url = $url
    mcp_url = "$url/mcp"
    port = Get-PortFromOrigin $url
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $ProcessId
    source_revision = $Health.source_revision
    contract_fingerprint = $Health.contract_fingerprint
  }
}

function Resolve-BackendPlan([int]$PreferredPort, [string]$ConfiguredUrl, $RuntimeState, [int]$PortReleaseTimeoutSec, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$EnforcePreferredPort, [int[]]$AvoidPorts = @()) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredUrl)) {
    $url = $ConfiguredUrl.TrimEnd("/")
    Assert-LoopbackHttpOrigin $url "SYMPP_BACKEND_URL"
    $health = Get-SymppBackendHealthWithRetry $url
    if (-not $health.healthy) {
      throw "SYMPP_BACKEND_URL is not a healthy Symphony++ backend: $url"
    }
    if (-not (Test-BackendLaunchCompatible $health $ExpectedContractFingerprint)) {
      throw "SYMPP_BACKEND_URL is healthy but not compatible with this launcher: $(Format-BackendLaunchCompatibilityMismatch $health $ExpectedSourceRevision $ExpectedContractFingerprint): $url"
    }

    Write-CompatibleSourceMismatchDiagnostic $url $health $ExpectedSourceRevision
    return New-ReusedBackendPlan "external_override" $url $health $false $null
  }

  $selectedPort = $null
  if ($PreferredPort -gt 0) {
    $preferredUrl = "http://127.0.0.1:$PreferredPort"
    $preferredHealth = Get-SymppBackendHealthWithRetry $preferredUrl
    $preferredEntry = if ($null -ne $RuntimeState) { $RuntimeState.backend } else { $null }
    if ($preferredHealth.healthy) {
      if (Test-RuntimeEntryExternalOverride $preferredEntry $preferredUrl "backend") {
        Write-Diagnostic "Ignoring recorded external backend $preferredUrl for implicit reuse. Set SYMPP_BACKEND_URL=$preferredUrl to reuse it explicitly."
      } elseif (Test-BackendLaunchCompatible $preferredHealth $ExpectedContractFingerprint) {
        $managed = $false
        $entryPid = $null
        $status = "external_loopback"
        if (Test-RuntimeEntryEndpointMatches "backend" $preferredEntry $preferredUrl) {
          $managed = $preferredEntry.managed -eq $true
          $entryPid = $preferredEntry.pid
          if ($managed) {
            $status = "reused"
          }
        }
        Write-CompatibleSourceMismatchDiagnostic $preferredUrl $preferredHealth $ExpectedSourceRevision
        return New-ReusedBackendPlan $status $preferredUrl $preferredHealth $managed $entryPid
      } else {
        Write-Diagnostic "Ignoring healthy Symphony++ backend $preferredUrl because $(Format-BackendLaunchCompatibilityMismatch $preferredHealth $ExpectedSourceRevision $ExpectedContractFingerprint)"
      }
      $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
    }
  }

  if ($null -ne $RuntimeState -and $null -ne $RuntimeState.backend) {
    $runtimeUrl = [string]$RuntimeState.backend.url
    if (-not [string]::IsNullOrWhiteSpace($runtimeUrl)) {
      $runtimeUrl = $runtimeUrl.TrimEnd("/")
      $runtimeHealth = Get-SymppBackendHealthWithRetry $runtimeUrl
      $runtimeManaged = $RuntimeState.backend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeUrl $EnforcePreferredPort
      if ($runtimeManaged -and $portAllowed -and $runtimeHealth.healthy -and (Test-BackendLaunchCompatible $runtimeHealth $ExpectedContractFingerprint)) {
        Write-CompatibleSourceMismatchDiagnostic $runtimeUrl $runtimeHealth $ExpectedSourceRevision
        return New-ReusedBackendPlan "reused" $runtimeUrl $runtimeHealth ($RuntimeState.backend.managed -eq $true) $RuntimeState.backend.pid
      }

      if ($runtimeHealth.healthy -and -not (Test-BackendLaunchCompatible $runtimeHealth $ExpectedContractFingerprint)) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because $(Format-BackendLaunchCompatibilityMismatch $runtimeHealth $ExpectedSourceRevision $ExpectedContractFingerprint)"
      } elseif ($runtimeHealth.healthy -and -not $runtimeManaged) {
        Write-Diagnostic "Ignoring recorded external backend $runtimeUrl for implicit reuse. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      } elseif ($runtimeHealth.healthy -and -not $portAllowed) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because SYMPP_BACKEND_PORT requests $PreferredPort. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      }
    }
  }

  if ($null -eq $selectedPort -and $PreferredPort -gt 0) {
    $portRelease = Wait-ForTcpPortRelease $PreferredPort $PortReleaseTimeoutSec
    if (-not $portRelease.released) {
      if (Test-SymppBackendOwners @($portRelease.owners)) {
        $busyHealth = Get-SymppBackendHealthWithRetry "http://127.0.0.1:$PreferredPort" 6 750
        if ($busyHealth.healthy -and (Test-BackendLaunchCompatible $busyHealth $ExpectedContractFingerprint)) {
          Write-CompatibleSourceMismatchDiagnostic "http://127.0.0.1:$PreferredPort" $busyHealth $ExpectedSourceRevision
          return New-ReusedBackendPlan "external_loopback" "http://127.0.0.1:$PreferredPort" $busyHealth $false $null
        }
        if ($busyHealth.mcp_ready) {
          Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) The occupied Symphony++ backend responded to MCP but is not a healthy compatible runtime (status=$($busyHealth.status), source=$(Format-SourceRevisionForDiagnostic $busyHealth.source_revision), contract=$(Format-McpContractFingerprintForDiagnostic $busyHealth.contract_fingerprint)). Selecting a fallback managed backend port for this Codex session."
          $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
        } elseif (-not $EnforcePreferredPort) {
          Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) The occupied Symphony++ backend did not become MCP-ready after the bounded retry window. Selecting a fallback managed backend port for this Codex session."
          $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
        } else {
          throw (New-BackendBusySymppMessage $PreferredPort @($portRelease.owners) $busyHealth)
        }
      } else {
        Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) Selecting a fallback managed backend port for this Codex session."
        $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
      }
    } else {
      $selectedPort = $PreferredPort
    }
  } elseif ($null -eq $selectedPort) {
    $selectedPort = Select-AvailablePort $PreferredPort @($AvoidPorts)
  }

  $url = "http://127.0.0.1:$selectedPort"
  return [pscustomobject]@{
    status = "starting"
    url = $url
    mcp_url = "$url/mcp"
    port = $selectedPort
    should_start = $true
    reused = $false
    managed = $true
    pid = $null
    source_revision = $null
    contract_fingerprint = $null
  }
}

function New-ReusedDashboardPlan([string]$Status, [string]$Origin, [bool]$Managed, $ProcessId) {
  $origin = $Origin.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    origin = $origin
    url = "$origin$BoardPath"
    port = Get-PortFromOrigin $origin
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $ProcessId
  }
}

function New-DisabledDashboardPlan([string]$Status, [string]$Error = $null) {
  return [pscustomobject]@{
    status = $Status
    origin = $null
    url = $null
    port = $null
    should_start = $false
    reused = $false
    managed = $false
    pid = $null
    error = $Error
  }
}

function Resolve-FastAttachRuntimePlan {
  param(
    $RuntimeState,
    [string]$ExpectedSourceRevision,
    [string]$ExpectedContractFingerprint,
    [int]$PreferredBackendPort,
    [int]$PreferredDashboardPort,
    [bool]$BackendPortExplicit,
    [bool]$DashboardPortExplicit,
    [string]$ConfiguredBackendUrl,
    [string]$ConfiguredDashboardOrigin,
    [object]$BackendHealthOverride = $null,
    [object]$DashboardHealthyOverride = $null,
    [object]$DashboardProxyMatchesOverride = $null
  )

  if ($BackendPortExplicit -or $DashboardPortExplicit -or
      -not [string]::IsNullOrWhiteSpace($ConfiguredBackendUrl) -or
      -not [string]::IsNullOrWhiteSpace($ConfiguredDashboardOrigin)) {
    return $null
  }

  if ($null -eq $RuntimeState -or $null -eq $RuntimeState.backend -or $null -eq $RuntimeState.frontend) {
    return $null
  }

  $managedRuntime = $RuntimeState.backend.managed -eq $true -and $RuntimeState.frontend.managed -eq $true
  $externalLoopbackRuntime = Test-RuntimeStateExternalLoopback $RuntimeState
  if (-not $managedRuntime -and -not $externalLoopbackRuntime) {
    return $null
  }

  $backendUrl = [string]$RuntimeState.backend.url
  $dashboardOrigin = [string]$RuntimeState.frontend.origin
  if ([string]::IsNullOrWhiteSpace($backendUrl) -or [string]::IsNullOrWhiteSpace($dashboardOrigin)) {
    return $null
  }

  $backendUrl = $backendUrl.TrimEnd("/")
  $dashboardOrigin = $dashboardOrigin.TrimEnd("/")
  try {
    Assert-LoopbackHttpOrigin $backendUrl "recorded Symphony++ backend"
    Assert-LoopbackHttpOrigin $dashboardOrigin "recorded Symphony++ dashboard"
  } catch {
    return $null
  }

  $artifactRuntimeState = $RuntimeState.PSObject.Properties["runtime_kind"] -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$RuntimeState.runtime_kind, "artifact")
  $dashboardSharesBackendPort = [System.StringComparer]::OrdinalIgnoreCase.Equals($backendUrl, $dashboardOrigin)
  $dashboardPortAllowed = if ($artifactRuntimeState -and $dashboardSharesBackendPort) {
    $true
  } else {
    Test-PortSelectionAllowsReuse $PreferredDashboardPort $dashboardOrigin $true
  }

  if (-not (Test-PortSelectionAllowsReuse $PreferredBackendPort $backendUrl $true) -or
      -not $dashboardPortAllowed) {
    return $null
  }

  $backendHealth = if ($null -ne $BackendHealthOverride) { $BackendHealthOverride } else { Get-SymppBackendHealthWithRetry $backendUrl }
  if (-not (Test-BackendLaunchCompatible $backendHealth $ExpectedContractFingerprint)) {
    return $null
  }
  Write-CompatibleSourceMismatchDiagnostic $backendUrl $backendHealth $ExpectedSourceRevision

  $dashboardHealthy = if ($null -ne $DashboardHealthyOverride) { [bool]$DashboardHealthyOverride } else { Test-HealthySymppDashboard $dashboardOrigin }
  if (-not $dashboardHealthy) {
    return $null
  }

  $dashboardProxyMatches =
    if ($null -ne $DashboardProxyMatchesOverride) {
      [bool]$DashboardProxyMatchesOverride
    } else {
      Test-SymppDashboardMcpProxyMatches $dashboardOrigin $ExpectedContractFingerprint
    }
  if (-not $dashboardProxyMatches) {
    return $null
  }

  $planStatus = if ($managedRuntime) { "fast_attach" } else { "external_loopback" }
  $backendPlan = New-ReusedBackendPlan $planStatus $backendUrl $backendHealth $managedRuntime $RuntimeState.backend.pid
  $dashboardPlan = New-ReusedDashboardPlan $planStatus $dashboardOrigin $managedRuntime $RuntimeState.frontend.pid
  $runtimeKey = New-RuntimeKey $backendPlan.url $dashboardPlan.origin $backendHealth.contract_fingerprint
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals((Get-RuntimeStateKey $RuntimeState), $runtimeKey)) {
    return $null
  }

  return [pscustomobject]@{
    backend_plan = $backendPlan
    dashboard_plan = $dashboardPlan
    runtime_key = $runtimeKey
  }
}

function Resolve-DashboardPlan([int]$PreferredPort, [string]$ConfiguredOrigin, [string]$BackendUrl, [string]$BackendSourceRevision, $RuntimeState, [bool]$EnforcePreferredPort, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$AllowRecordedRuntimeReuse) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredOrigin)) {
    $origin = $ConfiguredOrigin.TrimEnd("/")
    return New-ReusedDashboardPlan "external_override" $origin $false $null
  }

  $backendPort = Get-PortFromOrigin $BackendUrl
  if ($PreferredPort -gt 0 -and $PreferredPort -eq $DefaultDashboardPort -and $backendPort -eq $DefaultBackendPort) {
    $preferredOrigin = "http://127.0.0.1:$PreferredPort"
    if ((Test-HealthySymppDashboard $preferredOrigin) -and (Test-SymppDashboardMcpProxyMatches $preferredOrigin $ExpectedContractFingerprint)) {
      $preferredEntry = if ($null -ne $RuntimeState) { $RuntimeState.frontend } else { $null }
      $managed = $false
      $entryPid = $null
      $status = "external_loopback"
      if (Test-RuntimeEntryExternalOverride $preferredEntry $preferredOrigin "frontend") {
        Write-Diagnostic "Ignoring recorded external dashboard $preferredOrigin for implicit default-port reuse. Set SYMPP_DASHBOARD_ORIGIN=$preferredOrigin to reuse it explicitly."
      } elseif (Test-RuntimeEntryEndpointMatches "frontend" $preferredEntry $preferredOrigin) {
        $managed = $preferredEntry.managed -eq $true
        $entryPid = $preferredEntry.pid
        if ($managed) {
          $status = "reused"
        }

        return New-ReusedDashboardPlan $status $preferredOrigin $managed $entryPid
      } else {
        return New-ReusedDashboardPlan $status $preferredOrigin $managed $entryPid
      }
    }
  }

  if ($AllowRecordedRuntimeReuse -and $null -ne $RuntimeState -and $null -ne $RuntimeState.frontend) {
    $runtimeBackendUrl = [string]$RuntimeState.backend.url
    $runtimeOrigin = [string]$RuntimeState.frontend.origin
    if (-not [string]::IsNullOrWhiteSpace($runtimeBackendUrl) -and
        $runtimeBackendUrl.TrimEnd("/") -eq $BackendUrl.TrimEnd("/")) {
      $runtimeManaged = $RuntimeState.frontend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeOrigin $EnforcePreferredPort
      if ($runtimeManaged -and $portAllowed -and -not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin) -and (Test-SymppDashboardMcpProxyMatches $runtimeOrigin $ExpectedContractFingerprint)) {
        return New-ReusedDashboardPlan "reused" $runtimeOrigin ($RuntimeState.frontend.managed -eq $true) $RuntimeState.frontend.pid
      }
      if (-not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
        if (-not $runtimeManaged) {
          Write-Diagnostic "Ignoring recorded external dashboard $($runtimeOrigin.TrimEnd('/')) for implicit reuse. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        } elseif (-not $portAllowed) {
          Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because SYMPP_DASHBOARD_PORT requests $PreferredPort. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        } elseif (-not (Test-SymppDashboardMcpProxyMatches $runtimeOrigin $ExpectedContractFingerprint)) {
          Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because its MCP proxy does not match expected MCP contract $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). Expected source revision remains $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision)."
        }
      }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
      Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because it was recorded for backend $($runtimeBackendUrl.TrimEnd('/')), not $($BackendUrl.TrimEnd('/'))."
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision) -and
      -not (Test-SourceRevisionEquals $BackendSourceRevision $ExpectedSourceRevision)) {
    Write-Diagnostic "Not starting Symphony++ dashboard assets from source $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision) against compatible backend source $(Format-SourceRevisionForDiagnostic $BackendSourceRevision). MCP bridge will attach backend-only; restart the singleton or set SYMPP_DASHBOARD_ORIGIN to use an operator-owned dashboard."
    return New-DisabledDashboardPlan "disabled_source_drift" "backend_source_revision_mismatch"
  }

  $avoid = if ($backendPort) { @([int]$backendPort) } else { @() }
  $selectedPort = Select-AvailablePort $PreferredPort $avoid
  $origin = "http://127.0.0.1:$selectedPort"
  return [pscustomobject]@{
    status = "starting"
    origin = $origin
    url = "$origin$BoardPath"
    port = $selectedPort
    should_start = $true
    reused = $false
    managed = $true
    pid = $null
  }
}

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

function Start-Backend($Plan, [string]$DashboardOrigin, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec, [string]$ExpectedContractFingerprint, $ArtifactRuntime = $null) {
  $args = @("sympp.cockpit", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $args += @("--dashboard-origin", $DashboardOrigin)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $args += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  if ($null -ne $ArtifactRuntime) {
    $command = [pscustomobject]@{
      file = [string]$ArtifactRuntime.entrypoint
      args = $args
      working_directory = [string]$ArtifactRuntime.root
    }
  } else {
    Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
    $sourceCommand = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $args
    $command = [pscustomobject]@{
      file = $sourceCommand.file
      args = $sourceCommand.args
      working_directory = $ElixirDir
    }
  }

  $launch = Start-LoggedProcess $command.file $command.args $command.working_directory @{} "backend-$($Plan.port)" $LogDir
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
