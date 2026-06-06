param(
  [switch]$Help,
  [switch]$ValidateOnly,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$DefaultBackendPort = 19998
$DefaultDashboardPort = 19999
$BoardPath = "/sympp/board"

. (Join-Path $PSScriptRoot "sympp-launcher-runtime.ps1")

function Write-Usage {
  Write-Host "Starts the Symphony++ Codex plugin MCP bridge and local operator servers."
  Write-Host ""
  Write-Host "Default behavior:"
  Write-Host "  - Reuse a healthy Symphony++ runtime when its source revision matches this launcher."
  Write-Host "  - Start a fresh managed backend and dashboard for a new source revision, leaving old leased runtimes to drain."
  Write-Host "  - Bridge Codex stdio MCP traffic into the HTTP backend /mcp endpoint."
  Write-Host ""
  Write-Host "Environment:"
  Write-Host "  SYMPP_REPO_ROOT              Optional Symphony++ source checkout override. Marketplace installs are discovered automatically."
  Write-Host "  SYMPP_DATABASE               Optional SQLite ledger override passed to mix sympp.cockpit and mix sympp.mcp direct fallback."
  Write-Host "  SYMPP_LAUNCHER               Optional launcher: 'direct' or 'mise'. Defaults to 'mise' when elixir/mise.toml is present and mise is available; otherwise 'direct'."
  Write-Host "  SYMPP_MIX                    Optional mix executable path or name for direct launcher. Defaults to 'mix'."
  Write-Host "  SYMPP_MISE                   Optional mise executable path or name for mise launcher. Defaults to 'mise'."
  Write-Host "  MIX_BUILD_ROOT               Optional Mix build-root override. Defaults under %USERPROFILE%\.agents\splusplus\build\mcp for plugin launcher runs."
  Write-Host "  SYMPP_BACKEND_PORT           Backend/API port. Defaults to $DefaultBackendPort. Use 0 for any available port."
  Write-Host "  SYMPP_BACKEND_URL            Reuse an already-running backend URL instead of starting mix sympp.cockpit."
  Write-Host "  SYMPP_DASHBOARD_PORT         Preferred dashboard port. Defaults to $DefaultDashboardPort. Use 0 for any available port."
  Write-Host "  SYMPP_DASHBOARD_ORIGIN       Reuse an external dashboard origin instead of starting Vite."
  Write-Host "  SYMPP_AUTOSTART_SERVERS      Set to 0/false/off to skip backend and frontend autostart."
  Write-Host "  SYMPP_AUTOSTART_BACKEND      Set to 0/false/off to skip backend autostart."
  Write-Host "  SYMPP_AUTOSTART_FRONTEND     Set to 0/false/off to skip frontend autostart."
  Write-Host "  SYMPP_MCP_BRIDGE_MODE        'http' (default) bridges stdio to HTTP; 'direct_stdio' runs mix sympp.mcp directly."
  Write-Host "  SYMPP_RUNTIME_FILE           Optional runtime JSON output path. Defaults under %USERPROFILE%\.agents\splusplus\runtime."
  Write-Host "  SYMPP_LOG_DIR                Optional background server log directory. Defaults under %USERPROFILE%\.agents\splusplus\logs."
  Write-Host "  SYMPP_BACKEND_STARTUP_TIMEOUT_SEC    Backend startup wait. Defaults to 60."
  Write-Host "  SYMPP_BACKEND_PORT_RELEASE_TIMEOUT_SEC  Preferred backend port stale-listener wait. Defaults to 15."
  Write-Host "  SYMPP_ELIXIR_SETUP_TIMEOUT_SEC   Per-command Elixir setup wait. Defaults to 300."
  Write-Host "  SYMPP_FRONTEND_INSTALL_TIMEOUT_SEC   Dashboard npm install wait when dependencies are missing. Defaults to 180."
  Write-Host "  SYMPP_FRONTEND_STARTUP_TIMEOUT_SEC   Frontend startup wait. Defaults to 20."
  Write-Host "  SYMPP_MCP_HTTP_TIMEOUT_SEC           Per-request bridge timeout. Defaults to 300."
  Write-Host "  SYMPP_STARTUP_LOCK_TIMEOUT_SEC       Local startup lock wait. Defaults to the configured startup waits plus 30 seconds, with a 120-second floor."
  Write-Host ""
  Write-Host "Installed plugins first use marketplace source discovery; local refresh may also write a non-secret .sympp-source-root hint."
}

function Write-Diagnostic([string]$Message) {
  [Console]::Error.WriteLine($Message)
}

function Resolve-OptionalPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Test-SymphonySourceRoot([string]$Path) {
  return (-not [string]::IsNullOrWhiteSpace($Path)) -and (Test-Path -LiteralPath (Join-Path $Path "elixir/mix.exs"))
}

function Resolve-RepoRootFromMarketplaceCache([string]$PluginRoot) {
  $versionRoot = [System.IO.Path]::GetFullPath($PluginRoot)
  $packageRoot = Split-Path -Parent $versionRoot
  $marketplaceRoot = Split-Path -Parent $packageRoot
  $cacheRoot = Split-Path -Parent $marketplaceRoot
  $pluginsRoot = Split-Path -Parent $cacheRoot

  if ((Split-Path -Leaf $cacheRoot) -ne "cache" -or (Split-Path -Leaf $pluginsRoot) -ne "plugins") {
    return $null
  }

  $codexHome = Split-Path -Parent $pluginsRoot
  $marketplaceName = Split-Path -Leaf $marketplaceRoot
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $codexHome ".tmp/marketplaces/$marketplaceName"))

  if ((Test-SymphonySourceRoot $candidate) -and
      (Test-Path -LiteralPath (Join-Path $candidate "plugins/symphony-plus-plus/.codex-plugin/plugin.json")) -and
      (Test-Path -LiteralPath (Join-Path $candidate "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json"))) {
    return $candidate
  }

  return $null
}

function Resolve-RepoRoot {
  $configuredRoot = Resolve-OptionalPath $env:SYMPP_REPO_ROOT
  if ($configuredRoot) {
    if (Test-SymphonySourceRoot $configuredRoot) {
      return $configuredRoot
    }

    throw "SYMPP_REPO_ROOT does not look like a Symphony++ checkout with elixir/mix.exs: $configuredRoot"
  }

  $pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
  if (Test-SymphonySourceRoot $sourceCandidate) {
    return $sourceCandidate
  }

  $marketplaceRoot = Resolve-RepoRootFromMarketplaceCache $pluginRoot
  if ($marketplaceRoot) {
    return $marketplaceRoot
  }

  $invalidSourceRootHint = $false
  $sourceRootHintPath = Join-Path $pluginRoot ".sympp-source-root"
  if (Test-Path -LiteralPath $sourceRootHintPath) {
    $hintText = (Get-Content -LiteralPath $sourceRootHintPath -Raw).Trim().TrimStart([char]0xFEFF)
    $hintedRoot = Resolve-OptionalPath $hintText
    if ($hintedRoot -and (Test-SymphonySourceRoot $hintedRoot)) {
      return $hintedRoot
    }

    $invalidSourceRootHint = $true
  }

  if ($invalidSourceRootHint) {
    throw "Installed plugin source-root hint is invalid. Refresh the plugin cache or set SYMPP_REPO_ROOT."
  }

  throw "Cannot infer the Symphony++ runtime source. Reinstall or refresh the Symphony++ marketplace, or set SYMPP_REPO_ROOT to the source checkout root before starting the plugin MCP server."
}

function Resolve-SymppHome {
  $configured = Resolve-OptionalPath $env:SYMPP_HOME
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path $HOME ".agents/splusplus"))
}

function Resolve-RuntimeFile {
  $configured = Resolve-OptionalPath $env:SYMPP_RUNTIME_FILE
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppHome) "runtime/codex-plugin.json"))
}

function Resolve-LogDir {
  $configured = Resolve-OptionalPath $env:SYMPP_LOG_DIR
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppHome) "logs"))
}

function Resolve-StartupLockFile([string]$RuntimeFile) {
  $runtimeDir = Split-Path -Parent $RuntimeFile
  return [System.IO.Path]::GetFullPath((Join-Path $runtimeDir "codex-plugin.lock"))
}

function Enter-FileLock([string]$LockPath, [int]$TimeoutSec) {
  $lockDir = Split-Path -Parent $LockPath
  New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 200
    }
  }

  throw "Timed out waiting for Symphony++ launcher startup lock: $LockPath"
}

function Exit-FileLock($Lock) {
  if ($null -ne $Lock) {
    $Lock.Dispose()
  }
}

function Test-EnvDisabled([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $false
  }

  return $value.Trim().ToLowerInvariant() -in @("0", "false", "no", "off")
}

function Get-EnvInteger([string]$Name, [int]$Default, [int]$Min, [int]$Max) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Default
  }

  $parsed = 0
  if (-not [int]::TryParse($value.Trim(), [ref]$parsed) -or $parsed -lt $Min -or $parsed -gt $Max) {
    throw "$Name must be an integer from $Min to $Max."
  }

  return $parsed
}

function Get-EnvMode([string]$Name, [string]$Default, [string[]]$Allowed) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  $mode = if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { $value.Trim().ToLowerInvariant() }
  if ($Allowed -notcontains $mode) {
    throw "$Name must be one of: $($Allowed -join ', ')."
  }

  return $mode
}

function Test-IsMiseShim([string]$Path) {
  $normalized = $Path.Replace("\", "/").ToLowerInvariant()
  return ($normalized -match "/mise/" -or $normalized -match "/\.mise/") -and $normalized -match "/shims?/"
}

function Resolve-CommandSource([string]$CommandName, [string]$MissingMessage) {
  $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw $MissingMessage
  }

  if ($command.Source) {
    return [string]$command.Source
  }

  return [string]$command.Path
}

function Assert-LoopbackHttpOrigin([string]$Url, [string]$Name) {
  try {
    $uri = [System.Uri]$Url
  } catch {
    throw "$Name must be a valid local http URL."
  }

  if ($uri.Scheme -ne "http" -or -not $uri.IsLoopback) {
    throw "$Name must use a loopback http origin."
  }
}

function Resolve-NpmCommand {
  foreach ($candidate in @("npm.cmd", "npm.exe", "npm")) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.CommandType -eq "Application") {
      if ($command.Source) {
        return [string]$command.Source
      }
      return [string]$command.Path
    }
  }

  throw "Could not find npm executable. Install Node/npm or set SYMPP_DASHBOARD_ORIGIN to an existing dashboard."
}

function Test-NpmAvailable {
  try {
    [void](Resolve-NpmCommand)
    return $true
  } catch {
    return $false
  }
}

function Get-PowerShellHostCommandName {
  foreach ($candidate in @("pwsh", "powershell.exe", "powershell")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
      return $candidate
    }
  }

  return "powershell"
}

function Get-StartProcessCommand([string]$FilePath, [string[]]$ArgumentList) {
  if ($FilePath.EndsWith(".ps1", [System.StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{
      file = Get-PowerShellHostCommandName
      args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FilePath) + @($ArgumentList)
    }
  }

  return [pscustomobject]@{
    file = $FilePath
    args = @($ArgumentList)
  }
}

function ConvertTo-ProcessArgument([string]$Argument) {
  if ($null -eq $Argument -or $Argument.Length -eq 0) {
    return '""'
  }

  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }

  $result = [System.Text.StringBuilder]::new()
  [void]$result.Append('"')
  $backslashes = 0
  foreach ($char in $Argument.ToCharArray()) {
    if ($char -eq '\') {
      $backslashes += 1
    } elseif ($char -eq '"') {
      [void]$result.Append('\' * (($backslashes * 2) + 1))
      [void]$result.Append('"')
      $backslashes = 0
    } else {
      if ($backslashes -gt 0) {
        [void]$result.Append('\' * $backslashes)
        $backslashes = 0
      }
      [void]$result.Append($char)
    }
  }

  if ($backslashes -gt 0) {
    [void]$result.Append('\' * ($backslashes * 2))
  }
  [void]$result.Append('"')
  return $result.ToString()
}

function Join-ProcessArgumentList([string[]]$ArgumentList) {
  return (@($ArgumentList) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
}

function Resolve-MixCommand([string]$MixCommand) {
  $source = Resolve-CommandSource $MixCommand "Could not find mix executable '$MixCommand'. Install Elixir or set SYMPP_MIX."
  if (Test-IsMiseShim $source) {
    throw "Direct launcher resolved mix to a mise shim: $source. Set SYMPP_MIX to a non-mise Mix executable, or set SYMPP_LAUNCHER=mise after trusting the checkout's mise config."
  }

  return $source
}

function Assert-LauncherAvailable([string]$Launcher, [string]$MixCommand, [string]$MiseCommand) {
  switch ($Launcher) {
    "direct" {
      [void](Resolve-MixCommand $MixCommand)
      return
    }
    "mise" {
      [void](Resolve-CommandSource $MiseCommand "Could not find mise executable '$MiseCommand'. Install mise or set SYMPP_MISE.")
      return
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$Launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Get-LauncherCommand([string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string[]]$MixArgs) {
  switch ($Launcher) {
    "direct" {
      return [pscustomobject]@{
        file = Resolve-MixCommand $MixCommand
        args = @($MixArgs)
      }
    }
    "mise" {
      return [pscustomobject]@{
        file = Resolve-CommandSource $MiseCommand "Could not find mise executable '$MiseCommand'. Install mise or set SYMPP_MISE."
        args = @("exec", "--", "mix") + @($MixArgs)
      }
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$Launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Test-LauncherVersion([string]$Launcher, [string]$MixCommand, [string]$MiseCommand) {
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand @("--version")
  & $command.file @($command.args) | Out-Host
  return $LASTEXITCODE
}

function Test-PortAvailable([int]$Port) {
  if ($Port -eq 0) {
    return $true
  }

  $listener = $null
  try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) {
      $listener.Stop()
    }
  }
}

function New-PortOwner([int]$ProcessId, [string]$LocalAddress) {
  $processName = "<unknown>"
  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($process.ProcessName)) {
      $processName = [string]$process.ProcessName
    }
  } catch {
  }

  return [pscustomobject]@{
    pid = $ProcessId
    process = $processName
    localAddress = $LocalAddress
  }
}

function Add-PortOwner($Owners, $Seen, [int]$ProcessId, [string]$LocalAddress) {
  $key = "$ProcessId|$LocalAddress"
  if ($Seen.Contains($key)) {
    return
  }

  [void]$Seen.Add($key)
  [void]$Owners.Add((New-PortOwner $ProcessId $LocalAddress))
}

function Get-TcpPortOwners([int]$Port) {
  $owners = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new()

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
      $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
      foreach ($connection in $connections) {
        $processId = [int]$connection.OwningProcess
        if ($processId -gt 0) {
          Add-PortOwner $owners $seen $processId ([string]$connection.LocalAddress)
        }
      }
    } catch {
    }
  }

  if ($owners.Count -eq 0 -and (Get-Command netstat -ErrorAction SilentlyContinue)) {
    try {
      $escapedPort = [regex]::Escape([string]$Port)
      foreach ($line in @(& netstat -ano -p tcp 2>$null)) {
        if ($line -match "^\s*TCP\s+(.+):$escapedPort\s+\S+\s+LISTENING\s+(\d+)\s*$") {
          Add-PortOwner $owners $seen ([int]$matches[2]) $matches[1].Trim()
        }
      }
    } catch {
    }
  }

  return @($owners)
}

function Format-PortOwners([object[]]$Owners) {
  if ($Owners.Count -eq 0) {
    return "an unknown process"
  }

  return (@($Owners) | ForEach-Object {
      "pid=$($_.pid) process=$($_.process) localAddress=$($_.localAddress)"
    }) -join "; "
}

function New-BackendPortOccupiedMessage([int]$Port, [object[]]$Owners) {
  $ownerSummary = Format-PortOwners $Owners
  return "backend_port_occupied: configured Symphony++ backend port http://127.0.0.1:$Port is occupied by $ownerSummary. Wait for stale listeners to exit, stop the owning process, set SYMPP_BACKEND_PORT=0 or another explicit port, or set SYMPP_BACKEND_URL to a healthy backend."
}

function Wait-ForTcpPortRelease([int]$Port, [int]$TimeoutSec) {
  if ($Port -eq 0 -or (Test-PortAvailable $Port)) {
    return [pscustomobject]@{
      released = $true
      owners = @()
    }
  }

  $owners = @(Get-TcpPortOwners $Port)
  if ($TimeoutSec -gt 0) {
    Write-Diagnostic "Configured Symphony++ backend port 127.0.0.1:$Port is occupied by $(Format-PortOwners $owners); waiting up to $TimeoutSec seconds for stale listeners to clear."
  }

  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-PortAvailable $Port) {
      return [pscustomobject]@{
        released = $true
        owners = @()
      }
    }

    $owners = @(Get-TcpPortOwners $Port)
  }

  return [pscustomobject]@{
    released = $false
    owners = $owners
  }
}

function Get-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    $listener.Stop()
  }
}

function Select-AvailablePort([int]$PreferredPort, [int[]]$Avoid = @()) {
  $avoidSet = [System.Collections.Generic.HashSet[int]]::new()
  foreach ($port in @($Avoid)) {
    if ($port -gt 0) {
      [void]$avoidSet.Add($port)
    }
  }

  if ($PreferredPort -eq 0) {
    do {
      $port = Get-FreeTcpPort
    } while ($avoidSet.Contains($port))
    return $port
  }

  if (-not $avoidSet.Contains($PreferredPort) -and (Test-PortAvailable $PreferredPort)) {
    return $PreferredPort
  }

  for ($offset = 1; $offset -le 200; $offset++) {
    $candidate = $PreferredPort + $offset
    if ($candidate -gt 65535) {
      break
    }
    if (-not $avoidSet.Contains($candidate) -and (Test-PortAvailable $candidate)) {
      return $candidate
    }
  }

  do {
    $fallback = Get-FreeTcpPort
  } while ($avoidSet.Contains($fallback))
  return $fallback
}

function ConvertTo-JsonBody($Payload) {
  return $Payload | ConvertTo-Json -Depth 16 -Compress
}

function Get-ResponseHeaderValue($Headers, [string]$Name) {
  if ($null -eq $Headers) {
    return $null
  }

  $rawValue = $null
  if ($Headers -is [System.Net.WebHeaderCollection]) {
    $rawValue = $Headers[$Name]
  } elseif ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in $Headers.Keys) {
      if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rawValue = $Headers[$key]
        break
      }
    }
  } else {
    $property = $Headers.PSObject.Properties |
      Where-Object { [string]::Equals($_.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase) } |
      Select-Object -First 1
    if ($property) {
      $rawValue = $property.Value
    }
  }

  foreach ($value in @($rawValue)) {
    if ($null -eq $value) {
      continue
    }

    foreach ($entry in @($value)) {
      foreach ($part in ([string]$entry).Split(",")) {
        $text = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
          return $text
        }
      }
    }
  }

  return $null
}

function Read-ErrorResponseBody($Response) {
  if ($null -eq $Response) {
    return $null
  }

  try {
    if ($Response.PSObject.Methods["GetResponseStream"]) {
      $stream = $Response.GetResponseStream()
      if ($null -eq $stream) {
        return $null
      }

      $reader = [System.IO.StreamReader]::new($stream)
      try {
        return $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
    }

    if ($Response.PSObject.Properties["Content"] -and $Response.Content) {
      return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } catch {
    return $null
  }

  return $null
}

function New-InitializeRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-plugin-launcher-init"
    method = "initialize"
    params = @{
      protocolVersion = "2025-03-26"
      clientInfo = @{
        name = "sympp-plugin-launcher"
        version = "0.1.0"
      }
      capabilities = @{}
    }
  }
}

function New-HealthRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-plugin-launcher-health"
    method = "tools/call"
    params = @{
      name = "sympp.health"
      arguments = @{}
    }
  }
}

function Get-HeaderValue($Headers, [string]$Name) {
  return Get-ResponseHeaderValue $Headers $Name
}

function Convert-SseContentToJsonLines([string]$Content) {
  $messages = [System.Collections.Generic.List[string]]::new()
  $dataLines = [System.Collections.Generic.List[string]]::new()

  foreach ($rawLine in ($Content -split "`r?`n")) {
    $line = $rawLine.TrimEnd("`r")
    if ([string]::IsNullOrWhiteSpace($line)) {
      if ($dataLines.Count -gt 0) {
        $message = ($dataLines -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($message) -and $message -ne "[DONE]") {
          $messages.Add($message)
        }
        $dataLines.Clear()
      }
      continue
    }

    if ($line.StartsWith("data:", [System.StringComparison]::OrdinalIgnoreCase)) {
      $dataLines.Add($line.Substring(5).TrimStart())
    }
  }

  if ($dataLines.Count -gt 0) {
    $message = ($dataLines -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($message) -and $message -ne "[DONE]") {
      $messages.Add($message)
    }
  }

  return @($messages)
}

function Convert-McpHttpContentToJsonLines([string]$Content, $Headers) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    return @()
  }

  $contentType = Get-HeaderValue $Headers "Content-Type"
  if ($contentType -and $contentType.ToLowerInvariant().Contains("text/event-stream")) {
    return @(Convert-SseContentToJsonLines $Content)
  }

  return @($Content.Trim())
}

function Get-InitializeProtocolVersion([string]$Body) {
  try {
    $payload = $Body | ConvertFrom-Json
    if ($payload.method -eq "initialize" -and $payload.params.protocolVersion) {
      return [string]$payload.params.protocolVersion
    }
  } catch {
  }

  return $null
}

function Get-ResponseProtocolVersion([string[]]$ContentLines) {
  foreach ($contentLine in @($ContentLines)) {
    if ([string]::IsNullOrWhiteSpace($contentLine)) {
      continue
    }

    try {
      $payload = $contentLine | ConvertFrom-Json
      if ($payload.result.protocolVersion) {
        return [string]$payload.result.protocolVersion
      }
    } catch {
    }
  }

  return $null
}

function Get-HealthSourceRevision($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["source"]) {
    return $null
  }

  $source = $structuredContent.source
  if ($null -eq $source -or -not $source.PSObject.Properties["revision"]) {
    return $null
  }

  return Normalize-SymppSourceRevision ([string]$source.revision)
}

function Invoke-McpPost([string]$Url, [string]$Body, [string]$SessionId, [string]$ProtocolVersion, [int]$TimeoutSec) {
  $headers = @{ Accept = "application/json, text/event-stream" }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $headers["Mcp-Session-Id"] = $SessionId
  }
  if (-not [string]::IsNullOrWhiteSpace($ProtocolVersion)) {
    $headers["MCP-Protocol-Version"] = $ProtocolVersion
  }

  try {
    $response = Invoke-WebRequest `
      -Uri $Url `
      -Method Post `
      -Headers $headers `
      -ContentType "application/json" `
      -Body $Body `
      -TimeoutSec $TimeoutSec `
      -UseBasicParsing `
      -ErrorAction Stop

    return [pscustomobject]@{
      ok = $true
      statusCode = [int]$response.StatusCode
      headers = $response.Headers
      content = [string]$response.Content
      content_lines = @(Convert-McpHttpContentToJsonLines ([string]$response.Content) $response.Headers)
      error = $null
    }
  } catch {
    $response = $_.Exception.Response
    $statusCode = $null
    if ($null -ne $response) {
      try {
        $statusCode = [int]$response.StatusCode
      } catch {
        $statusCode = $null
      }
    }

    return [pscustomobject]@{
      ok = $false
      statusCode = $statusCode
      headers = if ($null -ne $response) { $response.Headers } else { $null }
      content = Read-ErrorResponseBody $response
      content_lines = @()
      error = $_.Exception.Message
    }
  }
}

function Get-SymppBackendHealth([string]$BackendUrl) {
  if ([string]::IsNullOrWhiteSpace($BackendUrl)) {
    return [pscustomobject]@{ healthy = $false; source_revision = $null; detail = "missing_url" }
  }

  $mcpUrl = $BackendUrl.TrimEnd("/") + "/mcp"
  $initializeBody = ConvertTo-JsonBody (New-InitializeRequest)
  $init = Invoke-McpPost $mcpUrl $initializeBody $null $null 2
  if (-not $init.ok -or [string]::IsNullOrWhiteSpace($init.content)) {
    return [pscustomobject]@{ healthy = $false; source_revision = $null; detail = "initialize_failed" }
  }

  $sessionId = Get-ResponseHeaderValue $init.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return [pscustomobject]@{ healthy = $false; source_revision = $null; detail = "missing_session_id" }
  }

  $protocolVersion = Get-ResponseProtocolVersion @($init.content_lines)
  if ([string]::IsNullOrWhiteSpace($protocolVersion)) {
    $protocolVersion = Get-InitializeProtocolVersion $initializeBody
  }

  $health = Invoke-McpPost $mcpUrl (ConvertTo-JsonBody (New-HealthRequest)) $sessionId $protocolVersion 2
  $healthLines = @($health.content_lines)
  if (-not $health.ok -or $healthLines.Count -eq 0) {
    return [pscustomobject]@{ healthy = $false; source_revision = $null; detail = "health_failed" }
  }

  try {
    $payload = $healthLines[0] | ConvertFrom-Json
    if ($null -ne $payload.result -and $null -eq $payload.error) {
      return [pscustomobject]@{
        healthy = $true
        source_revision = Get-HealthSourceRevision $payload
        detail = $null
      }
    }

    return [pscustomobject]@{ healthy = $false; source_revision = $null; detail = "health_error" }
  } catch {
    return [pscustomobject]@{ healthy = $false; source_revision = $null; detail = "health_parse_failed" }
  }
}

function Test-HealthySymppBackend([string]$BackendUrl) {
  return (Get-SymppBackendHealth $BackendUrl).healthy
}

function Test-BackendSourceMatches($Health, [string]$ExpectedSourceRevision) {
  if ($null -eq $Health -or -not $Health.healthy) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $false
  }

  return -not [string]::IsNullOrWhiteSpace([string]$Health.source_revision) -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Health.source_revision, $ExpectedSourceRevision)
}

function New-RuntimeKey([string]$BackendUrl, [string]$DashboardOrigin, [string]$SourceRevision) {
  $backend = if ([string]::IsNullOrWhiteSpace($BackendUrl)) { "none" } else { $BackendUrl.TrimEnd("/").ToLowerInvariant() }
  $dashboard = if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) { "none" } else { $DashboardOrigin.TrimEnd("/").ToLowerInvariant() }
  $source = if ([string]::IsNullOrWhiteSpace($SourceRevision)) { "unknown" } else { $SourceRevision.Trim().ToLowerInvariant() }
  return "source=$source;backend=$backend;dashboard=$dashboard"
}

function Get-RuntimeStateKey($State) {
  if ($null -eq $State) {
    return $null
  }

  if ($State.PSObject.Properties["runtime_key"] -and -not [string]::IsNullOrWhiteSpace([string]$State.runtime_key)) {
    return [string]$State.runtime_key
  }

  $sourceRevision = $null
  if ($null -ne $State.backend -and $State.backend.PSObject.Properties["source_revision"]) {
    $sourceRevision = [string]$State.backend.source_revision
  }

  if ($null -eq $State.backend) {
    return $null
  }

  return New-RuntimeKey ([string]$State.backend.url) ([string]$State.frontend.origin) $sourceRevision
}

function Format-SourceRevisionForDiagnostic([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return "unknown"
  }

  return $Revision
}

function Test-HealthySymppDashboard([string]$DashboardOrigin) {
  if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    return $false
  }

  $url = $DashboardOrigin.TrimEnd("/") + $BoardPath
  try {
    $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 -and [string]$response.Content -match "Symphony\+\+ Dashboard"
  } catch {
    return $false
  }
}

function Get-PortFromOrigin([string]$Origin) {
  try {
    $uri = [System.Uri]::new($Origin)
    return [int]$uri.Port
  } catch {
    return $null
  }
}

function Read-RuntimeState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-RuntimeState([string]$Path, $State) {
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $json = $State | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($Path, "$json`n", $utf8NoBom)
}

function Resolve-BridgeLeaseDir([string]$RuntimeFile) {
  return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $RuntimeFile) "codex-plugin-leases"))
}

function New-BridgeLease([string]$RuntimeFile, $BackendPlan, $DashboardPlan, [string]$RuntimeKey) {
  $leaseDir = Resolve-BridgeLeaseDir $RuntimeFile
  New-Item -ItemType Directory -Path $leaseDir -Force | Out-Null
  $leasePath = Join-Path $leaseDir ("bridge-$PID-$([guid]::NewGuid().ToString('N')).json")
  $lease = [pscustomobject]@{
    pid = $PID
    created_at = (Get-Date).ToString("o")
    runtime_key = $RuntimeKey
    runtime_kind = if ($BackendPlan.managed -eq $true) { "managed" } else { [string]$BackendPlan.status }
    source_revision = $BackendPlan.source_revision
    backend_url = $BackendPlan.url
    dashboard_origin = $DashboardPlan.origin
  }
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($leasePath, (($lease | ConvertTo-Json -Depth 8) + "`n"), $utf8NoBom)
  return $leasePath
}

function Remove-BridgeLease([string]$LeasePath) {
  if (-not [string]::IsNullOrWhiteSpace($LeasePath)) {
    Remove-Item -LiteralPath $LeasePath -Force -ErrorAction SilentlyContinue
  }
}

function Get-ProcessCommandLine([int]$ProcessId) {
  if ($ProcessId -le 0) {
    return $null
  }

  $cim = Get-Command Get-CimInstance -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cim) {
    try {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
      if ($process) {
        return [string]$process.CommandLine
      }
    } catch {
    }
  }

  $procCmdline = "/proc/$ProcessId/cmdline"
  if (Test-Path -LiteralPath $procCmdline) {
    try {
      $raw = [System.IO.File]::ReadAllText($procCmdline)
      $text = ($raw -replace [char]0, " ").Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        return $text
      }
    } catch {
    }
  }

  return $null
}

function Test-ProcessAlive([int]$ProcessId) {
  if ($ProcessId -le 0) {
    return $false
  }

  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Test-BridgeLeaseActive($Lease) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["pid"]) {
    return $false
  }

  $leasePid = 0
  if (-not [int]::TryParse([string]$Lease.pid, [ref]$leasePid) -or $leasePid -le 0) {
    return $false
  }

  if (-not (Test-ProcessAlive $leasePid)) {
    return $false
  }

  $commandLine = Get-ProcessCommandLine $leasePid
  return -not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine -match "start-sympp-mcp\.(ps1|cmd)"
}

function Get-ActiveBridgeLeases([string]$RuntimeFile) {
  $leaseDir = Resolve-BridgeLeaseDir $RuntimeFile
  if (-not (Test-Path -LiteralPath $leaseDir -PathType Container)) {
    return @()
  }

  $active = [System.Collections.Generic.List[object]]::new()
  foreach ($leasePath in @(Get-ChildItem -LiteralPath $leaseDir -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue)) {
    $lease = $null
    try {
      $lease = Get-Content -LiteralPath $leasePath.FullName -Raw | ConvertFrom-Json
    } catch {
    }

    if (Test-BridgeLeaseActive $lease) {
      $active.Add([pscustomobject]@{ path = $leasePath.FullName; lease = $lease })
    } else {
      Remove-Item -LiteralPath $leasePath.FullName -Force -ErrorAction SilentlyContinue
    }
  }

  return @($active)
}

function Test-BridgeLeaseMatchesRuntimeKey($Lease, [string]$RuntimeKey) {
  if ($null -eq $Lease -or [string]::IsNullOrWhiteSpace($RuntimeKey)) {
    return $false
  }

  if (-not $Lease.PSObject.Properties["runtime_key"] -or [string]::IsNullOrWhiteSpace([string]$Lease.runtime_key)) {
    return $false
  }

  return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Lease.runtime_key, $RuntimeKey)
}

function Test-ActiveLegacyBridgeLease($ActiveLeases) {
  foreach ($activeLease in @($ActiveLeases)) {
    $lease = $activeLease.lease
    if ($null -eq $lease -or -not $lease.PSObject.Properties["runtime_key"] -or [string]::IsNullOrWhiteSpace([string]$lease.runtime_key)) {
      return $true
    }
  }

  return $false
}

function Test-ActiveBridgeLeaseForRuntimeKey($ActiveLeases, [string]$RuntimeKey) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesRuntimeKey $activeLease.lease $RuntimeKey) {
      return $true
    }
  }

  return $false
}

function Stop-ManagedRuntimeProcess([string]$Role, $ProcessIdValue, [int]$Port) {
  $managedPid = 0
  if (-not [int]::TryParse([string]$ProcessIdValue, [ref]$managedPid) -or $managedPid -le 0) {
    return $false
  }

  $commandLine = Get-ProcessCommandLine $managedPid
  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    Write-Diagnostic "Skipping $Role shutdown for pid=$managedPid because its command line could not be verified."
    return $false
  }

  $rolePattern = if ($Role -eq "backend") { "sympp\.cockpit" } else { "vite" }
  $portPattern = if ($Port -gt 0) { "(--port\s+$Port|--port\s+`"$Port`")" } else { $null }
  if ($commandLine -notmatch $rolePattern -or ($portPattern -and $commandLine -notmatch $portPattern)) {
    Write-Diagnostic "Skipping $Role shutdown for pid=$managedPid because it no longer matches the managed Symphony++ command."
    return $false
  }

  Write-Diagnostic "Stopping managed Symphony++ $Role pid=$managedPid after last Codex MCP bridge exited."
  $process = Get-Process -Id $managedPid -ErrorAction SilentlyContinue
  Stop-Process -Id $managedPid -Force -ErrorAction SilentlyContinue
  if ($process) {
    try {
      [void]$process.WaitForExit(5000)
    } catch {
    }
  }
  return $true
}

function Get-RuntimeEntryPort($Entry) {
  $port = 0
  if ($null -ne $Entry) {
    [void][int]::TryParse([string]$Entry.port, [ref]$port)
  }

  return $port
}

function Stop-ManagedRuntimeEntry([string]$Role, $Entry) {
  if ($null -eq $Entry -or $Entry.managed -ne $true) {
    return $false
  }

  return Stop-ManagedRuntimeProcess $Role $Entry.pid (Get-RuntimeEntryPort $Entry)
}

function Test-RuntimeEntryEndpointMatches([string]$Role, $Entry, [string]$Endpoint) {
  if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($Endpoint)) {
    return $false
  }

  $entryEndpoint = if ($Role -eq "backend") { [string]$Entry.url } else { [string]$Entry.origin }
  return -not [string]::IsNullOrWhiteSpace($entryEndpoint) -and
    $entryEndpoint.TrimEnd("/") -eq $Endpoint.TrimEnd("/")
}

function Test-ManagedRuntimeEntrySuperseded([string]$Role, $Entry, [string]$SelectedEndpoint) {
  if ($null -eq $Entry -or $Entry.managed -ne $true) {
    return $false
  }

  $entryEndpoint = if ($Role -eq "backend") { [string]$Entry.url } else { [string]$Entry.origin }
  if ([string]::IsNullOrWhiteSpace($entryEndpoint)) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($SelectedEndpoint)) {
    return $true
  }

  return $entryEndpoint.TrimEnd("/") -ne $SelectedEndpoint.TrimEnd("/")
}

function Test-PortSelectionAllowsReuse([int]$PreferredPort, [string]$Endpoint, [bool]$EnforcePreferredPort) {
  if (-not $EnforcePreferredPort -or $PreferredPort -eq 0) {
    return $true
  }

  return (Get-PortFromOrigin $Endpoint) -eq $PreferredPort
}

function Test-RuntimeEntryExternalOverride($Entry, [string]$Endpoint, [string]$Role) {
  if ($null -eq $Entry -or [string]$Entry.status -ne "external_override") {
    return $false
  }

  return Test-RuntimeEntryEndpointMatches $Role $Entry $Endpoint
}

function Test-EndpointMatches([string]$RecordedEndpoint, [string]$ExpectedEndpoint) {
  return -not [string]::IsNullOrWhiteSpace($RecordedEndpoint) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedEndpoint) -and
    $RecordedEndpoint.TrimEnd("/") -eq $ExpectedEndpoint.TrimEnd("/")
}

function Test-BridgeLeaseMatchesBackend($Lease, [string]$BackendUrl) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["backend_url"]) {
    return $false
  }

  return Test-EndpointMatches ([string]$Lease.backend_url) $BackendUrl
}

function Test-BridgeLeaseMatchesDashboard($Lease, [string]$DashboardOrigin) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["dashboard_origin"]) {
    return $false
  }

  return Test-EndpointMatches ([string]$Lease.dashboard_origin) $DashboardOrigin
}

function Test-ActiveBridgeLeaseForBackend($ActiveLeases, [string]$BackendUrl) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesBackend $activeLease.lease $BackendUrl) {
      return $true
    }
  }

  return $false
}

function Test-ActiveBridgeLeaseForDashboard($ActiveLeases, [string]$DashboardOrigin) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesDashboard $activeLease.lease $DashboardOrigin) {
      return $true
    }
  }

  return $false
}

function New-SupersededRuntimeState($RuntimeState, $BackendPlan, $DashboardPlan) {
  $backend = $null
  $frontend = $null
  $runtimeKey = $null
  if ($null -ne $RuntimeState) {
    if (Test-ManagedRuntimeEntrySuperseded "backend" $RuntimeState.backend ([string]$BackendPlan.url)) {
      $backend = $RuntimeState.backend
    }
    if (Test-ManagedRuntimeEntrySuperseded "frontend" $RuntimeState.frontend ([string]$DashboardPlan.origin)) {
      $frontend = $RuntimeState.frontend
    }
    if ($null -ne $backend -or $null -ne $frontend) {
      $runtimeKey = Get-RuntimeStateKey $RuntimeState
    }
  }

  return [pscustomobject]@{
    runtime_key = $runtimeKey
    backend = $backend
    frontend = $frontend
  }
}

function Get-SupersededRuntimeKey($Superseded) {
  if ($null -eq $Superseded -or -not $Superseded.PSObject.Properties["runtime_key"]) {
    return $null
  }

  $runtimeKey = [string]$Superseded.runtime_key
  if ([string]::IsNullOrWhiteSpace($runtimeKey)) {
    return $null
  }

  return $runtimeKey
}

function Test-SupersededRuntimeStateHasEntries($Superseded) {
  return $null -ne $Superseded -and ($null -ne $Superseded.backend -or $null -ne $Superseded.frontend)
}

function Get-SupersededRuntimeStates($State) {
  $states = [System.Collections.ArrayList]::new()
  $seen = @{}
  if ($null -eq $State) {
    return @()
  }

  foreach ($entry in @($State.superseded_runtimes)) {
    if (-not (Test-SupersededRuntimeStateHasEntries $entry)) {
      continue
    }

    $runtimeKey = Get-SupersededRuntimeKey $entry
    if (-not [string]::IsNullOrWhiteSpace($runtimeKey)) {
      if ($seen.ContainsKey($runtimeKey)) {
        continue
      }
      $seen[$runtimeKey] = $true
    }

    [void]$states.Add($entry)
  }

  if ($State.PSObject.Properties["superseded"] -and (Test-SupersededRuntimeStateHasEntries $State.superseded)) {
    $runtimeKey = Get-SupersededRuntimeKey $State.superseded
    if ([string]::IsNullOrWhiteSpace($runtimeKey) -or -not $seen.ContainsKey($runtimeKey)) {
      [void]$states.Add($State.superseded)
    }
  }

  return @($states)
}

function Merge-SupersededRuntimeStates($Existing, $Candidate) {
  $states = [System.Collections.ArrayList]::new()
  $seen = @{}
  foreach ($entry in @($Candidate) + @($Existing)) {
    if (-not (Test-SupersededRuntimeStateHasEntries $entry)) {
      continue
    }

    $runtimeKey = Get-SupersededRuntimeKey $entry
    if (-not [string]::IsNullOrWhiteSpace($runtimeKey)) {
      if ($seen.ContainsKey($runtimeKey)) {
        continue
      }
      $seen[$runtimeKey] = $true
    }

    [void]$states.Add($entry)
  }

  return @($states)
}

function Set-SupersededRuntimeStates($State, $SupersededStates) {
  if ($null -eq $State) {
    return
  }

  $states = @($SupersededStates | Where-Object { Test-SupersededRuntimeStateHasEntries $_ })
  $legacyState = if ($states.Count -gt 0) { $states[0] } else { $null }
  $State | Add-Member -NotePropertyName superseded -NotePropertyValue $legacyState -Force
  $State | Add-Member -NotePropertyName superseded_runtimes -NotePropertyValue $states -Force
}

function Stop-SupersededManagedServersIfUnused([string]$RuntimeFile, $Superseded) {
  if ($null -eq $Superseded) {
    return $Superseded
  }

  $activeLeases = @(Get-ActiveBridgeLeases $RuntimeFile)
  if (Test-ActiveLegacyBridgeLease $activeLeases) {
    return $Superseded
  }

  if (-not (Test-ActiveBridgeLeaseForDashboard $activeLeases ([string]$Superseded.frontend.origin)) -and
      (Stop-ManagedRuntimeEntry "frontend" $Superseded.frontend)) {
    $Superseded.frontend = $null
  }
  if (-not (Test-ActiveBridgeLeaseForBackend $activeLeases ([string]$Superseded.backend.url)) -and
      (Stop-ManagedRuntimeEntry "backend" $Superseded.backend)) {
    $Superseded.backend = $null
  }

  return $Superseded
}

function Stop-SupersededRuntimeStatesIfUnused([string]$RuntimeFile, $SupersededStates) {
  $remaining = [System.Collections.ArrayList]::new()
  foreach ($superseded in @($SupersededStates)) {
    $updated = Stop-SupersededManagedServersIfUnused $RuntimeFile $superseded
    if (Test-SupersededRuntimeStateHasEntries $updated) {
      [void]$remaining.Add($updated)
    }
  }

  return @($remaining)
}

function Stop-ManagedRuntimeStateEntries($State, [string]$PreserveBackendUrl = $null, [string]$PreserveDashboardOrigin = $null) {
  $stoppedAny = $false
  if ($null -eq $State) {
    return $false
  }

  $supersededStates = [System.Collections.ArrayList]::new()
  foreach ($superseded in @(Get-SupersededRuntimeStates $State)) {
    if (-not (Test-RuntimeEntryEndpointMatches "frontend" $superseded.frontend $PreserveDashboardOrigin) -and
        (Stop-ManagedRuntimeEntry "frontend" $superseded.frontend)) {
      $superseded.frontend = $null
      $stoppedAny = $true
    }
    if (-not (Test-RuntimeEntryEndpointMatches "backend" $superseded.backend $PreserveBackendUrl) -and
        (Stop-ManagedRuntimeEntry "backend" $superseded.backend)) {
      $superseded.backend = $null
      $stoppedAny = $true
    }
    if (Test-SupersededRuntimeStateHasEntries $superseded) {
      [void]$supersededStates.Add($superseded)
    }
  }
  Set-SupersededRuntimeStates $State $supersededStates

  if (-not (Test-RuntimeEntryEndpointMatches "frontend" $State.frontend $PreserveDashboardOrigin) -and
      (Stop-ManagedRuntimeEntry "frontend" $State.frontend)) {
    $State.frontend.status = "stopped"
    $State.frontend.pid = $null
    $stoppedAny = $true
  }

  if (-not (Test-RuntimeEntryEndpointMatches "backend" $State.backend $PreserveBackendUrl) -and
      (Stop-ManagedRuntimeEntry "backend" $State.backend)) {
    $State.backend.status = "stopped"
    $State.backend.pid = $null
    $stoppedAny = $true
  }

  return $stoppedAny
}

function Stop-CurrentManagedRuntimeStateEntries($State, $ActiveLeases) {
  $stoppedAny = $false
  if ($null -eq $State) {
    return $false
  }

  if (-not (Test-ActiveBridgeLeaseForDashboard $ActiveLeases ([string]$State.frontend.origin)) -and
      (Stop-ManagedRuntimeEntry "frontend" $State.frontend)) {
    $State.frontend.status = "stopped"
    $State.frontend.pid = $null
    $stoppedAny = $true
  }

  if (-not (Test-ActiveBridgeLeaseForBackend $ActiveLeases ([string]$State.backend.url)) -and
      (Stop-ManagedRuntimeEntry "backend" $State.backend)) {
    $State.backend.status = "stopped"
    $State.backend.pid = $null
    $stoppedAny = $true
  }

  return $stoppedAny
}

function Get-ManagedListenerPid([string]$Role, [int]$Port) {
  $rolePattern = if ($Role -eq "backend") { "sympp\.cockpit" } else { "vite" }
  foreach ($owner in @(Get-TcpPortOwners $Port)) {
    $commandLine = Get-ProcessCommandLine ([int]$owner.pid)
    if (-not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine -match $rolePattern) {
      return [int]$owner.pid
    }
  }

  return $null
}

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

  $oldEnvironment = @{}
  foreach ($key in @($Environment.Keys)) {
    $oldEnvironment[$key] = [Environment]::GetEnvironmentVariable([string]$key, "Process")
    [Environment]::SetEnvironmentVariable([string]$key, [string]$Environment[$key], "Process")
  }

  try {
    $process = Start-Process `
      -FilePath $startCommand.file `
      -ArgumentList (Join-ProcessArgumentList @($startCommand.args)) `
      -WorkingDirectory $WorkingDirectory `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -WindowStyle Hidden `
      -PassThru
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

function New-ReusedBackendPlan([string]$Status, [string]$Url, $Health, [bool]$Managed, $Pid) {
  $url = $Url.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    url = $url
    mcp_url = "$url/mcp"
    port = Get-PortFromOrigin $url
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $Pid
    source_revision = $Health.source_revision
  }
}

function Resolve-BackendPlan([int]$PreferredPort, [string]$ConfiguredUrl, $RuntimeState, [int]$PortReleaseTimeoutSec, [string]$ExpectedSourceRevision, [bool]$EnforcePreferredPort, [int[]]$AvoidPorts = @()) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredUrl)) {
    $url = $ConfiguredUrl.TrimEnd("/")
    Assert-LoopbackHttpOrigin $url "SYMPP_BACKEND_URL"
    $health = Get-SymppBackendHealth $url
    if (-not $health.healthy) {
      throw "SYMPP_BACKEND_URL is not a healthy Symphony++ backend: $url"
    }

    return New-ReusedBackendPlan "external_override" $url $health $false $null
  }

  if ($null -ne $RuntimeState -and $null -ne $RuntimeState.backend) {
    $runtimeUrl = [string]$RuntimeState.backend.url
    if (-not [string]::IsNullOrWhiteSpace($runtimeUrl)) {
      $runtimeUrl = $runtimeUrl.TrimEnd("/")
      $runtimeHealth = Get-SymppBackendHealth $runtimeUrl
      $runtimeManaged = $RuntimeState.backend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeUrl $EnforcePreferredPort
      if ($runtimeManaged -and $portAllowed -and $runtimeHealth.healthy -and (Test-BackendSourceMatches $runtimeHealth $ExpectedSourceRevision)) {
        return New-ReusedBackendPlan "reused" $runtimeUrl $runtimeHealth ($RuntimeState.backend.managed -eq $true) $RuntimeState.backend.pid
      }

      if ($runtimeHealth.healthy -and -not (Test-BackendSourceMatches $runtimeHealth $ExpectedSourceRevision)) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because source revision $(Format-SourceRevisionForDiagnostic $runtimeHealth.source_revision) does not match expected $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision)."
      } elseif ($runtimeHealth.healthy -and -not $runtimeManaged) {
        Write-Diagnostic "Ignoring recorded external backend $runtimeUrl for implicit reuse. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      } elseif ($runtimeHealth.healthy -and -not $portAllowed) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because SYMPP_BACKEND_PORT requests $PreferredPort. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      }
    }
  }

  if ($PreferredPort -gt 0) {
    $preferredUrl = "http://127.0.0.1:$PreferredPort"
    $preferredHealth = Get-SymppBackendHealth $preferredUrl
    if ($preferredHealth.healthy) {
      if (Test-RuntimeEntryExternalOverride $RuntimeState.backend $preferredUrl "backend") {
        Write-Diagnostic "Ignoring recorded external backend $preferredUrl for implicit reuse. Set SYMPP_BACKEND_URL=$preferredUrl to reuse it explicitly."
      } elseif (Test-BackendSourceMatches $preferredHealth $ExpectedSourceRevision) {
        return New-ReusedBackendPlan "external_loopback" $preferredUrl $preferredHealth $false $null
      } else {
        Write-Diagnostic "Ignoring healthy Symphony++ backend $preferredUrl because source revision $(Format-SourceRevisionForDiagnostic $preferredHealth.source_revision) does not match expected $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision)."
      }
      $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
    } else {
      $selectedPort = $null
    }
  } else {
    $selectedPort = $null
  }

  if ($null -eq $selectedPort -and $PreferredPort -gt 0) {
    $portRelease = Wait-ForTcpPortRelease $PreferredPort $PortReleaseTimeoutSec
    if (-not $portRelease.released) {
      Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) Selecting a fallback managed backend port for this Codex session."
      $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
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
  }
}

function New-ReusedDashboardPlan([string]$Status, [string]$Origin, [bool]$Managed, $Pid) {
  $origin = $Origin.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    origin = $origin
    url = "$origin$BoardPath"
    port = Get-PortFromOrigin $origin
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $Pid
  }
}

function Resolve-DashboardPlan([int]$PreferredPort, [string]$ConfiguredOrigin, [string]$BackendUrl, $RuntimeState, [bool]$EnforcePreferredPort, [bool]$AllowRecordedRuntimeReuse) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredOrigin)) {
    $origin = $ConfiguredOrigin.TrimEnd("/")
    return New-ReusedDashboardPlan "external_override" $origin $false $null
  }

  if ($AllowRecordedRuntimeReuse -and $null -ne $RuntimeState -and $null -ne $RuntimeState.frontend) {
    $runtimeBackendUrl = [string]$RuntimeState.backend.url
    $runtimeOrigin = [string]$RuntimeState.frontend.origin
    if (-not [string]::IsNullOrWhiteSpace($runtimeBackendUrl) -and
        $runtimeBackendUrl.TrimEnd("/") -eq $BackendUrl.TrimEnd("/")) {
      $runtimeManaged = $RuntimeState.frontend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeOrigin $EnforcePreferredPort
      if ($runtimeManaged -and $portAllowed -and -not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
        return New-ReusedDashboardPlan "reused" $runtimeOrigin ($RuntimeState.frontend.managed -eq $true) $RuntimeState.frontend.pid
      }
      if (-not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
        if (-not $runtimeManaged) {
          Write-Diagnostic "Ignoring recorded external dashboard $($runtimeOrigin.TrimEnd('/')) for implicit reuse. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        } elseif (-not $portAllowed) {
          Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because SYMPP_DASHBOARD_PORT requests $PreferredPort. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        }
      }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
      Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because it was recorded for backend $($runtimeBackendUrl.TrimEnd('/')), not $($BackendUrl.TrimEnd('/'))."
    }
  }

  $backendPort = Get-PortFromOrigin $BackendUrl
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
  Write-Diagnostic "Ensuring Symphony++ Elixir dependencies are available in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("deps.get", "--check-locked") "elixir-deps" $LogDir $TimeoutSec

  Write-Diagnostic "Compiling Symphony++ Elixir runtime in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("compile") "elixir-compile" $LogDir $TimeoutSec
}

function Start-Backend($Plan, [string]$DashboardOrigin, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec) {
  $args = @("sympp.cockpit", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $args += @("--dashboard-origin", $DashboardOrigin)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $args += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $args
  $launch = Start-LoggedProcess $command.file $command.args $ElixirDir @{} "backend-$($Plan.port)" $LogDir
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

  $health = Get-SymppBackendHealth $Plan.url
  $listenerPid = Get-ManagedListenerPid "backend" ([int]$Plan.port)
  return [pscustomobject]@{
    pid = if ($listenerPid) { $listenerPid } else { $launch.process.Id }
    stdout = $launch.stdout
    stderr = $launch.stderr
    source_revision = if ($health.healthy) { $health.source_revision } else { $null }
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

function Invoke-DirectStdioMcp([string]$RepoRoot, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand) {
  $mcpArgs = @("sympp.mcp", "--mode", "stdio", "--repo-root", $RepoRoot)
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $mcpArgs += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  Set-Location -LiteralPath $ElixirDir
  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $mcpArgs
  & $command.file @($command.args)
  exit $LASTEXITCODE
}

function Invoke-SelfTest {
  if ((Select-AvailablePort 0) -le 0) {
    throw "Select-AvailablePort did not return an ephemeral port."
  }
  $preferredForAvoidTest = Select-AvailablePort 0
  $fallbackForAvoidTest = Select-AvailablePort $preferredForAvoidTest @($preferredForAvoidTest, ($preferredForAvoidTest + 1))
  if ($fallbackForAvoidTest -eq $preferredForAvoidTest -or $fallbackForAvoidTest -eq ($preferredForAvoidTest + 1)) {
    throw "Select-AvailablePort did not honor avoided fallback ports."
  }

  $headers = [System.Net.WebHeaderCollection]::new()
  $headers.Add("Mcp-Session-Id", "session-one")
  if ((Get-ResponseHeaderValue $headers "mcp-session-id") -ne "session-one") {
    throw "Get-ResponseHeaderValue did not read WebHeaderCollection values case-insensitively."
  }

  if ((Test-EnvDisabled "__SYMPP_SELFTEST_MISSING__") -ne $false) {
    throw "Test-EnvDisabled should treat missing variables as enabled/default."
  }

  $old = [Environment]::GetEnvironmentVariable("SYMPP_SELFTEST_FLAG", "Process")
  try {
    [Environment]::SetEnvironmentVariable("SYMPP_SELFTEST_FLAG", "off", "Process")
    if (-not (Test-EnvDisabled "SYMPP_SELFTEST_FLAG")) {
      throw "Test-EnvDisabled did not treat 'off' as disabled."
    }
  } finally {
    [Environment]::SetEnvironmentVariable("SYMPP_SELFTEST_FLAG", $old, "Process")
  }

  $wrapped = Get-StartProcessCommand "C:\Tools\mix.ps1" @("sympp.cockpit")
  if ($wrapped.file -notmatch "^(pwsh|powershell(\.exe)?)$" -or $wrapped.args[4] -ne "C:\Tools\mix.ps1") {
    throw "Get-StartProcessCommand did not wrap PowerShell scripts for Start-Process."
  }

  $joinedArgs = Join-ProcessArgumentList @("--database", "C:\Users\Jane Doe\ledger db.sqlite3", 'value"withquote')
  if ($joinedArgs -notmatch '"C:\\Users\\Jane Doe\\ledger db\.sqlite3"' -or $joinedArgs -notmatch '"value\\"withquote"') {
    throw "Join-ProcessArgumentList did not preserve spaced or quoted arguments."
  }

  Assert-LoopbackHttpOrigin "http://127.0.0.1:19998" "SYMPP_BACKEND_URL"
  $rejectedRemoteOrigin = $false
  try {
    Assert-LoopbackHttpOrigin "http://example.com:19998" "SYMPP_BACKEND_URL"
  } catch {
    $rejectedRemoteOrigin = $true
  }
  if (-not $rejectedRemoteOrigin) {
    throw "Assert-LoopbackHttpOrigin did not reject a remote backend URL."
  }

  $freePortRelease = Wait-ForTcpPortRelease (Select-AvailablePort 0) 0
  if (-not $freePortRelease.released) {
    throw "Wait-ForTcpPortRelease did not recognize a free port."
  }

  $occupiedListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
  try {
    $occupiedListener.Start()
    $occupiedPort = [int]$occupiedListener.LocalEndpoint.Port
    $occupiedRelease = Wait-ForTcpPortRelease $occupiedPort 0
    if ($occupiedRelease.released) {
      throw "Wait-ForTcpPortRelease did not detect an occupied port."
    }

    $occupiedMessage = New-BackendPortOccupiedMessage $occupiedPort @($occupiedRelease.owners)
    if ($occupiedMessage -notmatch "backend_port_occupied" -or $occupiedMessage -notmatch [string]$occupiedPort) {
      throw "New-BackendPortOccupiedMessage did not include the status code and port."
    }
  } finally {
    $occupiedListener.Stop()
  }

  $processLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "sympp-plugin-selftest-process-logs"
  $sleepLaunch = $null
  try {
    $sleepLaunch = Start-LoggedProcess `
      (Get-PowerShellHostCommandName) `
      @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") `
      ([System.IO.Path]::GetTempPath()) `
      @{} `
      "sleep" `
      $processLogDir
    if ($sleepLaunch.process.HasExited) {
      throw "Self-test process exited before Stop-LoggedProcess could stop it."
    }

    Stop-LoggedProcess $sleepLaunch
    if (-not $sleepLaunch.process.HasExited) {
      throw "Stop-LoggedProcess did not terminate the self-test process."
    }
  } finally {
    Stop-LoggedProcess $sleepLaunch
    Remove-Item -LiteralPath $processLogDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  $sseHeaders = @{ "Content-Type" = "text/event-stream; charset=utf-8" }
  $sseContent = "event: message`ndata: {`"jsonrpc`":`"2.0`",`"id`":1,`"result`":{}}`n`n"
  $sseLines = @(Convert-McpHttpContentToJsonLines $sseContent $sseHeaders)
  if ($sseLines.Count -ne 1 -or ($sseLines[0] | ConvertFrom-Json).id -ne 1) {
    throw "SSE MCP response content did not normalize to JSON-RPC lines."
  }

  $sseWebHeaders = [System.Net.WebHeaderCollection]::new()
  $sseWebHeaders.Add("Content-Type", "text/event-stream; charset=utf-8")
  $sseWebHeaderLines = @(Convert-McpHttpContentToJsonLines $sseContent $sseWebHeaders)
  if ($sseWebHeaderLines.Count -ne 1 -or ($sseWebHeaderLines[0] | ConvertFrom-Json).id -ne 1) {
    throw "SSE MCP response WebHeaderCollection content did not normalize to JSON-RPC lines."
  }

  $initializeBody = ConvertTo-JsonBody (New-InitializeRequest)
  if ((Get-InitializeProtocolVersion $initializeBody) -ne "2025-03-26") {
    throw "Initialize protocol version extraction failed."
  }
  $initializeResponse = '{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18"}}'
  if ((Get-ResponseProtocolVersion @($initializeResponse)) -ne "2025-06-18") {
    throw "Response protocol version extraction failed."
  }

  $revisionA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  $revisionB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  $healthyA = [pscustomobject]@{ healthy = $true; source_revision = $revisionA }
  if (-not (Test-BackendSourceMatches $healthyA $revisionA)) {
    throw "Source-matching backend health should be reusable."
  }
  if (Test-BackendSourceMatches $healthyA $revisionB) {
    throw "Stale backend source revision should not be reusable."
  }
  if (Test-BackendSourceMatches $healthyA $null) {
    throw "Backend source matching should fail closed when the expected source revision is unknown."
  }
  if (Test-BackendSourceMatches ([pscustomobject]@{ healthy = $false; source_revision = $revisionA }) $revisionA) {
    throw "Unhealthy backend should not be reusable."
  }

  $runtimeKeyA = New-RuntimeKey "http://127.0.0.1:45678/" "http://127.0.0.1:45679/" $revisionA
  $runtimeKeyANormalized = New-RuntimeKey "http://127.0.0.1:45678" "http://127.0.0.1:45679" $revisionA
  if ($runtimeKeyA -ne $runtimeKeyANormalized -or $runtimeKeyA -notmatch $revisionA) {
    throw "Runtime keys should normalize endpoint slashes and include the source revision."
  }
  if (-not (Test-PortSelectionAllowsReuse 19998 "http://127.0.0.1:20000" $false)) {
    throw "Implicit port selection should allow existing managed runtime reuse."
  }
  if (Test-PortSelectionAllowsReuse 19998 "http://127.0.0.1:20000" $true) {
    throw "Explicit backend/dashboard port selection should block reuse from another port."
  }
  $externalOverrideEntry = [pscustomobject]@{ status = "external_override"; url = "http://127.0.0.1:19998" }
  if (-not (Test-RuntimeEntryExternalOverride $externalOverrideEntry "http://127.0.0.1:19998/" "backend")) {
    throw "Recorded external override entries should be identifiable by endpoint."
  }
  if (Test-RuntimeEntryExternalOverride $externalOverrideEntry "http://127.0.0.1:20000" "backend") {
    throw "Recorded external override entries should not match different endpoints."
  }

  $oldRuntimeKey = New-RuntimeKey "http://127.0.0.1:19998" "http://127.0.0.1:19999" $revisionA
  $oldRuntimeState = [pscustomobject]@{
    runtime_key = $oldRuntimeKey
    backend = [pscustomobject]@{
      managed = $true
      url = "http://127.0.0.1:19998"
      port = 19998
      pid = 1234
      source_revision = $revisionA
    }
    frontend = [pscustomobject]@{
      managed = $true
      origin = "http://127.0.0.1:19999"
      port = 19999
      pid = 1235
    }
  }
  $newBackendPlan = [pscustomobject]@{ url = "http://127.0.0.1:20000" }
  $newDashboardPlan = [pscustomobject]@{ origin = "http://127.0.0.1:20001" }
  $superseded = New-SupersededRuntimeState $oldRuntimeState $newBackendPlan $newDashboardPlan
  if ($null -eq $superseded.backend -or $null -eq $superseded.frontend) {
    throw "Superseded managed runtime entries should be preserved for cleanup."
  }
  if ($superseded.runtime_key -ne $oldRuntimeKey) {
    throw "Superseded runtime state should retain the old runtime key for key-scoped cleanup."
  }
  $olderRuntimeKey = New-RuntimeKey "http://127.0.0.1:19996" "http://127.0.0.1:19997" $revisionA
  $olderSuperseded = [pscustomobject]@{
    runtime_key = $olderRuntimeKey
    backend = [pscustomobject]@{ managed = $true; url = "http://127.0.0.1:19996"; port = 19996; pid = 4321 }
    frontend = [pscustomobject]@{ managed = $true; origin = "http://127.0.0.1:19997"; port = 19997; pid = 4322 }
  }
  $mergedSuperseded = @(Merge-SupersededRuntimeStates @($olderSuperseded) $superseded)
  if ($mergedSuperseded.Count -ne 2 -or $mergedSuperseded[0].runtime_key -ne $oldRuntimeKey -or $mergedSuperseded[1].runtime_key -ne $olderRuntimeKey) {
    throw "Superseded runtime merge should retain multiple old runtime keys newest-first."
  }
  $mergedState = [pscustomobject]@{}
  Set-SupersededRuntimeStates $mergedState $mergedSuperseded
  if (@($mergedState.superseded_runtimes).Count -ne 2 -or $mergedState.superseded.runtime_key -ne $oldRuntimeKey) {
    throw "Superseded runtime state should expose both list and newest legacy field."
  }
  if (-not (Test-RuntimeEntryEndpointMatches "backend" $oldRuntimeState.backend "http://127.0.0.1:19998/")) {
    throw "Runtime backend endpoint matching should normalize trailing slashes."
  }
  if (-not (Test-RuntimeEntryEndpointMatches "frontend" $oldRuntimeState.frontend "http://127.0.0.1:19999/")) {
    throw "Runtime frontend endpoint matching should normalize trailing slashes."
  }

  $runtimePath = Join-Path ([System.IO.Path]::GetTempPath()) "sympp-plugin-selftest-runtime.json"
  $state = [pscustomobject]@{
    runtime_key = $oldRuntimeKey
    backend = [pscustomobject]@{
      status = "reused"
      managed = $false
      url = "http://127.0.0.1:$DefaultBackendPort"
      source_revision = $revisionA
    }
    frontend = [pscustomobject]@{ origin = "http://127.0.0.1:$DefaultDashboardPort" }
  }
  Write-RuntimeState $runtimePath $state
  $read = Read-RuntimeState $runtimePath
  if ($read.backend.url -ne $state.backend.url) {
    throw "Runtime state did not round-trip."
  }

  $leasePath = New-BridgeLease $runtimePath $state.backend $state.frontend $oldRuntimeKey
  $activeLeases = @(Get-ActiveBridgeLeases $runtimePath)
  if ($activeLeases.Count -ne 1 -or $activeLeases[0].path -ne $leasePath) {
    throw "Bridge lease did not appear active for the current launcher process."
  }
  if (-not (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases $oldRuntimeKey)) {
    throw "Bridge lease should be discoverable by runtime key."
  }
  if (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases (New-RuntimeKey "http://127.0.0.1:20000" "http://127.0.0.1:20001" $revisionB)) {
    throw "Bridge lease should not match a different runtime key."
  }
  if (-not (Test-ActiveBridgeLeaseForBackend $activeLeases $state.backend.url)) {
    throw "Bridge lease should keep shared backend runtime entries alive."
  }
  if (-not (Test-ActiveBridgeLeaseForDashboard $activeLeases $state.frontend.origin)) {
    throw "Bridge lease should keep shared dashboard runtime entries alive."
  }
  if (Test-ActiveBridgeLeaseForDashboard $activeLeases "http://127.0.0.1:29999") {
    throw "Bridge lease should not match a different dashboard endpoint."
  }
  Remove-BridgeLease $leasePath
  $activeAfterRemove = @(Get-ActiveBridgeLeases $runtimePath)
  if ($activeAfterRemove.Count -ne 0) {
    throw "Bridge lease cleanup did not remove the current launcher lease."
  }
  $staleLeaseDir = Resolve-BridgeLeaseDir $runtimePath
  New-Item -ItemType Directory -Path $staleLeaseDir -Force | Out-Null
  $staleLeasePath = Join-Path $staleLeaseDir "bridge-0-stale.json"
  Set-Content -LiteralPath $staleLeasePath -Value '{"pid":0}' -NoNewline
  $activeAfterStale = @(Get-ActiveBridgeLeases $runtimePath)
  if ($activeAfterStale.Count -ne 0 -or (Test-Path -LiteralPath $staleLeasePath)) {
    throw "Stale bridge leases were not pruned."
  }

  Remove-Item -LiteralPath $runtimePath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Resolve-BridgeLeaseDir $runtimePath) -Recurse -Force -ErrorAction SilentlyContinue

  Write-Host "Symphony++ MCP launcher self-test passed."
}

if ($Help) {
  Write-Usage
  exit 0
}

if ($SelfTest) {
  Invoke-SelfTest
  exit 0
}

$repoRoot = Resolve-RepoRoot
$elixirDir = Join-Path $repoRoot "elixir"
$assetsDir = Join-Path $elixirDir "assets"
$mix = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MIX)) { "mix" } else { $env:SYMPP_MIX }
$mise = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MISE)) { "mise" } else { $env:SYMPP_MISE }
$defaultLauncher = Resolve-SymppDefaultLauncher $elixirDir $mise
$launcher = Get-EnvMode "SYMPP_LAUNCHER" $defaultLauncher @("direct", "mise")
$defaultMixBuildRoot = Resolve-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp"
if (-not $ValidateOnly) {
  Set-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp"
}
$runtimeFile = Resolve-RuntimeFile
$logDir = Resolve-LogDir

if ($ValidateOnly) {
  Assert-LauncherAvailable $launcher $mix $mise
  Set-Location -LiteralPath $elixirDir
  $validationExitCode = Test-LauncherVersion $launcher $mix $mise
  if ($validationExitCode -ne 0) {
    throw "Selected Symphony++ MCP launcher failed validation with exit code $validationExitCode."
  }

  Write-Host "Symphony++ MCP launcher validation passed."
  Write-Host "  repoRoot: $repoRoot"
  Write-Host "  elixirDir: $elixirDir"
  Write-Host "  assetsDir: $assetsDir"
  Write-Host "  launcher: $launcher"
  Write-Host "  mixBuildRoot: $defaultMixBuildRoot"
  Write-Host "  runtimeFile: $runtimeFile"
  Write-Host "  logDir: $logDir"
  if (Test-NpmAvailable) {
    Write-Host "  dashboardLauncher: available"
  } else {
    Write-Host "  dashboardLauncher: unavailable (MCP bridge can still start; dashboard autostart will be recorded as failed)"
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    Write-Host "  database: $([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE))"
  }
  exit 0
}

$elixirSetupTimeout = Get-EnvInteger "SYMPP_ELIXIR_SETUP_TIMEOUT_SEC" 300 1 1800
$bridgeMode = Get-EnvMode "SYMPP_MCP_BRIDGE_MODE" "http" @("http", "direct_stdio")
if ($bridgeMode -eq "direct_stdio") {
  [void](Initialize-ElixirRuntime $elixirDir $launcher $mix $mise $logDir $elixirSetupTimeout)
  Invoke-DirectStdioMcp $repoRoot $elixirDir $launcher $mix $mise
  exit 0
}

$autostartServers = -not (Test-EnvDisabled "SYMPP_AUTOSTART_SERVERS")
$autostartBackend = $autostartServers -and -not (Test-EnvDisabled "SYMPP_AUTOSTART_BACKEND")
$autostartFrontend = $autostartServers -and -not (Test-EnvDisabled "SYMPP_AUTOSTART_FRONTEND")
$backendPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_BACKEND_PORT)
$dashboardPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_PORT)
$backendPort = Get-EnvInteger "SYMPP_BACKEND_PORT" $DefaultBackendPort 0 65535
$dashboardPort = Get-EnvInteger "SYMPP_DASHBOARD_PORT" $DefaultDashboardPort 0 65535
$backendTimeout = Get-EnvInteger "SYMPP_BACKEND_STARTUP_TIMEOUT_SEC" 60 1 600
$backendPortReleaseTimeout = Get-EnvInteger "SYMPP_BACKEND_PORT_RELEASE_TIMEOUT_SEC" 15 0 600
$frontendInstallTimeout = Get-EnvInteger "SYMPP_FRONTEND_INSTALL_TIMEOUT_SEC" 180 1 1800
$frontendTimeout = Get-EnvInteger "SYMPP_FRONTEND_STARTUP_TIMEOUT_SEC" 20 1 600
$bridgeTimeout = Get-EnvInteger "SYMPP_MCP_HTTP_TIMEOUT_SEC" 300 1 3600
$startupLockMinimum = 30
if ($autostartBackend) {
  $startupLockMinimum += ($elixirSetupTimeout * 2)
  $startupLockMinimum += $backendTimeout
  $startupLockMinimum += $backendPortReleaseTimeout
}
if ($autostartFrontend) {
  $startupLockMinimum += $frontendInstallTimeout
  $startupLockMinimum += $frontendTimeout
}
$startupLockDefault = [Math]::Min(1800, [Math]::Max(120, $startupLockMinimum))
$startupLockTimeout = Get-EnvInteger "SYMPP_STARTUP_LOCK_TIMEOUT_SEC" $startupLockDefault 1 1800
if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_STARTUP_LOCK_TIMEOUT_SEC) -and $startupLockTimeout -lt $startupLockMinimum) {
  throw "SYMPP_STARTUP_LOCK_TIMEOUT_SEC must be at least $startupLockMinimum for the configured backend/frontend startup waits."
}

$backendLaunch = $null
$frontendLaunch = $null
$frontendInstall = $null
$frontendError = $null
$backendPlan = $null
$dashboardPlan = $null
$bridgeLeasePath = $null
$runtimeKey = $null
$supersededStates = @()
$expectedSourceRevision = Resolve-SymppSourceRevision $repoRoot
$startupLock = Enter-FileLock (Resolve-StartupLockFile $runtimeFile) $startupLockTimeout
try {
  $runtimeState = Read-RuntimeState $runtimeFile
  $activeLeasesAtStart = @(Get-ActiveBridgeLeases $runtimeFile)
  if ($activeLeasesAtStart.Count -eq 0 -and $null -ne $runtimeState -and $null -ne $runtimeState.backend) {
    $runtimeHealth = Get-SymppBackendHealth ([string]$runtimeState.backend.url)
    $preserveBackendUrl = if ([string]::IsNullOrWhiteSpace($env:SYMPP_BACKEND_URL)) { $null } else { $env:SYMPP_BACKEND_URL.TrimEnd("/") }
    $preserveDashboardOrigin = if ([string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_ORIGIN)) { $null } else { $env:SYMPP_DASHBOARD_ORIGIN.TrimEnd("/") }
    if (-not (Test-BackendSourceMatches $runtimeHealth $expectedSourceRevision) -and
        (Stop-ManagedRuntimeStateEntries $runtimeState $preserveBackendUrl $preserveDashboardOrigin)) {
      Write-RuntimeState $runtimeFile $runtimeState
    }
  }

  $backendPlan = Resolve-BackendPlan $backendPort $env:SYMPP_BACKEND_URL $runtimeState $backendPortReleaseTimeout $expectedSourceRevision $backendPortExplicit @($dashboardPort)
  if ($backendPlan.should_start -and -not $autostartBackend) {
    throw "Backend autostart is disabled and no reusable Symphony++ backend was found at $($backendPlan.url)."
  }

  $allowRecordedDashboardReuse = $backendPlan.managed -eq $true -and [string]$backendPlan.status -eq "reused"
  $dashboardPlan = Resolve-DashboardPlan $dashboardPort $env:SYMPP_DASHBOARD_ORIGIN $backendPlan.url $runtimeState $dashboardPortExplicit $allowRecordedDashboardReuse
  if ($dashboardPlan.should_start -and -not $autostartFrontend) {
    $dashboardPlan = [pscustomobject]@{
      status = "disabled"
      origin = $null
      url = $null
      port = $null
      should_start = $false
      reused = $false
    }
  }

  $supersededStates = Merge-SupersededRuntimeStates (Get-SupersededRuntimeStates $runtimeState) (New-SupersededRuntimeState $runtimeState $backendPlan $dashboardPlan)
  $supersededStates = Stop-SupersededRuntimeStatesIfUnused $runtimeFile $supersededStates

  if ($backendPlan.should_start) {
    [void](Initialize-ElixirRuntime $elixirDir $launcher $mix $mise $logDir $elixirSetupTimeout)
    $backendLaunch = Start-Backend $backendPlan $dashboardPlan.origin $elixirDir $launcher $mix $mise $logDir $backendTimeout
    $backendPlan.status = "started"
    $backendPlan.pid = $backendLaunch.pid
    $backendPlan.source_revision = $backendLaunch.source_revision
  }

  if ($dashboardPlan.should_start) {
    try {
      $frontendInstall = Install-FrontendDependencies $assetsDir $logDir $frontendInstallTimeout
      $frontendLaunch = Start-Frontend $dashboardPlan $backendPlan.url $assetsDir $logDir $frontendTimeout
      $dashboardPlan.status = "started"
      $dashboardPlan.pid = $frontendLaunch.pid
    } catch {
      $frontendError = $_.Exception.Message
      $dashboardPlan.status = "failed"
      Write-Diagnostic "Symphony++ dashboard autostart failed; MCP bridge will continue. detail=$frontendError"
    }
  }

  $runtimeSourceRevision = if ([string]::IsNullOrWhiteSpace([string]$backendPlan.source_revision)) { $expectedSourceRevision } else { [string]$backendPlan.source_revision }
  $runtimeKey = New-RuntimeKey $backendPlan.url $dashboardPlan.origin $runtimeSourceRevision
  $state = [pscustomobject]@{
    generated_at = (Get-Date).ToString("o")
    repo_root = $repoRoot
    plugin_root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    mcp_transport = "stdio_to_http_bridge"
    runtime_key = $runtimeKey
    runtime_kind = if ($backendPlan.managed -eq $true) { "managed" } else { [string]$backendPlan.status }
    backend = [pscustomobject]@{
      status = $backendPlan.status
      url = $backendPlan.url
      mcp_url = $backendPlan.mcp_url
      port = $backendPlan.port
      reused = $backendPlan.reused
      managed = $backendPlan.managed -eq $true
      pid = $backendPlan.pid
      expected_source_revision = $expectedSourceRevision
      source_revision = $backendPlan.source_revision
      stdout_log = if ($backendLaunch) { $backendLaunch.stdout } else { $null }
      stderr_log = if ($backendLaunch) { $backendLaunch.stderr } else { $null }
    }
    frontend = [pscustomobject]@{
      status = $dashboardPlan.status
      origin = $dashboardPlan.origin
      url = $dashboardPlan.url
      port = $dashboardPlan.port
      reused = $dashboardPlan.reused
      managed = $dashboardPlan.managed -eq $true
      pid = $dashboardPlan.pid
      install_stdout_log = if ($frontendInstall) { $frontendInstall.stdout } else { $null }
      install_stderr_log = if ($frontendInstall) { $frontendInstall.stderr } else { $null }
      stdout_log = if ($frontendLaunch) { $frontendLaunch.stdout } else { $null }
      stderr_log = if ($frontendLaunch) { $frontendLaunch.stderr } else { $null }
      error = $frontendError
    }
    controls = [pscustomobject]@{
      backend_port_env = "SYMPP_BACKEND_PORT"
      dashboard_port_env = "SYMPP_DASHBOARD_PORT"
      backend_url_env = "SYMPP_BACKEND_URL"
      dashboard_origin_env = "SYMPP_DASHBOARD_ORIGIN"
      autostart_env = "SYMPP_AUTOSTART_SERVERS"
      bridge_mode_env = "SYMPP_MCP_BRIDGE_MODE"
    }
    superseded = if ($supersededStates.Count -gt 0) { $supersededStates[0] } else { $null }
    superseded_runtimes = $supersededStates
  }
  Write-RuntimeState $runtimeFile $state
  $bridgeLeasePath = New-BridgeLease $runtimeFile $backendPlan $dashboardPlan $runtimeKey

  $dashboardSummary = if ($dashboardPlan.url) { "$($dashboardPlan.url) [$($dashboardPlan.status)]" } else { $dashboardPlan.status }
  Write-Diagnostic "Symphony++ MCP bridge ready: backend=$($backendPlan.url) dashboard=$dashboardSummary runtime=$runtimeFile"
} finally {
  Exit-FileLock $startupLock
}
try {
  Invoke-HttpMcpBridge $backendPlan.mcp_url $bridgeTimeout
} finally {
  Remove-BridgeLease $bridgeLeasePath
  Stop-ManagedServersIfUnused $runtimeFile $runtimeKey
}
