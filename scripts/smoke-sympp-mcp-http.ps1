param(
  [string]$Url = "http://127.0.0.1:4057/mcp",
  [switch]$Json,
  [switch]$Bound,
  [string]$WorkKeySecretEnv,
  [string]$ClaimedBy,
  [switch]$SkipUnboundTools,
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

$ExpectedBoundWorkerTools = @(
  "sympp.health",
  "claim_work_key",
  "get_current_assignment",
  "read_context",
  "read_task_plan",
  "update_task_plan",
  "append_finding",
  "append_progress",
  "set_status",
  "report_blocker",
  "resolve_blocker",
  "create_guidance_request",
  "read_guidance_request",
  "request_scope_expansion",
  "attach_branch",
  "attach_pr",
  "sync_pr",
  "submit_review_package",
  "attach_review_suite_result",
  "mark_ready"
)

$SoloTools = @(
  "solo_attach",
  "solo_append",
  "solo_show",
  "solo_list",
  "solo_update_status"
)

$ArchitectTools = @(
  "create_child_work_package",
  "mint_child_worker_key",
  "revoke_child_worker_key",
  "list_work_requests",
  "read_work_request",
  "list_guidance_requests",
  "read_guidance_request",
  "answer_guidance_request",
  "escalate_guidance_request",
  "set_work_request_status",
  "ask_work_request_question",
  "answer_work_request_question",
  "close_work_request_question",
  "record_work_request_decision",
  "add_work_request_planned_slice",
  "approve_work_request_planned_slice",
  "skip_work_request_planned_slice",
  "mark_work_request_sliced",
  "dispatch_work_request_planned_slice",
  "read_child_status",
  "approve_scope_expansion",
  "read_phase_board",
  "request_child_replan",
  "approve_child_ready_state",
  "merge_child_into_phase",
  "split_work_package",
  "publish_phase_update"
)

$ArchitectOnlyTools = @($ArchitectTools | Where-Object { $ExpectedBoundWorkerTools -notcontains $_ })
$UnboundAllowedBoundTools = @("sympp.health", "claim_work_key")
$ForbiddenUnboundTools =
  @($ExpectedBoundWorkerTools | Where-Object { $UnboundAllowedBoundTools -notcontains $_ -and $ArchitectTools -notcontains $_ })
$ForbiddenBoundWorkerTools = $SoloTools + $ArchitectOnlyTools
$ExpectedUnboundTools = $ExpectedTools + $ArchitectTools

$ExpectedWorkerResourceFiles = @(
  "context.md",
  "task_plan.md",
  "findings.md",
  "progress.md",
  "acceptance.md",
  "review_suite.md",
  "handoff.md"
)

$RedactedValue = "<redacted>"
$script:SensitiveValues = [System.Collections.Generic.List[string]]::new()

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

function Add-SensitiveValue([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  if (-not $script:SensitiveValues.Contains($Value)) {
    [void]$script:SensitiveValues.Add($Value)
  }
}

function Protect-SensitiveText([string]$Text) {
  if ($null -eq $Text) {
    return $null
  }

  $protected = [string]$Text
  foreach ($value in $script:SensitiveValues) {
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $protected = $protected.Replace($value, $RedactedValue)
    }
  }

  return $protected
}

function ConvertTo-RedactedJson($Value) {
  return Protect-SensitiveText ($Value | ConvertTo-Json -Depth 12)
}

function Write-SmokeResult($Result, [int]$ExitCode) {
  if ($Json) {
    ConvertTo-RedactedJson $Result
  }
  elseif ($ExitCode -eq 0) {
    Write-Host (Protect-SensitiveText "OK: $($Result.message)")
    if ($Result.PSObject.Properties["mode"]) {
      Write-Host (Protect-SensitiveText "Mode: $($Result.mode)")
    }
    if ($Result.PSObject.Properties["workPackageId"]) {
      Write-Host (Protect-SensitiveText "WorkPackage: $($Result.workPackageId)")
    }
    if ($Result.PSObject.Properties["tools"]) {
      Write-Host (Protect-SensitiveText "Tools: $($Result.tools -join ', ')")
    }
    if ($Result.PSObject.Properties["resources"]) {
      Write-Host (Protect-SensitiveText "Resources: $($Result.resources -join ', ')")
    }
  }
  else {
    [Console]::Error.WriteLine((Protect-SensitiveText $Result.message))
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

function New-ToolCallRequest([string]$Id, [string]$Name, [hashtable]$Arguments) {
  return @{
    jsonrpc = "2.0"
    id = $Id
    method = "tools/call"
    params = @{
      name = $Name
      arguments = $Arguments
    }
  }
}

function New-ResourcesListRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-resources"
    method = "resources/list"
    params = @{}
  }
}

function New-ResourcesReadRequest([string]$Uri) {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-resource"
    method = "resources/read"
    params = @{
      uri = $Uri
    }
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

function Get-ResourceUris($ResourcesPayload) {
  $resources = $ResourcesPayload.result.resources
  if ($null -eq $resources) {
    return @()
  }

  return @($resources | ForEach-Object { [string]$_.uri } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Get-AssignmentWorkPackageId($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["assignment"]) {
    return $null
  }

  $assignment = $structuredContent.assignment
  if ($null -eq $assignment -or -not $assignment.PSObject.Properties["work_package_id"]) {
    return $null
  }

  $workPackageId = [string]$assignment.work_package_id
  if ([string]::IsNullOrWhiteSpace($workPackageId)) {
    return $null
  }

  return $workPackageId
}

function Test-ResponseSessionHeader($Response, [string]$ExpectedSessionId, [string]$Stage) {
  $actualSessionId = Get-ResponseHeaderValue $Response.headers "Mcp-Session-Id"
  if ($actualSessionId -ne $ExpectedSessionId) {
    $actual = if ([string]::IsNullOrWhiteSpace($actualSessionId)) { "<missing>" } else { $actualSessionId }
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "session_id_mismatch" "MCP $Stage did not echo the expected Mcp-Session-Id. expected=$ExpectedSessionId actual=$actual"
    }
  }

  return [pscustomobject]@{ ok = $true }
}

function Get-ResourceJsonPayload($Payload, [string]$Stage) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    throw "$Stage returned no result."
  }

  $contents = @($Payload.result.contents)
  if ($contents.Count -eq 0 -or $null -eq $contents[0].text) {
    throw "$Stage returned no text content."
  }

  try {
    $text = [string]$contents[0].text
    return ($text | ConvertFrom-Json)
  }
  catch {
    throw "$Stage returned non-JSON resource text: $($_.Exception.Message)"
  }
}

function Resolve-BoundSmokeConfig([bool]$UseBound, [string]$SecretEnvName, [string]$Owner) {
  if (-not $UseBound) {
    if (-not [string]::IsNullOrWhiteSpace($SecretEnvName) -or -not [string]::IsNullOrWhiteSpace($Owner) -or $SkipUnboundTools) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "invalid_arguments" "Bound smoke arguments require -Bound. Run without -Bound for the unbound health smoke."
      }
    }

    return [pscustomobject]@{ ok = $true; bound = $false }
  }

  if ([string]::IsNullOrWhiteSpace($SecretEnvName)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_arguments" "Bound smoke requires -WorkKeySecretEnv <env-var-name>."
    }
  }

  $secretEnvName = $SecretEnvName.Trim()
  if ($secretEnvName -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_arguments" "Bound smoke requires a simple environment variable name for -WorkKeySecretEnv."
    }
  }

  if ([string]::IsNullOrWhiteSpace($Owner)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_arguments" "Bound smoke requires -ClaimedBy <stable-worker-id>."
    }
  }

  $owner = $Owner.Trim()
  $secret = [Environment]::GetEnvironmentVariable($secretEnvName)
  if ($null -ne $secret) {
    $secret = $secret.Trim()
  }

  if ([string]::IsNullOrWhiteSpace($secret)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "missing_work_key_secret" "Bound smoke could not read a non-empty work key secret from environment variable '$secretEnvName'."
    }
  }

  Add-SensitiveValue $secret

  return [pscustomobject]@{
    ok = $true
    bound = $true
    secretEnvName = $secretEnvName
    claimedBy = $owner
    secret = $secret
  }
}

function Invoke-InitializeSession([bool]$RedactSessionId) {
  $initResponse = Invoke-McpPost $Url (New-InitializeRequest) $null
  if (-not $initResponse.ok) {
    if ($initResponse.statusCode) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "initialize_failed" "MCP initialize failed with HTTP $($initResponse.statusCode): $($initResponse.error)"
      }
    }

    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "endpoint_unreachable" "Could not reach local MCP endpoint at $Url`: $($initResponse.error)"
    }
  }

  $initPayload = ConvertFrom-JsonResponse $initResponse.content "initialize"
  $initError = Get-JsonRpcErrorMessage $initPayload
  if ($initError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "initialize_failed" "MCP initialize failed: $initError"
    }
  }

  $sessionId = Get-ResponseHeaderValue $initResponse.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "missing_session_id" "MCP initialize succeeded but did not return Mcp-Session-Id."
    }
  }

  if ($RedactSessionId) {
    Add-SensitiveValue $sessionId
  }

  return [pscustomobject]@{
    ok = $true
    sessionId = $sessionId
    payload = $initPayload
  }
}

function Invoke-ToolsListSmoke([string]$SessionId, [string[]]$Expected, [string]$SurfaceName, [string[]]$Forbidden = @()) {
  $toolsResponse = Invoke-McpPost $Url (New-ToolsListRequest) $SessionId
  if (-not $toolsResponse.ok) {
    $reason = if ($toolsResponse.statusCode) { "HTTP $($toolsResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $toolsResponse $toolsResponse.error
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "tools_list_failed" "MCP tools/list failed for $SurfaceName ($reason): $detail"
    }
  }

  $sessionCheck = Test-ResponseSessionHeader $toolsResponse $SessionId "tools/list for $SurfaceName"
  if (-not $sessionCheck.ok) {
    return $sessionCheck
  }

  $toolsPayload = ConvertFrom-JsonResponse $toolsResponse.content "tools/list"
  $toolsError = Get-JsonRpcErrorMessage $toolsPayload
  if ($toolsError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "tools_list_failed" "MCP tools/list returned JSON-RPC error for $SurfaceName`: $toolsError"
    }
  }

  $toolNames = Get-ToolNames $toolsPayload
  $missingTools = @($Expected | Where-Object { $toolNames -notcontains $_ })
  if ($missingTools.Count -gt 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "missing_expected_tools" "MCP tools/list is missing expected $SurfaceName tools: $($missingTools -join ', ')." @{
        tools = $toolNames
        missingTools = $missingTools
      }
    }
  }

  $unexpectedTools = @($Forbidden | Where-Object { $toolNames -contains $_ })
  if ($unexpectedTools.Count -gt 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "unexpected_tools" "MCP tools/list exposed tools that must not appear for $SurfaceName`: $($unexpectedTools -join ', ')." @{
        tools = $toolNames
        unexpectedTools = $unexpectedTools
      }
    }
  }

  return [pscustomobject]@{
    ok = $true
    tools = $toolNames
    payload = $toolsPayload
  }
}

function Invoke-McpSmoke {
  $init = Invoke-InitializeSession $false
  if (-not $init.ok) {
    return $init.result
  }

  $sessionId = $init.sessionId
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
  $missingTools = @($ExpectedUnboundTools | Where-Object { $toolNames -notcontains $_ })
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

function Invoke-BoundMcpSmoke {
  $config = Resolve-BoundSmokeConfig $true $WorkKeySecretEnv $ClaimedBy
  if (-not $config.ok) {
    return $config.result
  }

  $init = Invoke-InitializeSession $true
  if (-not $init.ok) {
    return $init.result
  }

  $sessionId = $init.sessionId
  $unboundTools = @()
  if (-not $SkipUnboundTools) {
    $unbound = Invoke-ToolsListSmoke $sessionId $ExpectedUnboundTools "unbound pre-claim" $ForbiddenUnboundTools
    if (-not $unbound.ok) {
      return $unbound.result
    }

    $unboundTools = $unbound.tools
  }

  $claimResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-claim" "claim_work_key" @{
      secret = $config.secret
      claimed_by = $config.claimedBy
    }) $sessionId

  if (-not $claimResponse.ok) {
    $reason = if ($claimResponse.statusCode) { "HTTP $($claimResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $claimResponse $claimResponse.error
    return New-SmokeResult "claim_failed" "MCP claim_work_key failed ($reason): $detail"
  }

  $claimedSessionId = Get-ResponseHeaderValue $claimResponse.headers "Mcp-Session-Id"
  Add-SensitiveValue $claimedSessionId
  if ([string]::IsNullOrWhiteSpace($claimedSessionId)) {
    return New-SmokeResult "missing_claimed_session_id" "MCP claim_work_key succeeded but did not return Mcp-Session-Id."
  }

  if ($claimedSessionId -ne $sessionId) {
    return New-SmokeResult "session_id_mismatch" "MCP claim_work_key did not preserve the initialized Mcp-Session-Id."
  }

  $claimPayload = ConvertFrom-JsonResponse $claimResponse.content "claim_work_key"
  $claimError = Get-JsonRpcErrorMessage $claimPayload
  if ($claimError) {
    return New-SmokeResult "claim_failed" "MCP claim_work_key returned JSON-RPC error: $claimError"
  }

  $workPackageId = Get-AssignmentWorkPackageId $claimPayload
  if ([string]::IsNullOrWhiteSpace($workPackageId)) {
    return New-SmokeResult "claim_assignment_missing" "MCP claim_work_key response did not include assignment.work_package_id."
  }

  $boundTools = Invoke-ToolsListSmoke $claimedSessionId $ExpectedBoundWorkerTools "bound worker" $ForbiddenBoundWorkerTools
  if (-not $boundTools.ok) {
    return $boundTools.result
  }

  $assignmentToolResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-assignment" "get_current_assignment" @{}) $claimedSessionId
  if (-not $assignmentToolResponse.ok) {
    $reason = if ($assignmentToolResponse.statusCode) { "HTTP $($assignmentToolResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $assignmentToolResponse $assignmentToolResponse.error
    return New-SmokeResult "assignment_tool_failed" "MCP get_current_assignment failed with claimed session ($reason): $detail"
  }

  $sessionCheck = Test-ResponseSessionHeader $assignmentToolResponse $claimedSessionId "get_current_assignment"
  if (-not $sessionCheck.ok) {
    return $sessionCheck.result
  }

  $assignmentToolPayload = ConvertFrom-JsonResponse $assignmentToolResponse.content "get_current_assignment"
  $assignmentToolError = Get-JsonRpcErrorMessage $assignmentToolPayload
  if ($assignmentToolError) {
    return New-SmokeResult "assignment_tool_failed" "MCP get_current_assignment returned JSON-RPC error: $assignmentToolError"
  }

  $assignmentToolWorkPackageId = Get-AssignmentWorkPackageId $assignmentToolPayload
  if ($assignmentToolWorkPackageId -ne $workPackageId) {
    return New-SmokeResult "assignment_mismatch" "MCP get_current_assignment returned a different WorkPackage id than claim_work_key."
  }

  $assignmentResourceResponse = Invoke-McpPost $Url (New-ResourcesReadRequest "sympp://assignment/current") $claimedSessionId
  if (-not $assignmentResourceResponse.ok) {
    $reason = if ($assignmentResourceResponse.statusCode) { "HTTP $($assignmentResourceResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $assignmentResourceResponse $assignmentResourceResponse.error
    return New-SmokeResult "assignment_resource_failed" "MCP resources/read sympp://assignment/current failed with claimed session ($reason): $detail"
  }

  $sessionCheck = Test-ResponseSessionHeader $assignmentResourceResponse $claimedSessionId "resources/read sympp://assignment/current"
  if (-not $sessionCheck.ok) {
    return $sessionCheck.result
  }

  $assignmentResourcePayload = ConvertFrom-JsonResponse $assignmentResourceResponse.content "resources/read"
  $assignmentResourceError = Get-JsonRpcErrorMessage $assignmentResourcePayload
  if ($assignmentResourceError) {
    return New-SmokeResult "assignment_resource_failed" "MCP resources/read sympp://assignment/current returned JSON-RPC error: $assignmentResourceError"
  }

  $assignmentResource = Get-ResourceJsonPayload $assignmentResourcePayload "resources/read sympp://assignment/current"
  if ([string]$assignmentResource.work_package_id -ne $workPackageId) {
    return New-SmokeResult "assignment_resource_mismatch" "MCP assignment resource returned a different WorkPackage id than claim_work_key."
  }

  $resourcesResponse = Invoke-McpPost $Url (New-ResourcesListRequest) $claimedSessionId
  if (-not $resourcesResponse.ok) {
    $reason = if ($resourcesResponse.statusCode) { "HTTP $($resourcesResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $resourcesResponse $resourcesResponse.error
    return New-SmokeResult "resources_list_failed" "MCP resources/list failed with claimed session ($reason): $detail"
  }

  $sessionCheck = Test-ResponseSessionHeader $resourcesResponse $claimedSessionId "resources/list"
  if (-not $sessionCheck.ok) {
    return $sessionCheck.result
  }

  $resourcesPayload = ConvertFrom-JsonResponse $resourcesResponse.content "resources/list"
  $resourcesError = Get-JsonRpcErrorMessage $resourcesPayload
  if ($resourcesError) {
    return New-SmokeResult "resources_list_failed" "MCP resources/list returned JSON-RPC error: $resourcesError"
  }

  $resourceUris = Get-ResourceUris $resourcesPayload
  $expectedResources = @("sympp://assignment/current")
  foreach ($fileName in $ExpectedWorkerResourceFiles) {
    $expectedResources += "sympp://work-packages/$workPackageId/$fileName"
  }

  $missingResources = @($expectedResources | Where-Object { $resourceUris -notcontains $_ })
  if ($missingResources.Count -gt 0) {
    return New-SmokeResult "missing_expected_resources" "MCP resources/list is missing expected bound worker resources: $($missingResources -join ', ')." @{
      resources = $resourceUris
      missingResources = $missingResources
    }
  }

  $data = @{
    mode = "bound_worker"
    claimedBy = $config.claimedBy
    workKeySecretEnv = $config.secretEnvName
    sessionId = $RedactedValue
    sessionIdRedacted = $true
    workPackageId = $workPackageId
    tools = $boundTools.tools
    resources = $resourceUris
  }

  if (-not $SkipUnboundTools) {
    $data["unboundTools"] = $unboundTools
  }

  return New-SmokeResult "ok" "Local Symphony++ HTTP MCP daemon claimed the work key and exposes the expected bound worker tools/resources." $data
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

  $sessionCheck = Test-ResponseSessionHeader ([pscustomobject]@{ headers = @{ "Mcp-Session-Id" = "expected-session" } }) "expected-session" "self-test"
  if (-not $sessionCheck.ok) {
    throw "Expected matching session header to pass continuity validation."
  }

  $sessionCheck = Test-ResponseSessionHeader ([pscustomobject]@{ headers = @{ "Mcp-Session-Id" = "rotated-session" } }) "expected-session" "self-test"
  if ($sessionCheck.ok -or $sessionCheck.result.status -ne "session_id_mismatch") {
    throw "Expected mismatched session header to fail continuity validation."
  }

  if ($ForbiddenUnboundTools -notcontains "append_progress" -or $ForbiddenUnboundTools -notcontains "get_current_assignment") {
    throw "Expected unbound forbidden tools to include worker-only tools."
  }

  if ($ForbiddenUnboundTools -contains "claim_work_key" -or $ForbiddenUnboundTools -contains "sympp.health") {
    throw "Expected unbound forbidden tools to keep health and claim_work_key allowed."
  }

  if ($ForbiddenUnboundTools -contains "read_work_request" -or $ExpectedUnboundTools -notcontains "read_work_request") {
    throw "Expected unbound discovery to allow architect schemas."
  }

  if ($ForbiddenBoundWorkerTools -notcontains "list_work_requests" -or $ForbiddenBoundWorkerTools -notcontains "dispatch_work_request_planned_slice") {
    throw "Expected bound worker forbidden tools to include architect-only tools."
  }

  if ($ArchitectTools -notcontains "read_guidance_request") {
    throw "Expected full architect surface to include shared read_guidance_request."
  }

  if ($ForbiddenBoundWorkerTools -contains "read_guidance_request") {
    throw "Expected shared worker guidance read tool to remain allowed for bound workers."
  }

  $script:SensitiveValues.Clear()
  Add-SensitiveValue "secret-value-for-self-test"
  Add-SensitiveValue "claimed-session-for-self-test"
  $redactedJson = ConvertTo-RedactedJson (New-SmokeResult "ok" "secret-value-for-self-test claimed-session-for-self-test" @{
      secret = "secret-value-for-self-test"
      sessionId = "claimed-session-for-self-test"
    })
  if ($redactedJson -match "secret-value-for-self-test" -or $redactedJson -match "claimed-session-for-self-test") {
    throw "Expected JSON smoke output redaction to remove raw secret and claimed session values."
  }

  if ($redactedJson -notmatch [regex]::Escape($RedactedValue)) {
    throw "Expected JSON smoke output redaction marker to be present."
  }

  $oldValue = [Environment]::GetEnvironmentVariable("SYMPP_SMOKE_SELFTEST_SECRET")
  try {
    [Environment]::SetEnvironmentVariable("SYMPP_SMOKE_SELFTEST_SECRET", "secret-from-env")
    $resolved = Resolve-BoundSmokeConfig $true "SYMPP_SMOKE_SELFTEST_SECRET" "worker-self-test"
    if (-not $resolved.ok -or $resolved.secretEnvName -ne "SYMPP_SMOKE_SELFTEST_SECRET" -or $resolved.claimedBy -ne "worker-self-test") {
      throw "Expected bound smoke argument resolution to read a valid secret environment variable."
    }
  }
  finally {
    [Environment]::SetEnvironmentVariable("SYMPP_SMOKE_SELFTEST_SECRET", $oldValue)
  }

  $invalidEnvName = Resolve-BoundSmokeConfig $true "BAD-NAME" "worker-self-test"
  if ($invalidEnvName.ok -or $invalidEnvName.result.status -ne "invalid_arguments") {
    throw "Expected invalid env-var names to fail bound smoke validation."
  }

  $missingEnv = Resolve-BoundSmokeConfig $true "SYMPP_SMOKE_SELFTEST_MISSING" "worker-self-test"
  if ($missingEnv.ok -or $missingEnv.result.status -ne "missing_work_key_secret") {
    throw "Expected missing work key environment variable to fail bound smoke validation."
  }

  $unexpectedBoundArgument = Resolve-BoundSmokeConfig $false "SYMPP_SMOKE_SELFTEST_SECRET" ""
  if ($unexpectedBoundArgument.ok -or $unexpectedBoundArgument.result.status -ne "invalid_arguments") {
    throw "Expected bound arguments without -Bound to fail validation."
  }

  return New-SmokeResult "ok" "PowerShell header normalization, redaction, and bound argument validation self-test passed."
}

try {
  if ($SelfTest) {
    Write-SmokeResult (Invoke-SelfTest) 0
  }

  $config = Resolve-BoundSmokeConfig ([bool]$Bound) $WorkKeySecretEnv $ClaimedBy
  if (-not $config.ok) {
    Write-SmokeResult $config.result 1
  }

  $result = if ($config.bound) { Invoke-BoundMcpSmoke } else { Invoke-McpSmoke }
  $exitCode = if ($result.status -eq "ok") { 0 } else { 1 }
  Write-SmokeResult $result $exitCode
}
catch {
  $result = New-SmokeResult "script_error" $_.Exception.Message
  Write-SmokeResult $result 1
}
