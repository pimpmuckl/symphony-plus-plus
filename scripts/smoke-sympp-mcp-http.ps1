param(
  [string]$Url = "http://127.0.0.1:4057/mcp",
  [switch]$Json,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$ExpectedTools = @(
  "sympp.health",
  "solo_attach",
  "solo_append",
  "solo_show",
  "solo_list",
  "solo_update_status",
  "claim_work_key"
)

function New-SmokeResult([string]$Status, [string]$Message, [hashtable]$Data = @{}) {
  $result = [ordered]@{
    status = $Status
    message = $Message
    url = $Url
  }

  foreach ($key in $Data.Keys) {
    $result[$key] = $Data[$key]
  }

  return [pscustomobject]$result
}

function Write-SmokeResult($Result, [int]$ExitCode) {
  if ($Json) {
    $Result | ConvertTo-Json -Depth 12
  }
  elseif ($ExitCode -eq 0) {
    Write-Host "OK: $($Result.message)"
    if ($Result.PSObject.Properties["tools"]) {
      Write-Host "Tools: $($Result.tools -join ', ')"
    }
  }
  else {
    [Console]::Error.WriteLine($Result.message)
  }

  exit $ExitCode
}

function ConvertTo-JsonBody([hashtable]$Payload) {
  return $Payload | ConvertTo-Json -Depth 12 -Compress
}

function New-InitializeRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-init"
    method = "initialize"
    params = @{
      protocolVersion = "2025-03-26"
      clientInfo = @{
        name = "sympp-http-smoke"
        version = "0.1.0"
      }
      capabilities = @{}
    }
  }
}

function New-ToolsListRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-tools"
    method = "tools/list"
    params = @{}
  }
}

function Get-ResponseHeaderValue($Headers, [string]$Name) {
  if ($null -eq $Headers) {
    return $null
  }

  $rawValue = $null
  if ($Headers -is [System.Net.WebHeaderCollection]) {
    $rawValue = $Headers[$Name]
  }
  elseif ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in $Headers.Keys) {
      if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rawValue = $Headers[$key]
        break
      }
    }
  }
  else {
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
      }
      finally {
        $reader.Dispose()
      }
    }

    if ($Response.PSObject.Properties["Content"] -and $Response.Content) {
      return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  }
  catch {
    return $null
  }

  return $null
}

function Invoke-McpPost([string]$TargetUrl, [hashtable]$Payload, [string]$SessionId) {
  $headers = @{
    Accept = "application/json"
  }

  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $headers["Mcp-Session-Id"] = [string]$SessionId
  }

  try {
    $response = Invoke-WebRequest `
      -Uri $TargetUrl `
      -Method Post `
      -Headers $headers `
      -ContentType "application/json" `
      -Body (ConvertTo-JsonBody $Payload) `
      -TimeoutSec 10 `
      -UseBasicParsing `
      -ErrorAction Stop

    return [pscustomobject]@{
      ok = $true
      statusCode = [int]$response.StatusCode
      headers = $response.Headers
      content = [string]$response.Content
      error = $null
    }
  }
  catch {
    $response = $_.Exception.Response
    $statusCode = $null
    if ($null -ne $response) {
      try {
        $statusCode = [int]$response.StatusCode
      }
      catch {
        $statusCode = $null
      }
    }

    return [pscustomobject]@{
      ok = $false
      statusCode = $statusCode
      headers = if ($null -ne $response) { $response.Headers } else { $null }
      content = Read-ErrorResponseBody $response
      error = $_.Exception.Message
    }
  }
}

function ConvertFrom-JsonResponse([string]$Content, [string]$Stage) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    throw "$Stage returned an empty response body."
  }

  try {
    return $Content | ConvertFrom-Json
  }
  catch {
    throw "$Stage returned non-JSON response: $($_.Exception.Message)"
  }
}

function Get-JsonRpcErrorMessage($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["error"]) {
    return $null
  }

  $errorObject = $Payload.error
  $reason = $null
  if ($errorObject.PSObject.Properties["data"] -and $errorObject.data.PSObject.Properties["reason"]) {
    $reason = [string]$errorObject.data.reason
  }

  if ($reason) {
    return "$($errorObject.message): $reason"
  }

  return [string]$errorObject.message
}

function Get-ResponseErrorDetail($Response, [string]$Fallback) {
  if (-not [string]::IsNullOrWhiteSpace($Response.content)) {
    try {
      $payload = $Response.content | ConvertFrom-Json
      $jsonRpcError = Get-JsonRpcErrorMessage $payload
      if (-not [string]::IsNullOrWhiteSpace($jsonRpcError)) {
        return $jsonRpcError
      }
    }
    catch {
      return $Response.content
    }
  }

  return $Fallback
}

function Get-ToolNames($ToolsPayload) {
  $tools = $ToolsPayload.result.tools
  if ($null -eq $tools) {
    return @()
  }

  return @($tools | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Invoke-McpSmoke {
  $initResponse = Invoke-McpPost $Url (New-InitializeRequest) $null
  if (-not $initResponse.ok) {
    if ($initResponse.statusCode) {
      return New-SmokeResult "initialize_failed" "MCP initialize failed with HTTP $($initResponse.statusCode): $($initResponse.error)"
    }

    return New-SmokeResult "endpoint_unreachable" "Could not reach local MCP endpoint at $Url`: $($initResponse.error)"
  }

  $initPayload = ConvertFrom-JsonResponse $initResponse.content "initialize"
  $initError = Get-JsonRpcErrorMessage $initPayload
  if ($initError) {
    return New-SmokeResult "initialize_failed" "MCP initialize failed: $initError"
  }

  $sessionId = Get-ResponseHeaderValue $initResponse.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return New-SmokeResult "missing_session_id" "MCP initialize succeeded but did not return Mcp-Session-Id."
  }

  $toolsResponse = Invoke-McpPost $Url (New-ToolsListRequest) $sessionId
  if (-not $toolsResponse.ok) {
    $reason = if ($toolsResponse.statusCode) { "HTTP $($toolsResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $toolsResponse $toolsResponse.error
    return New-SmokeResult "tools_list_failed" "MCP tools/list failed with initialized session ($reason): $detail"
  }

  $toolsSessionId = Get-ResponseHeaderValue $toolsResponse.headers "Mcp-Session-Id"
  if ($toolsSessionId -ne $sessionId) {
    $actual = if ([string]::IsNullOrWhiteSpace($toolsSessionId)) { "<missing>" } else { $toolsSessionId }
    return New-SmokeResult "session_id_mismatch" "MCP tools/list did not echo the initialized Mcp-Session-Id. expected=$sessionId actual=$actual"
  }

  $toolsPayload = ConvertFrom-JsonResponse $toolsResponse.content "tools/list"
  $toolsError = Get-JsonRpcErrorMessage $toolsPayload
  if ($toolsError) {
    return New-SmokeResult "tools_list_failed" "MCP tools/list returned JSON-RPC error: $toolsError"
  }

  $toolNames = Get-ToolNames $toolsPayload
  $missingTools = @($ExpectedTools | Where-Object { $toolNames -notcontains $_ })
  if ($missingTools.Count -gt 0) {
    return New-SmokeResult "missing_expected_tools" "MCP tools/list is missing expected unbound tools: $($missingTools -join ', ')." @{
      tools = $toolNames
      missingTools = $missingTools
    }
  }

  return New-SmokeResult "ok" "Local Symphony++ HTTP MCP daemon is initialized and exposes the expected unbound tools." @{
    sessionId = $sessionId
    tools = $toolNames
  }
}

function Invoke-SelfTest {
  $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $dictionary["Mcp-Session-Id"] = @("state-key-one", "ignored")
  $normalized = Get-ResponseHeaderValue $dictionary "mcp-session-id"
  if ($normalized -ne "state-key-one") {
    throw "Expected first header-array value to be used, got '$normalized'."
  }

  $customHeaders = [pscustomobject]@{
    "mcp-session-id" = @("state-key-two")
  }
  $normalized = Get-ResponseHeaderValue $customHeaders "Mcp-Session-Id"
  if ($normalized -ne "state-key-two") {
    throw "Expected PSCustomObject header value to be used, got '$normalized'."
  }

  if ((Get-ResponseHeaderValue @{} "Mcp-Session-Id") -ne $null) {
    throw "Expected missing header to normalize to null."
  }

  $webHeaders = [System.Net.WebHeaderCollection]::new()
  $webHeaders.Add("Mcp-Session-Id", "state-key-three")
  $normalized = Get-ResponseHeaderValue $webHeaders "mcp-session-id"
  if ($normalized -ne "state-key-three") {
    throw "Expected WebHeaderCollection header value to be used, got '$normalized'."
  }

  $duplicateWebHeaders = [System.Net.WebHeaderCollection]::new()
  $duplicateWebHeaders.Add("Mcp-Session-Id", "state-key-four")
  $duplicateWebHeaders.Add("Mcp-Session-Id", "ignored")
  $normalized = Get-ResponseHeaderValue $duplicateWebHeaders "Mcp-Session-Id"
  if ($normalized -ne "state-key-four") {
    throw "Expected first duplicated WebHeaderCollection value to be used, got '$normalized'."
  }

  return New-SmokeResult "ok" "PowerShell header normalization self-test passed."
}

try {
  if ($SelfTest) {
    Write-SmokeResult (Invoke-SelfTest) 0
  }

  $result = Invoke-McpSmoke
  $exitCode = if ($result.status -eq "ok") { 0 } else { 1 }
  Write-SmokeResult $result $exitCode
}
catch {
  $result = New-SmokeResult "script_error" $_.Exception.Message
  Write-SmokeResult $result 1
}
