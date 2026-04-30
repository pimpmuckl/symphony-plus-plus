# Symphony++ Upstream Baseline Setup Notes

This document records the local baseline for the upstream Symphony reference
implementation before adding Symphony++ runtime behavior.

## Scope

- Package: `SYMPP-P0-001`
- Branch: `agent/SYMPP-P0-001/upstream-baseline`
- Baseline target: `symphony-plus-plus/beta`
- Reference implementation: `elixir/`

No Symphony++ runtime code, orchestration behavior, workflow defaults, tests, or
configuration were changed for this baseline.

## Required Tooling

The upstream Elixir README recommends `mise` for Elixir/Erlang installation.
The pinned tool versions are in `elixir/mise.toml`:

```toml
[tools]
erlang = "28"
elixir = "1.19.5-otp-28"
```

The documented quality gate also requires `make`.

## Environment Variables

- `LINEAR_API_KEY`: required for live Linear/orchestrator smoke checks.
- `SYMPHONY_LIVE_LINEAR_TEAM_KEY`: optional for `make e2e`; defaults to
  `SYME2E`.
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS`: optional comma-separated SSH worker list for
  `make e2e`.

Do not print or commit raw credential values.

## Fresh Setup Commands

From a fresh clone:

```powershell
git clone https://github.com/openai/symphony
cd symphony\elixir
mise trust
mise install
mise exec -- elixir --version
mise exec -- mix setup
mise exec -- mix build
```

For this fork/worktree:

```powershell
cd C:\Users\jonat\.codex\worktrees\symphony-plus-plus-SYMPP-P0-001\elixir
mise trust
mise install
mise exec -- elixir --version
mise exec -- mix setup
mise exec -- mix build
```

Run the upstream quality gate from the repository root:

```powershell
make -C elixir all
```

Or from `elixir/`:

```powershell
make all
```

Start the service after setup with a workflow file:

```powershell
cd C:\Users\jonat\.codex\worktrees\symphony-plus-plus-SYMPP-P0-001\elixir
.\bin\symphony .\WORKFLOW.md
```

`elixir/bin` was not present before a successful build in this local baseline.

## Local Baseline Results

Host shell: PowerShell on Windows.

Tool discovery:

```text
where.exe make   -> not found
where.exe mise   -> not found
where.exe elixir -> not found
where.exe mix    -> not found
LINEAR_API_KEY   -> missing
```

Documented command results in PowerShell:

```text
make -C elixir all
Result: failed before tests; make is not installed.
Error: The term 'make' is not recognized as a name of a cmdlet, function,
script file, or executable program.

mise install
Result: failed before setup; mise is not installed.
Error: The term 'mise' is not recognized as a name of a cmdlet, function,
script file, or executable program.

mise exec -- elixir --version
Result: failed before version check; mise is not installed.

mise trust
Result: failed before trust; mise is not installed.

mise exec -- mix setup
Result: failed before dependency setup; mise is not installed.

mise exec -- mix build
Result: failed before build; mise is not installed.
```

WSL fallback check:

```text
wsl.exe --version
Result: WSL 2.6.3.0 is installed.

wsl.exe bash -lc "command -v make; command -v mise; command -v elixir; command -v mix"
Result: /usr/bin/make was found; mise, elixir, and mix were not found.

wsl.exe bash -lc "cd /mnt/c/Users/jonat/.codex/worktrees/symphony-plus-plus-SYMPP-P0-001/elixir && make all"
Result: failed before tests; Makefile invoked mix setup, but mix is missing.
Error: make[1]: mix: No such file or directory

wsl.exe bash -lc "cd /mnt/c/Users/jonat/.codex/worktrees/symphony-plus-plus-SYMPP-P0-001/elixir && make setup"
Result: failed before dependency setup; mix is missing.
Error: make: mix: No such file or directory

wsl.exe bash -lc "cd /mnt/c/Users/jonat/.codex/worktrees/symphony-plus-plus-SYMPP-P0-001/elixir && make build"
Result: failed before build; mix is missing.
Error: make: mix: No such file or directory
```

No ExUnit tests, formatter checks, lint checks, coverage, Dialyzer, live E2E, or
runtime orchestrator smoke checks executed in this environment because the local
host is missing the required Elixir toolchain. Live Linear checks were also
skipped because `LINEAR_API_KEY` was not present.

## Post-Install Validation Refresh

Date: 2026-04-30.

After installing Erlang/Elixir/Chocolatey tooling on the same Windows host,
the upstream baseline was rerun from the merged `symphony-plus-plus/beta`
state. This refresh preserves the original missing-tooling baseline above and
adds the current host evidence after installation.

Validated successfully in `elixir/`:

```text
mise trust
Result: passed.

mise exec -- elixir --version
Result: passed; Erlang/OTP 28 and Elixir 1.19.5 were available.

mise exec -- mix --version
Result: passed; Mix 1.19.5 was available.

mise exec -- mix setup
Result: passed.

mise exec -- mix build
Result: passed; generated bin/symphony.
Note: Phoenix LiveView emitted a Windows symlink permission warning (:eperm),
but the build completed successfully.
```

Raw `make -C elixir all` still failed in the current PowerShell process because
Make invoked plain `mix`, and that process `PATH` did not include Chocolatey's
Elixir bin directory. For the current session, prepending the Chocolatey Elixir
bin directory remediated raw command discovery:

```powershell
$env:PATH = "C:\ProgramData\chocolatey\lib\elixir\tools\bin;$env:PATH"
where.exe elixir
where.exe mix
where.exe iex
```

After that current-session fix, raw `elixir`, `mix`, and `iex` resolved. This
PATH note is only for raw command discovery after an out-of-band Chocolatey
install. Keep the canonical validation flow on the pinned `mise exec` commands
below; do not use a global Chocolatey PATH entry as a substitute for the
`elixir/mise.toml` toolchain.

The full upstream gate advanced past setup/build/format/lint and reached tests
when run through `mise`:

```text
mise exec -- make all
Result: failed in coverage/tests after setup, build, format, and lint.
Observed: 230 tests, 57 failures, 2 skipped.
Coverage: 95.39%, below the configured 100% threshold.
```

Failure clusters on this Windows host included path canonicalization/root
containment, symlink permission behavior, fake SSH/binary interception, shell
hook execution through `sh -lc`, specs-check expectations, and workspace
cleanup/path assertions.

This means Phase 0 now has upstream baseline evidence that `mise exec` setup and
build work on the post-install Windows host. The full gate reaches the upstream
test/coverage phase but is not green on this host.

## Next Local Setup Step

For a fresh PowerShell host with no tooling, install `mise` and `make` first.
Let `mise install` provide the pinned Elixir/Erlang toolchain, then rerun:

```powershell
cd <repo-root>\elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- make all
```

If the current PowerShell process must resolve raw Elixir commands immediately
after a Chocolatey Elixir install, first apply the session-local `PATH`
remediation:

```powershell
$env:PATH = "C:\ProgramData\chocolatey\lib\elixir\tools\bin;$env:PATH"
where.exe elixir
where.exe mix
where.exe iex
```

A new login shell or persistent user/system `PATH` update may still be required
after Chocolatey installs for future PowerShell processes to resolve those raw
commands without manual session patching. That PATH update is not part of the
pinned upstream validation flow above.

For the WSL fallback profiled above, `/usr/bin/make` is already present. Install
the Elixir toolchain with `mise`, then rerun:

```bash
cd <repo-root>/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
make all
```

With a valid `LINEAR_API_KEY`, run live validation only when disposable Linear
resources and a real Codex app-server session are acceptable:

```powershell
cd <repo-root>\elixir
$env:LINEAR_API_KEY = "<redacted>"
mise exec -- make e2e
```

Keep token values out of logs, docs, PR text, and commits.
