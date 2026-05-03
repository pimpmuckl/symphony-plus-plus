$script = Join-Path $PSScriptRoot "sympp_hook_nudge.py"

$candidates = @(
  @{ Name = "py"; Args = @("-3") },
  @{ Name = "python3"; Args = @() },
  @{ Name = "python"; Args = @() }
)

foreach ($candidateSpec in $candidates) {
  $candidate = Get-Command $candidateSpec.Name -ErrorAction SilentlyContinue
  if (-not $candidate) {
    continue
  }

  if ($candidate.Source -like "*\Microsoft\WindowsApps\python*.exe") {
    continue
  }

  & $candidate.Source @($candidateSpec.Args) -c "import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)" *> $null
  if ($LASTEXITCODE -ne 0) {
    continue
  }

  & $candidate.Source @($candidateSpec.Args) $script
  exit $LASTEXITCODE
}

exit 0
