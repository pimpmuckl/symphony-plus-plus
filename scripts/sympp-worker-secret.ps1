param(
  [Parameter(Position = 0, Mandatory = $true)]
  [ValidateSet("store", "remove", "exists", "verify", "run-mcp")]
  [string]$Action,

  [string]$Target,

  [string]$UserName = "sympp-worker",
  [string]$SecretFile,
  [string]$SecretSha256,
  [string]$Database,
  [string]$ClaimedBy,
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
}
