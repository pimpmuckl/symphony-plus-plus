param(
  [Parameter(Position = 0, Mandatory = $true)]
  [ValidateSet("store", "remove", "exists", "verify", "run-mcp", "run-mcp-local-file", "run-mcp-local-file-once")]
  [string]$Action,

  [string]$Target,

  [string]$UserName = "sympp-worker",
  [string]$SecretFile,
  [string]$SecretSha256,
  [string]$Database,
  [string]$ClaimedBy,
  [string]$InputFile,
  [string]$OutputFile,
  [string]$ErrorFile,
  [int]$TimeoutSeconds = 60,
  [string]$EnvVar = "SYMPP_WORK_KEY_SECRET",
  [string]$ElixirDir
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($ElixirDir)) {
  $ElixirDir = Join-Path $scriptRoot "..\elixir"
}

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core") {
  throw "Windows Credential Manager handoff is only available on Windows."
}

$nativeCredentialSource = @"
using System;
using System.Runtime.InteropServices;

public static class SymppNativeCredential
{
    public const uint CRED_TYPE_GENERIC = 1;
    public const uint CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredWrite(ref CREDENTIAL userCredential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern void CredFree(IntPtr cred);
}
"@

if (-not ("SymppNativeCredential" -as [type])) {
  Add-Type -TypeDefinition $nativeCredentialSource
}

function Assert-NonBlank([string]$Value, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Name is required."
  }
}

function New-SpoolPath([string]$Suffix) {
  return Join-Path ([System.IO.Path]::GetTempPath()) ("sympp-mcp-" + [System.Guid]::NewGuid().ToString("N") + $Suffix)
}

function Get-SpoolByteCount([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return (Get-Item -LiteralPath $Path).Length
  }

  return 0
}

function Write-McpOnceSummary([string]$Status, [object]$ExitCode, [string]$OutputPath, [string]$ErrorPath) {
  [pscustomobject]@{
    status = $Status
    exit_code = $ExitCode
    output_file = [System.IO.Path]::GetFullPath($OutputPath)
    error_file = [System.IO.Path]::GetFullPath($ErrorPath)
    stdout_bytes = Get-SpoolByteCount $OutputPath
    stderr_bytes = Get-SpoolByteCount $ErrorPath
  } | ConvertTo-Json -Compress
}

function Initialize-SpoolFile([string]$Path) {
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $parent = [System.IO.Path]::GetDirectoryName($fullPath)

  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  $stream = [System.IO.File]::Open(
    $fullPath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::Read
  )
  $stream.Dispose()
  Set-OwnerOnlyFileAcl $fullPath
  return $fullPath
}

function Set-OwnerOnlyFileAcl([string]$Path) {
  $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = Get-Acl -LiteralPath $Path
  $acl.SetAccessRuleProtection($true, $false)

  foreach ($rule in @($acl.Access)) {
    [void]$acl.RemoveAccessRuleAll($rule)
  }

  $acl.SetOwner($currentUser)
  $acl.AddAccessRule(
    [System.Security.AccessControl.FileSystemAccessRule]::new(
      $currentUser,
      [System.Security.AccessControl.FileSystemRights]::FullControl,
      [System.Security.AccessControl.AccessControlType]::Allow
    )
  )
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-ExistingSpoolTarget([string]$Path) {
  return (Test-Path -LiteralPath $Path)
}

function Test-SamePath([string]$Left, [string]$Right) {
  return [string]::Equals(
    [System.IO.Path]::GetFullPath($Left),
    [System.IO.Path]::GetFullPath($Right),
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

function Test-ReparsePoint([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  $item = Get-Item -LiteralPath $Path -Force
  return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-ReparsePointAncestor([string]$Path) {
  $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))

  while (-not [string]::IsNullOrWhiteSpace($directory)) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
      $item = Get-Item -LiteralPath $directory -Force

      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $true
      }
    }

    $parent = [System.IO.Path]::GetDirectoryName($directory)
    if ($parent -eq $directory) {
      break
    }

    $directory = $parent
  }

  return $false
}

function Write-GenericCredential([string]$CredentialTarget, [string]$CredentialUserName, [string]$Secret) {
  Assert-NonBlank $CredentialTarget "Target"
  Assert-NonBlank $CredentialUserName "UserName"
  Assert-NonBlank $Secret "Secret"

  $bytes = [System.Text.Encoding]::Unicode.GetBytes($Secret)
  $blob = [System.Runtime.InteropServices.Marshal]::AllocCoTaskMem($bytes.Length)

  try {
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $blob, $bytes.Length)

    $credential = New-Object SymppNativeCredential+CREDENTIAL
    $credential.Type = [SymppNativeCredential]::CRED_TYPE_GENERIC
    $credential.TargetName = $CredentialTarget
    $credential.CredentialBlobSize = [uint32]$bytes.Length
    $credential.CredentialBlob = $blob
    $credential.Persist = [SymppNativeCredential]::CRED_PERSIST_LOCAL_MACHINE
    $credential.UserName = $CredentialUserName

    if (-not [SymppNativeCredential]::CredWrite([ref]$credential, 0)) {
      $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
      throw "CredWrite failed with Windows error $errorCode."
    }
  }
  finally {
    if ($blob -ne [IntPtr]::Zero) {
      [System.Runtime.InteropServices.Marshal]::FreeCoTaskMem($blob)
    }
  }
}

function Read-GenericCredentialSecret([string]$CredentialTarget) {
  Assert-NonBlank $CredentialTarget "Target"

  $credentialPtr = [IntPtr]::Zero
  if (-not [SymppNativeCredential]::CredRead($CredentialTarget, [SymppNativeCredential]::CRED_TYPE_GENERIC, 0, [ref]$credentialPtr)) {
    $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "CredRead failed with Windows error $errorCode."
  }

  try {
    $credential = [System.Runtime.InteropServices.Marshal]::PtrToStructure($credentialPtr, [type][SymppNativeCredential+CREDENTIAL])
    if ($credential.CredentialBlobSize -eq 0 -or $credential.CredentialBlob -eq [IntPtr]::Zero) {
      throw "Credential blob is empty."
    }

    $bytes = New-Object byte[] $credential.CredentialBlobSize
    [System.Runtime.InteropServices.Marshal]::Copy($credential.CredentialBlob, $bytes, 0, $bytes.Length)
    return [System.Text.Encoding]::Unicode.GetString($bytes)
  }
  finally {
    if ($credentialPtr -ne [IntPtr]::Zero) {
      [SymppNativeCredential]::CredFree($credentialPtr)
    }
  }
}

function Test-GenericCredential([string]$CredentialTarget) {
  Assert-NonBlank $CredentialTarget "Target"

  $credentialPtr = [IntPtr]::Zero
  if (-not [SymppNativeCredential]::CredRead($CredentialTarget, [SymppNativeCredential]::CRED_TYPE_GENERIC, 0, [ref]$credentialPtr)) {
    $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($errorCode -eq 1168) {
      return $false
    }

    throw "CredRead failed with Windows error $errorCode."
  }

  try {
    return $true
  }
  finally {
    if ($credentialPtr -ne [IntPtr]::Zero) {
      [SymppNativeCredential]::CredFree($credentialPtr)
    }
  }
}

function ConvertTo-Sha256Hex([string]$Secret) {
  Assert-NonBlank $Secret "Secret"

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $hashBytes = $sha256.ComputeHash($bytes)
    return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
  }
  finally {
    $sha256.Dispose()
  }
}

function Remove-GenericCredential([string]$CredentialTarget) {
  Assert-NonBlank $CredentialTarget "Target"

  if (-not [SymppNativeCredential]::CredDelete($CredentialTarget, [SymppNativeCredential]::CRED_TYPE_GENERIC, 0)) {
    $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($errorCode -ne 1168) {
      throw "CredDelete failed with Windows error $errorCode."
    }
  }
}

function Invoke-McpWithSecret([string]$Secret) {
  Assert-NonBlank $Secret "Secret"
  Assert-NonBlank $ClaimedBy "ClaimedBy"

  $previousSecret = [Environment]::GetEnvironmentVariable($EnvVar, "Process")
  $pushedLocation = $false

  try {
    [Environment]::SetEnvironmentVariable($EnvVar, $Secret, "Process")
    Push-Location $ElixirDir
    $pushedLocation = $true

    $mcpArgs = @("exec", "--", "mix", "sympp.mcp", "--mode", "stdio", "--work-key-secret-env", $EnvVar, "--claimed-by", $ClaimedBy)
    if (-not [string]::IsNullOrWhiteSpace($Database)) {
      $mcpArgs += @("--database", $Database)
    }

    & mise @mcpArgs
    exit $LASTEXITCODE
  }
  finally {
    if ($pushedLocation) {
      Pop-Location
    }

    [Environment]::SetEnvironmentVariable($EnvVar, $previousSecret, "Process")
  }
}

function Invoke-McpOnceWithSecret([string]$Secret) {
  Assert-NonBlank $Secret "Secret"
  Assert-NonBlank $ClaimedBy "ClaimedBy"
  Assert-NonBlank $InputFile "InputFile"

  if ($TimeoutSeconds -lt 1) {
    throw "TimeoutSeconds must be greater than zero."
  }

  if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = New-SpoolPath ".jsonl"
  }

  if ([string]::IsNullOrWhiteSpace($ErrorFile)) {
    $ErrorFile = New-SpoolPath ".stderr.txt"
  }

  $InputFile = [System.IO.Path]::GetFullPath($InputFile)
  $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)
  $ErrorFile = [System.IO.Path]::GetFullPath($ErrorFile)
  $SecretFilePath = [System.IO.Path]::GetFullPath($SecretFile)

  if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    Write-McpOnceSummary "launch_failed" 1 $OutputFile $ErrorFile
    exit 1
  }

  if (
    (Test-SamePath $InputFile $OutputFile) -or
    (Test-SamePath $InputFile $ErrorFile) -or
    (Test-SamePath $OutputFile $ErrorFile) -or
    (Test-SamePath $SecretFilePath $InputFile) -or
    (Test-SamePath $SecretFilePath $OutputFile) -or
    (Test-SamePath $SecretFilePath $ErrorFile) -or
    (Test-ReparsePoint $SecretFilePath) -or
    (Test-ReparsePoint $InputFile) -or
    (Test-ReparsePoint $OutputFile) -or
    (Test-ReparsePoint $ErrorFile) -or
    (Test-ReparsePointAncestor $SecretFilePath) -or
    (Test-ReparsePointAncestor $InputFile) -or
    (Test-ReparsePointAncestor $OutputFile) -or
    (Test-ReparsePointAncestor $ErrorFile) -or
    (Test-ExistingSpoolTarget $OutputFile) -or
    (Test-ExistingSpoolTarget $ErrorFile)
  ) {
    Write-McpOnceSummary "invalid_paths" 2 $OutputFile $ErrorFile
    exit 2
  }

  $mcpArgs = @("exec", "--", "mix", "sympp.mcp", "--mode", "stdio", "--work-key-secret-env", $EnvVar, "--claimed-by", $ClaimedBy)

  if (-not [string]::IsNullOrWhiteSpace($Database)) {
    $mcpArgs += @("--database", $Database)
  }

  $timedOut = $false
  $exitCode = $null
  $previousSecret = [Environment]::GetEnvironmentVariable($EnvVar, "Process")
  $process = $null
  $launchFailed = $false

  try {
    [Environment]::SetEnvironmentVariable($EnvVar, $Secret, "Process")

    try {
      $OutputFile = Initialize-SpoolFile $OutputFile
      $ErrorFile = Initialize-SpoolFile $ErrorFile

      $process =
        Start-Process `
          -FilePath "mise" `
          -ArgumentList $mcpArgs `
          -WorkingDirectory $ElixirDir `
          -RedirectStandardInput $InputFile `
          -RedirectStandardOutput $OutputFile `
          -RedirectStandardError $ErrorFile `
          -WindowStyle Hidden `
          -PassThru `
          -ErrorAction Stop
    }
    catch {
      $launchFailed = $true
      $exitCode = 127
    }

    if ($null -eq $process) {
      $launchFailed = $true
      $exitCode = 127
    }

    if ($null -ne $process -and -not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $timedOut = $true

      try {
        $process.Kill($true)
      }
      catch {
        $taskkill = Get-Command taskkill.exe -ErrorAction SilentlyContinue

        if ($null -ne $taskkill) {
          & $taskkill.Source /PID $process.Id /T /F | Out-Null
        }

        if (-not $process.HasExited) {
          $process.Kill()
        }
      }

      $process.WaitForExit()
    }

    if ($null -ne $process) {
      $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    }
  }
  finally {
    [Environment]::SetEnvironmentVariable($EnvVar, $previousSecret, "Process")

    if ($null -ne $process) {
      $process.Dispose()
    }
  }

  Write-McpOnceSummary `
    $(if ($launchFailed -or $exitCode -in @(126, 127)) { "launch_failed" } elseif ($timedOut) { "timed_out" } else { "completed" }) `
    $exitCode `
    $OutputFile `
    $ErrorFile

  exit $exitCode
}

switch ($Action) {
  "store" {
    Assert-NonBlank $Target "Target"

    if ([string]::IsNullOrWhiteSpace($SecretFile)) {
      $secret = [Environment]::GetEnvironmentVariable($EnvVar, "Process")
    }
    else {
      $secret = Get-Content -LiteralPath $SecretFile -Raw
    }

    Write-GenericCredential -CredentialTarget $Target -CredentialUserName $UserName -Secret $secret
    Write-Output "stored"
  }
  "remove" {
    Assert-NonBlank $Target "Target"
    Remove-GenericCredential -CredentialTarget $Target
    Write-Output "removed"
  }
  "exists" {
    Assert-NonBlank $Target "Target"
    if (Test-GenericCredential -CredentialTarget $Target) {
      Write-Output "present"
      exit 0
    }

    Write-Output "missing"
    exit 2
  }
  "verify" {
    Assert-NonBlank $Target "Target"
    Assert-NonBlank $SecretSha256 "SecretSha256"

    if (-not (Test-GenericCredential -CredentialTarget $Target)) {
      Write-Output "missing"
      exit 2
    }

    $secret = Read-GenericCredentialSecret -CredentialTarget $Target
    if ((ConvertTo-Sha256Hex -Secret $secret) -ieq $SecretSha256) {
      Write-Output "match"
      exit 0
    }

    Write-Output "mismatch"
    exit 3
  }
  "run-mcp" {
    Assert-NonBlank $Target "Target"
    $secret = Read-GenericCredentialSecret -CredentialTarget $Target
    Invoke-McpWithSecret -Secret $secret
  }
  "run-mcp-local-file" {
    Assert-NonBlank $SecretFile "SecretFile"

    if (-not (Test-Path -LiteralPath $SecretFile -PathType Leaf)) {
      throw "Worker secret file was not found."
    }

    $secret = Get-Content -LiteralPath $SecretFile -Raw
    Invoke-McpWithSecret -Secret $secret
  }
  "run-mcp-local-file-once" {
    Assert-NonBlank $SecretFile "SecretFile"

    if ([string]::IsNullOrWhiteSpace($OutputFile)) {
      $OutputFile = New-SpoolPath ".jsonl"
    }

    if ([string]::IsNullOrWhiteSpace($ErrorFile)) {
      $ErrorFile = New-SpoolPath ".stderr.txt"
    }

    if (-not (Test-Path -LiteralPath $SecretFile -PathType Leaf)) {
      Write-McpOnceSummary "launch_failed" 1 $OutputFile $ErrorFile
      exit 1
    }

    $secretFilePath = [System.IO.Path]::GetFullPath($SecretFile)
    if ((Test-ReparsePoint $secretFilePath) -or (Test-ReparsePointAncestor $secretFilePath)) {
      Write-McpOnceSummary "invalid_paths" 2 $OutputFile $ErrorFile
      exit 2
    }

    $secret = Get-Content -LiteralPath $SecretFile -Raw
    Invoke-McpOnceWithSecret -Secret $secret
  }
}
