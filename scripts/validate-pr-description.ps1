[CmdletBinding(DefaultParameterSetName = "File")]
param(
  [Parameter(Mandatory = $true, ParameterSetName = "File")]
  [string] $File,

  [Parameter(Mandatory = $true, ParameterSetName = "BodyJson")]
  [AllowEmptyString()]
  [string] $BodyJson,

  [string] $TemplatePath = ".github/pull_request_template.md",

  [switch] $WarnOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-Markdown {
  param([AllowNull()][string] $Text)

  if ($null -eq $Text) {
    return ""
  }

  return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Read-BodyMarkdown {
  if ($PSCmdlet.ParameterSetName -eq "File") {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
      throw "Unable to read $File"
    }

    return Normalize-Markdown (Get-Content -LiteralPath $File -Raw)
  }

  if ([string]::IsNullOrWhiteSpace($BodyJson) -or $BodyJson -eq "null") {
    return ""
  }

  $decoded = $BodyJson | ConvertFrom-Json
  return Normalize-Markdown ([string] $decoded)
}

function Get-HeadingPosition {
  param(
    [string] $Document,
    [string] $Heading
  )

  return $Document.IndexOf($Heading, [System.StringComparison]::Ordinal)
}

function Get-HeadingSection {
  param(
    [string] $Document,
    [string] $Heading,
    [string[]] $Headings
  )

  $headingIndex = Get-HeadingPosition -Document $Document -Heading $Heading
  if ($headingIndex -lt 0) {
    return $null
  }

  $sectionStart = $headingIndex + $Heading.Length
  if (($sectionStart + 2) -gt $Document.Length) {
    return ""
  }

  if ($Document.Substring($sectionStart, 2) -ne "`n`n") {
    return $null
  }

  $contentStart = $sectionStart + 2
  $content = $Document.Substring($contentStart)
  $nextOffsets = @()

  foreach ($candidate in $Headings) {
    if ($candidate -eq $Heading) {
      continue
    }

    $offset = $content.IndexOf("`n$candidate", [System.StringComparison]::Ordinal)
    if ($offset -ge 0) {
      $nextOffsets += $offset
    }
  }

  if ($nextOffsets.Count -eq 0) {
    return $content
  }

  return $content.Substring(0, ($nextOffsets | Measure-Object -Minimum).Minimum)
}

function Test-RequiredHeadings {
  param(
    [string] $Body,
    [string[]] $Headings
  )

  $errors = @()

  foreach ($heading in $Headings) {
    if ((Get-HeadingPosition -Document $Body -Heading $heading) -lt 0) {
      $errors += "Missing required heading: $heading"
    }
  }

  return $errors
}

function Test-HeadingOrder {
  param(
    [string] $Body,
    [string[]] $Headings
  )

  $positions = @()

  foreach ($heading in $Headings) {
    $position = Get-HeadingPosition -Document $Body -Heading $heading
    if ($position -ge 0) {
      $positions += $position
    }
  }

  $sorted = @($positions | Sort-Object)
  for ($index = 0; $index -lt $positions.Count; $index++) {
    if ($positions[$index] -ne $sorted[$index]) {
      return @("Required headings are out of order.")
    }
  }

  return @()
}

function Test-Sections {
  param(
    [string] $Template,
    [string] $Body,
    [string[]] $Headings
  )

  $errors = @()

  foreach ($heading in $Headings) {
    $templateSection = Get-HeadingSection -Document $Template -Heading $heading -Headings $Headings
    $bodySection = Get-HeadingSection -Document $Body -Heading $heading -Headings $Headings

    if ($null -eq $bodySection) {
      continue
    }

    if ($bodySection.Trim() -eq "") {
      $errors += "Section cannot be empty: $heading"
      continue
    }

    if (($templateSection -match "(?m)^- ") -and ($bodySection -notmatch "(?m)^- ")) {
      $errors += "Section must include at least one bullet item: $heading"
    }

    if (($templateSection -match "(?m)^- \[ \] ") -and ($bodySection -notmatch "(?m)^- \[[ xX]\] ")) {
      $errors += "Section must include at least one checkbox item: $heading"
    }
  }

  return $errors
}

function Format-GitHubCommandMessage {
  param([string] $Message)

  return $Message.Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
}

function Write-LintWarning {
  param([string] $Message)

  if ($env:GITHUB_ACTIONS -eq "true") {
    Write-Output "::warning::$(Format-GitHubCommandMessage $Message)"
  } else {
    Write-Warning $Message
  }
}

if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
  throw "Unable to read PR template at $TemplatePath"
}

$template = Normalize-Markdown (Get-Content -LiteralPath $TemplatePath -Raw)
$body = Read-BodyMarkdown
$headings = @([regex]::Matches($template, "(?m)^#{4,6}\s+.+$") | ForEach-Object { $_.Value })

if ($headings.Count -eq 0) {
  throw "No markdown headings found in $TemplatePath"
}

$errors = @()
$errors += Test-RequiredHeadings -Body $body -Headings $headings
$errors += Test-HeadingOrder -Body $body -Headings $headings

if ($body.Contains("<!--")) {
  $errors += "PR description still contains template placeholder comments (<!-- ... -->)."
}

$errors += Test-Sections -Template $template -Body $body -Headings $headings

if ($errors.Count -eq 0) {
  Write-Output "PR body format OK"
  exit 0
}

foreach ($errorMessage in $errors) {
  if ($WarnOnly) {
    Write-LintWarning $errorMessage
  } else {
    [Console]::Error.WriteLine("ERROR: $errorMessage")
  }
}

if ($WarnOnly) {
  Write-Output "PR body format warnings only; continuing."
  exit 0
}

[Console]::Error.WriteLine("PR body format invalid. Read ``$TemplatePath`` and follow it precisely.")
exit 1
