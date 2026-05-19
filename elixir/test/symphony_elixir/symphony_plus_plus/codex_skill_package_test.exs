defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry

  @repo_root Path.expand("../../../../", __DIR__)
  @skill_path Path.join(@repo_root, ".codex/skills/symphony-work-package/SKILL.md")
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
  @plugin_mcp_path Path.join(@repo_root, "plugins/symphony-plus-plus/.mcp.json")
  @plugin_skills_dir Path.join(@repo_root, "plugins/symphony-plus-plus/skills")
  @plugin_default_solo_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills-default/symphony-solo-session/SKILL.md")
  @plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus/scripts/sympp-solo.ps1")
  @plugin_lifecycle_diagnostic_path Path.join(@repo_root, "plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1")
  @mcp_plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json")
  @mcp_plugin_mcp_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/.mcp.json")
  @mcp_plugin_readme_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/README.md")
  @mcp_plugin_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-work-package/SKILL.md")
  @mcp_plugin_solo_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-solo-session/SKILL.md")
  @mcp_plugin_architect_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md")
  @mcp_plugin_start_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
  @mcp_plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1")
  @marketplace_path Path.join(@repo_root, ".agents/plugins/marketplace.json")
  @plugin_readme_path Path.join(@repo_root, "plugins/symphony-plus-plus/README.md")
  @refresh_script_path Path.join(@repo_root, "scripts/refresh-local-plugin.ps1")
  @worker_secret_script_path Path.join(@repo_root, "scripts/sympp-worker-secret.ps1")
  @worker_secret_shell_path Path.join(@repo_root, "scripts/sympp-worker-secret.sh")
  @prompt_path Path.join(@repo_root, ".codex/skills/symphony-work-package/references/worker_prompt.md")
  @wiring_path Path.join(@repo_root, ".codex/skills/symphony-work-package/references/mcp_wiring.md")
  @mcp_plugin_wiring_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-work-package/references/mcp_wiring.md")
  @handoff_path Path.join(@repo_root, "implementation_docs_symphplusplus/docs/00_ARCHITECT_AGENT_HANDOFF.md")
  @runbook_path Path.join(@repo_root, "implementation_docs_symphplusplus/docs/09_OPERATIONAL_RUNBOOK.md")
  @template_skill_path Path.join(@repo_root, "implementation_docs_symphplusplus/templates/SKILL.md")
  @template_prompt_path Path.join(@repo_root, "implementation_docs_symphplusplus/templates/worker_agent_prompt.md")
  @template_references_dir Path.join(@repo_root, "implementation_docs_symphplusplus/templates/references")
  @contract_path Path.join(@repo_root, "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json")

  @worker_tools [
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
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "mark_ready"
  ]

  test "skill package has required metadata and worker MCP workflow" do
    skill = File.read!(@skill_path)

    assert skill =~ "name: symphony-work-package"
    assert skill =~ "description:"

    for tool <- @worker_tools do
      assert skill =~ tool
    end

    assert skill =~ "sympp://work-packages/{id}/acceptance.md"
    assert skill =~ "--work-key-secret-env <env-var> --claimed-by <stable-worker-id>"
    assert skill =~ "Do not ask for, paste, print, or log the raw secret."
    assert skill =~ "Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as"
    assert skill =~ "Worker grants are scoped to exactly one WorkPackage."
    assert skill =~ "`state_key` preserves initialized MCP handshake continuity only."
    refute skill =~ "request_context"
  end

  test "worker prompt is paste-ready and MCP-backed" do
    prompt = File.read!(@prompt_path)
    template_prompt = File.read!(@template_prompt_path)

    for content <- [prompt, template_prompt] do
      assert String.starts_with?(content, "You are assigned Symphony++ work package")
      assert content =~ "<WORK_PACKAGE_ID>"
      assert content =~ "Work key handoff: configured in the local MCP private-store bootstrap"
      assert content =~ "Handoff target: <HANDOFF_TARGET>"
      assert content =~ "update_task_plan(patch, expected_version)"
      assert content =~ "resolve_blocker(blocker_id, resolution, summary, idempotency_key)"
      assert content =~ "request_scope_expansion(summary, idempotency_key, payload)"
      assert content =~ "attach_pr(url, head_sha)"
      assert content =~ "Do not create local planning files as the WorkPackage source of truth."
      assert content =~ "Do not use broad Linear/GitHub state as permission authority."
      refute content =~ "attach_pr(pr_url"
      refute content =~ "```"
      refute content =~ "request_context"
    end
  end

  test "MCP wiring docs explain the local HTTP dependency without embedding secrets" do
    wiring = File.read!(@wiring_path)
    plugin_wiring = File.read!(@mcp_plugin_wiring_path)
    template_wiring = File.read!(Path.join(@template_references_dir, "mcp_wiring.md"))

    assert wiring =~ "http://127.0.0.1:4057/mcp"
    assert wiring =~ "mix sympp.cockpit --database <ledger-path>"
    assert wiring =~ "--port 0"
    assert wiring =~ "[mcp_servers.symphony_plus_plus]"
    assert wiring =~ "url = \"http://127.0.0.1:4057/mcp\""
    assert wiring =~ "sympp-worker-secret.ps1"
    assert wiring =~ "sympp-worker-secret.sh"
    assert wiring =~ "run-mcp-local-file-once"
    assert wiring =~ "waits for exit before draining stdout"
    assert wiring =~ "--work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by <stable-worker-id>"
    assert wiring =~ "should not embed raw work-key secrets or bearer tokens"
    assert wiring =~ "generic Codex sessions, review-suite lanes, and `codex review`"
    assert wiring =~ "open a new session before treating stale skill metadata"
    assert wiring =~ "ValidateInstalledCache checks the packaged HTTP URL"
    assert wiring =~ "scripts/refresh-local-plugin.ps1 -ValidateInstalledCache"
    assert wiring =~ "Skill visibility, explicit MCP configuration, global MCP settings"
    assert wiring =~ "must not declare\n`mcpServers`"
    assert wiring =~ "That server may not appear"
    assert plugin_wiring == wiring
    assert template_wiring == wiring
    refute wiring =~ "sympp_live_"
  end

  test "worker secret wrappers include safe one-shot stdio diagnostics" do
    powershell = File.read!(@worker_secret_script_path)
    shell = File.read!(@worker_secret_shell_path)
    contract = File.read!(@contract_path)

    assert powershell =~ "run-mcp-local-file-once"
    assert powershell =~ "InputFile"
    assert powershell =~ "OutputFile"
    assert powershell =~ "-RedirectStandardOutput $OutputFile"
    assert powershell =~ "Get-SpoolByteCount"
    assert powershell =~ "Initialize-SpoolFile"
    assert powershell =~ "Set-OwnerOnlyFileAcl"
    assert powershell =~ "[System.IO.FileMode]::CreateNew"
    assert powershell =~ "SetAccessRuleProtection($true, $false)"
    assert powershell =~ "FileSystemRights]::FullControl"
    assert powershell =~ "Test-ExistingSpoolTarget"
    assert powershell =~ "Test-SamePath"
    assert powershell =~ "Test-ReparsePoint"
    assert powershell =~ "Test-ReparsePointAncestor"
    assert powershell =~ "SecretFilePath"
    assert powershell =~ "secretFilePath"
    assert powershell =~ "invalid_paths"
    assert powershell =~ "$exitCode -in @(126, 127)"
    assert powershell =~ "-ErrorAction Stop"
    assert powershell =~ "$null -eq $process"
    assert powershell =~ "taskkill.exe"
    assert powershell =~ "/PID $process.Id /T /F"
    assert powershell =~ "launch_failed"
    refute powershell =~ "Write-Output $secret"

    assert shell =~ "run-mcp-local-file-once"
    assert shell =~ "--input-file"
    assert shell =~ "--output-file"
    assert shell =~ "mktemp -d"
    assert shell =~ "TEMP_ROOT=${TMPDIR:-/tmp}"
    assert shell =~ "pwd -P) && SPOOL_DIR=$(mktemp -d \"$TEMP_ROOT/sympp-mcp.XXXXXX\""
    assert shell =~ "make_absolute_path"
    assert shell =~ "emit_one_shot_summary"
    assert shell =~ "normalize_path_segments"
    assert shell =~ "canonical_path"
    assert shell =~ "has_symlink_ancestor"
    assert shell =~ "CALLER_CWD=${PWD:-}"
    refute shell =~ "CALLER_CWD=$(pwd -P)"
    assert shell =~ "OUTPUT_FILE_GENERATED=1"
    assert shell =~ "[ \"$OUTPUT_FILE_GENERATED\" -eq 0 ]"
    assert shell =~ "[ \"$SECRET_PATH\" = \"$OUTPUT_FILE\" ]"
    assert shell =~ "[ -L \"$OUTPUT_FILE\" ]"
    assert shell =~ "prepare_spool_file"
    assert shell =~ "SYMPP_MCP_ONCE_TIMEOUT_SECONDS"
    assert shell =~ "setsid mise exec"
    assert shell =~ "TIMEOUT_FILE=$OUTPUT_FILE.timeout.$$"
    assert shell =~ "if kill -0 \"$CHILD_PID\""
    assert shell =~ "kill -TERM \"-$CHILD_PID\""
    assert shell =~ "kill_process_tree -TERM \"$CHILD_PID\""
    assert shell =~ "pgrep -P \"$pid\""
    assert shell =~ "kill -KILL \"-$CHILD_PID\""
    assert shell =~ "kill_process_tree -KILL \"$CHILD_PID\""
    assert shell =~ "old_umask=$(umask)"
    assert shell =~ "restore_noclobber=1"
    assert shell =~ "umask 077"
    assert shell =~ "set -C"
    assert shell =~ "set +C"
    assert shell =~ "chmod 600 \"$1\""
    assert shell =~ "[ -e \"$OUTPUT_FILE\" ]"
    assert shell =~ "[ -e \"$ERROR_FILE\" ]"
    assert shell =~ "SYMPP_WORK_KEY_SECRET=$SECRET setsid mise exec"
    assert shell =~ "unset SECRET"
    assert shell =~ "SUMMARY_STATUS=invalid_paths"
    assert shell =~ "SUMMARY_STATUS=timed_out"
    assert shell =~ "elif ! cd \"$ELIXIR_DIR\" 2>/dev/null; then"
    assert shell =~ "OUTPUT_FILE_READY=0"
    assert shell =~ "SUMMARY_STATUS=launch_failed"
    refute shell =~ "sympp-mcp-stdout.$$"
    assert shell =~ "json_escape()"
    assert shell =~ "OUTPUT_FILE_JSON=$(json_escape \"$OUTPUT_FILE\")"
    refute shell =~ "printf '%s\\n' \"$SECRET\""

    assert contract =~ "run-mcp-local-file-once"
  end

  test "Codex plugin package exposes only MCP-free Solo Session skill" do
    manifest =
      @plugin_manifest_path
      |> File.read!()
      |> Jason.decode!()

    marketplace =
      @marketplace_path
      |> File.read!()
      |> Jason.decode!()

    assert manifest["name"] == "symphony-plus-plus"
    assert manifest["version"] == @plugin_version
    assert Version.compare(@plugin_version, "0.1.1") == :gt
    assert manifest["skills"] == "./skills-default/"
    refute Map.has_key?(manifest, "mcpServers")
    assert manifest["interface"]["displayName"] == "Symphony++"
    assert manifest["description"] =~ "Solo Session"
    assert manifest["interface"]["shortDescription"] =~ "Solo Session"
    refute manifest["description"] =~ "WorkPackage"
    refute manifest["interface"]["shortDescription"] =~ "WorkPackage"
    refute File.exists?(@plugin_mcp_path)
    refute File.exists?(@plugin_skills_dir)
    assert File.read!(@plugin_default_solo_skill_path) =~ "name: symphony-solo-session"
    assert File.read!(@plugin_default_solo_skill_path) =~ "Do not create local"
    assert File.read!(@plugin_default_solo_skill_path) =~ "symphony-work-package"
    assert File.read!(@plugin_solo_script_path) =~ "mix sympp.solo"
    assert File.read!(@plugin_solo_script_path) =~ ".sympp-source-root"
    refute File.read!(@plugin_solo_script_path) =~ "Resolve-DefaultDatabase"
    refute File.read!(@plugin_solo_script_path) =~ "solo-sessions.sqlite3"
    refute File.exists?(@mcp_plugin_solo_skill_path)
    refute File.read!(@mcp_plugin_solo_script_path) =~ "Resolve-DefaultDatabase"
    refute File.read!(@mcp_plugin_solo_script_path) =~ "solo-sessions.sqlite3"

    assert Enum.any?(marketplace["plugins"], fn plugin ->
             plugin["name"] == "symphony-plus-plus" and
               plugin["source"] == %{"source" => "local", "path" => "./plugins/symphony-plus-plus"}
           end)

    assert Enum.any?(marketplace["plugins"], fn plugin ->
             plugin["name"] == "symphony-plus-plus-mcp" and
               plugin["source"] == %{"source" => "local", "path" => "./plugins/symphony-plus-plus-mcp"}
           end)

    assert File.exists?(@refresh_script_path)
    assert File.exists?(@worker_secret_script_path)
    assert File.exists?(@worker_secret_shell_path)
    assert File.read!(@plugin_readme_path) =~ ~s("path": "./plugins/symphony-plus-plus")
    assert File.read!(@plugin_readme_path) =~ "manifest-version directory"
    assert File.read!(@plugin_readme_path) =~ "refreshes every Symphony++ package"
    assert File.read!(@plugin_readme_path) =~ "refresh-local-plugin.ps1 -ValidateInstalledCache"
    assert File.read!(@plugin_readme_path) =~ "intentionally skill-only"
    assert File.read!(@plugin_readme_path) =~ "does not declare `mcpServers`"
    assert File.read!(@plugin_readme_path) =~ "skills-default/"
    assert File.read!(@plugin_readme_path) =~ "`codex review`"
    assert File.read!(@plugin_readme_path) =~ "plugins/symphony-plus-plus-mcp"
    assert File.read!(@plugin_readme_path) =~ "diagnose-mcp-lifecycle.ps1"
    assert File.read!(@plugin_readme_path) =~ "local HTTP daemon"
    assert File.read!(@plugin_readme_path) =~ "taskkill"
    assert File.read!(@plugin_readme_path) =~ "diagnostic truncates and redacts"
    assert File.read!(@plugin_readme_path) =~ "Live process counts are scoped to `-RepoRoot`"
    assert File.read!(@plugin_readme_path) =~ "current usable cache entries"
    assert File.read!(@plugin_readme_path) =~ "prunes removed managed skill directories"
    assert File.read!(@plugin_readme_path) =~ "Superseded version directories"
    assert File.read!(@plugin_readme_path) =~ "The diagnostic rejects `-RepoRoot`"
    assert File.read!(@plugin_readme_path) =~ "usable current caches point at multiple"
    assert File.read!(@plugin_readme_path) =~ "reported separately as unattributed"
    assert File.read!(@plugin_readme_path) =~ "opt-in\n`mise exec -- mix` launcher path"
    assert File.read!(@plugin_readme_path) =~ "Malformed installed cache JSON is reported"
    assert File.read!(@plugin_readme_path) =~ "scans every `symphony-plus-plus` marketplace cache"
    assert File.read!(@plugin_readme_path) =~ "manifest lifecycle status"
    assert File.read!(@plugin_readme_path) =~ "incompatible_default_plugin_bundles_mcp"
    assert File.read!(@plugin_readme_path) =~ "missing_manifest"
    assert File.read!(@plugin_readme_path) =~ "reporting machine-wide processes"
    assert File.read!(@plugin_readme_path) =~ "defines the expected\n`symphony_plus_plus` HTTP server"
    assert File.read!(@plugin_readme_path) =~ "process scan as unsupported"
    assert File.read!(@plugin_readme_path) =~ "Default Planning And Opt-In MCP"
    assert File.read!(@plugin_readme_path) =~ "symphony-plus-plus:symphony-solo-session"
    assert File.read!(@plugin_readme_path) =~ "sympp-solo.ps1 -ValidateOnly"
    assert File.read!(@plugin_readme_path) =~ "http://127.0.0.1:4057/mcp"
    assert File.read!(@plugin_readme_path) =~ "codex --profile sympp-agent app <path>"
    assert File.read!(@plugin_readme_path) =~ "subprocess/app-server session"
    assert File.read!(@plugin_readme_path) =~ "supported replacement for app-visible"
    assert File.read!(@plugin_readme_path) =~ "Solo/cockpit handoff path"
    assert File.read!(@plugin_readme_path) =~ "shared local Symphony++ default ledger"
    assert File.read!(@plugin_readme_path) =~ "diagnose-mcp-lifecycle.ps1 -Doctor"
    assert File.read!(@plugin_readme_path) =~ "solo_ready_mcp_companion_not_enabled"
    assert File.read!(@plugin_readme_path) =~ "symphony-plus-plus-mcp@<marketplace>"
    assert File.read!(@plugin_readme_path) =~ "-EnableMcpCompanion"
    assert File.read!(@plugin_readme_path) =~ "-CodexHome <dedicated-codex-home>"
    assert File.read!(@plugin_readme_path) =~ "config.toml.sympp-backup-*"
    assert File.read!(@plugin_readme_path) =~ "refuses the default `~/.codex` home"
    assert File.read!(@plugin_readme_path) =~ "cannot inspect the tool list already registered"
    assert File.read!(@plugin_readme_path) =~ "source-only repair commands"

    assert File.read!(@plugin_default_solo_skill_path) =~
             "default Symphony++ planning path for real agents"

    refute File.read!(@plugin_readme_path) =~ "../../Code/"
    assert File.read!(@refresh_script_path) =~ "ReparsePoint"
    assert File.read!(@refresh_script_path) =~ "ValidateInstalledCache"
    assert File.read!(@refresh_script_path) =~ "Invoke-InstalledCacheValidation"
    assert File.read!(@refresh_script_path) =~ "$PluginName = \"all\""
    assert File.read!(@refresh_script_path) =~ "SymppPluginPackageNames"
    assert File.read!(@refresh_script_path) =~ "PSObject.Properties.Name) -contains \"mcpServers\""
    assert File.read!(@refresh_script_path) =~ "scripts/sympp-solo.ps1"
    assert File.read!(@refresh_script_path) =~ "skills-default"
    assert File.read!(@refresh_script_path) =~ "Repair-IncompatibleDefaultPluginCacheEntries"
    assert File.read!(@refresh_script_path) =~ "Sync-ManagedDirectoryChildren"
    assert File.read!(@refresh_script_path) =~ "Installed plugin MCP fallback wrapper validation failed"
    assert File.read!(@refresh_script_path) =~ "Default installed plugin cache must not contain root .mcp.json"
    assert File.read!(@refresh_script_path) =~ "Run the activation doctor"
    assert File.read!(@refresh_script_path) =~ "Get-AvailablePowerShellCommandName"
    assert File.read!(@refresh_script_path) =~ "Quote-PowerShellLiteral $doctorScript"
    assert File.read!(@refresh_script_path) =~ "-CodexHome $(Quote-PowerShellLiteral $codexHomePath)"
    assert File.read!(@refresh_script_path) =~ "-MarketplaceName $(Quote-PowerShellLiteral $marketplaceName)"
    refute File.read!(@refresh_script_path) =~ " -File plugins\\symphony-plus-plus"
    assert File.exists?(@plugin_lifecycle_diagnostic_path)
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "start-sympp-mcp.ps1"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "sympp\\.mcp --mode stdio"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Resolve-ComparableFileSystemPath"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Update-TomlMultilineStringState"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "New-CurrentDiagnosticCommand"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "diagnose-mcp-lifecycle self-test passed"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "installed_cache = @($cachePackages)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "live_repo_roots = @($repoRoots)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "launcher_parents = @($launcherParents)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "repo_root_filter = $RepoRoot"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "other_marketplace_mcp_companion_enabled"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "RepoRoot does not look like a Symphony++ checkout"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "mise_sympp_mcp = $miseProcesses.Count"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Find-AncestorLauncherProcessIds"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "foreach ($processId in $found)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Find-TomlBooleanKeyAssignment"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "quoted boolean key"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "$filterAnchorProcesses"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "manifest_parse_error"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "mcp_parse_error"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "manifest_mcpServers_declared"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "manifest_exists"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "default_plugin_lifecycle_status"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "symphony-plus-plus-mcp"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "package_name"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "package.marketplace_name"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "ready_priority"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "version_sort_key"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "current_working_directory"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "multiple_marketplaces_need_selection"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "relocate_global_sympp_mcp_entry"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "-CodexHome $(Quote-PowerShellLiteral $CodexHomePath)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "$($package.marketplace_name)/$($package.package_name)/$($package.label)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "opt_in_mcp_plugin_bundles_mcp"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "reference_mcp_server_status"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "invalid_url"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "invalid_mixed_http_stdio"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "non_default_http_url"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "http_mcp_reachability_status"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "mcp_endpoint_available"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "unexpected_http_status_"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "unreachable"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "invalid_cwd"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "invalid_args"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Test-CachePackageIsCurrentForProcessScope"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Test-CachePackageCanScopeProcesses"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "missing_manifest"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "incompatible_default_plugin_bundles_mcp"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "symphony_plus_plus_server"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "process_scan_supported"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "process_scan_scope"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "skipped_no_repo_root_scope"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "skipped_ambiguous_cache_source_root_hints"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "installed_cache_source_root_hints"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "directLauncherProcesses"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "start_sympp_mcp_pwsh_unattributed"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "unattributed_launcher_parents"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "MarketplaceName = \"*\""
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "[System.Boolean]::Parse"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Get-ReadinessSummary"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "solo_ready_mcp_companion_not_enabled"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Get-ActivationConfigKey"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "EnableMcpCompanion"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Set-PluginEnabledInConfig"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "sympp-backup"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Keep symphony-plus-plus-mcp out of generic worker"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "ready_via_mcp_companion"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "session_visibility_note"

    assert File.read!(@refresh_script_path) =~
             "Assert-ExistingCachePathNotReparsePoint @($codexHomePath, $pluginsRoot, $cacheRoot, $marketplaceCacheRoot, $pluginCacheRoot)"

    assert File.read!(@refresh_script_path) =~ "Assert-NoReparsePointDescendants $TargetRoot"
    assert File.read!(@refresh_script_path) =~ "Assert-NotReparsePoint $target"
    assert File.read!(@refresh_script_path) =~ "Assert-NoReparsePointDescendants $target"
    assert File.read!(@refresh_script_path) =~ "Assert-NotReparsePoint $sourceRootHintPath"
    refute File.read!(@refresh_script_path) =~ "Remove-Item -LiteralPath $TargetRoot -Recurse"
    assert File.read!(@refresh_script_path) =~ "Refusing to refresh reparse-point plugin cache directory"
    assert File.read!(@refresh_script_path) =~ "Refusing to refresh plugin cache directory containing a reparse-point child"
    assert File.read!(@worker_secret_script_path) =~ "CRED_PERSIST_LOCAL_MACHINE"
    refute File.read!(@worker_secret_script_path) =~ "CRED_PERSIST_SESSION"
  end

  test "Codex plugin package is physically MCP-free by default" do
    manifest =
      @plugin_manifest_path
      |> File.read!()
      |> Jason.decode!()

    assert manifest["name"] == "symphony-plus-plus"
    refute Map.has_key?(manifest, "mcpServers")
    refute File.exists?(@plugin_mcp_path)
  end

  test "opt-in MCP plugin package carries bundled server wiring and full skills" do
    manifest =
      @mcp_plugin_manifest_path
      |> File.read!()
      |> Jason.decode!()

    mcp_config =
      @mcp_plugin_mcp_path
      |> File.read!()
      |> Jason.decode!()

    assert manifest["name"] == "symphony-plus-plus-mcp"
    assert manifest["version"] == @plugin_version
    assert manifest["skills"] == "./skills/"
    assert manifest["mcpServers"] == "./.mcp.json"
    assert manifest["description"] =~ "Opt-in"
    assert manifest["interface"]["displayName"] == "Symphony++ MCP"

    assert File.read!(@mcp_plugin_readme_path) =~ "`symphony-plus-plus` Codex plugin"
    assert File.read!(@mcp_plugin_readme_path) =~ "Do not enable this plugin in the normal global Codex config"
    assert File.read!(@mcp_plugin_readme_path) =~ "concrete install path"
    assert File.read!(@mcp_plugin_readme_path) =~ "[plugins.\"symphony-plus-plus-mcp@jonat-local\"]"
    assert File.read!(@mcp_plugin_readme_path) =~ "-EnableMcpCompanion"
    assert File.read!(@mcp_plugin_readme_path) =~ "-CodexHome <dedicated-codex-home>"
    assert File.read!(@mcp_plugin_readme_path) =~ "timestamped backup"
    assert File.read!(@mcp_plugin_readme_path) =~ "refuses the default `~/.codex` home"
    assert File.read!(@mcp_plugin_readme_path) =~ "diagnose-mcp-lifecycle.ps1 -MarketplaceName jonat-local -Doctor"
    assert File.read!(@mcp_plugin_readme_path) =~ "cannot inspect"

    assert File.read!(@mcp_plugin_skill_path) == File.read!(@skill_path)
    refute File.exists?(@mcp_plugin_solo_skill_path)
    assert File.read!(@mcp_plugin_architect_skill_path) =~ "name: symphony-architect"

    assert File.read!(@mcp_plugin_start_script_path) =~ "sympp.mcp"
    assert File.read!(@mcp_plugin_solo_script_path) =~ "sympp.solo"

    assert %{
             "symphony_plus_plus" => %{
               "url" => "http://127.0.0.1:4057/mcp"
             }
           } = documented_mcp_server_map(mcp_config)

    refute get_in(documented_mcp_server_map(mcp_config), ["symphony_plus_plus", "command"])
    refute get_in(documented_mcp_server_map(mcp_config), ["symphony_plus_plus", "args"])

    serialized = Jason.encode!(manifest) <> Jason.encode!(mcp_config)
    refute serialized =~ "SYMPP_WORK_KEY_SECRET"
    refute serialized =~ "bearer"
    refute serialized =~ "token"
    refute serialized =~ "worker-secret"
  end

  test "lifecycle diagnostic explains default skill visible but MCP companion not enabled" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-readiness-default-only-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])

      companion_manifest_path =
        plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      companion_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))

        File.mkdir_p!(Path.dirname(companion_manifest_path))

        File.write!(
          companion_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})
        )

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true
          """
        )

        {json_output, json_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "solo_ready_mcp_companion_not_enabled"
        assert readiness["solo_session"]["status"] == "ready"
        assert readiness["workrequest_mcp"]["status"] == "companion_installed_not_enabled"
        assert readiness["workrequest_mcp"]["companion_config_key"] == "symphony-plus-plus-mcp@jonat-local"
        enable_action = Enum.find(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
        assert enable_action
        assert enable_action["message"] =~ ~s([plugins."symphony-plus-plus-mcp@jonat-local"])
        assert enable_action["command"] =~ "-EnableMcpCompanion"
        assert readiness["generic_review_boundary"] =~ "generic worker"

        {doctor_output, doctor_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Doctor"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_output
        assert doctor_output =~ "overall: solo_ready_mcp_companion_not_enabled"
        assert doctor_output =~ ~s([plugins."symphony-plus-plus-mcp@jonat-local"])
        assert doctor_output =~ "-EnableMcpCompanion"
        assert doctor_output =~ "Restart or reload that dedicated Codex session"
        assert doctor_output =~ "Keep symphony-plus-plus-mcp out of generic worker"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic self-test covers enable command TOML mutation shapes" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    if powershell do
      {output, status} =
        System.cmd(
          powershell,
          [
            "-NoProfile",
            "-File",
            @plugin_lifecycle_diagnostic_path,
            "-SelfTest"
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "diagnose-mcp-lifecycle self-test passed."
    end
  end

  test "enable command safely mutates only the MCP companion plugin config" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-#{System.unique_integer([:positive])}")

    initial_config = """
    [plugins."symphony-plus-plus@jonat-local"]
    enabled = true
    note = "caf\u00e9"

    [plugins."unrelated@jonat-local"]
    enabled = false

    [mcp_servers.other]
    url = "http://127.0.0.1:9999/mcp"
    """

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), initial_config)

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        result = Jason.decode!(json_output)
        assert result["status"] == "added_section"
        assert result["changed"] == true
        assert result["plugin_key"] == "symphony-plus-plus-mcp@jonat-local"
        assert result["restart_action"] =~ "Restart or reload"
        assert result["smoke_command"] =~ "smoke-sympp-mcp-http.ps1"
        assert result["boundary"] =~ "generic worker"

        config = File.read!(Path.join(temp_codex_home, "config.toml"))
        assert companion_plugin_section_present?(config)
        assert normalize_newlines(config) =~ ~s([plugins."symphony-plus-plus-mcp@jonat-local"]\nenabled = true)
        assert config =~ ~s([plugins."symphony-plus-plus@jonat-local"])
        assert config =~ ~s([plugins."unrelated@jonat-local"])
        assert config =~ "[mcp_servers.other]"
        assert config =~ "caf\u00e9"
        refute config =~ "[mcp_servers.symphony_plus_plus]"

        backups = config_backups(temp_codex_home)
        assert length(backups) == 1
        assert same_path?(result["backup_path"], List.first(backups))
        assert normalize_newlines(File.read!(List.first(backups))) == normalize_newlines(initial_config)
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "enable command keeps parser-sensitive embedded TOML text inert" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-parser-sensitive-#{System.unique_integer([:positive])}")

    initial_config =
      ~s([plugins."symphony-plus-plus-mcp@jonat-local"]\n) <>
        ~s(note = \"\"\"\n) <>
        ~s(enabled = false\n) <>
        ~s([plugins."not-a-real-section@jonat-local"]\n) <>
        ~s([mcp_servers.symphony_plus_plus]\n) <>
        ~s(\"\"\"\n)

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), initial_config)

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        result = Jason.decode!(json_output)
        assert result["status"] == "added_enabled"
        assert result["changed"] == true

        config = File.read!(Path.join(temp_codex_home, "config.toml"))

        assert normalize_newlines(config) =~
                 ~s(note = \"\"\"\nenabled = false\n[plugins."not-a-real-section@jonat-local"]\n[mcp_servers.symphony_plus_plus]\n\"\"\")

        {doctor_json, doctor_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_json
        doctor_summary = Jason.decode!(doctor_json)
        assert doctor_summary["codex_config"]["symphony_mcp_companion_plugin_enabled"] == true
        assert doctor_summary["codex_config"]["global_sympp_mcp_entry"] == false
        assert doctor_summary["readiness"]["workrequest_mcp"]["companion_plugin_enabled"] == true

        refute Enum.any?(
                 doctor_summary["readiness"]["next_actions"],
                 &(&1["code"] == "enable_mcp_companion")
               )
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "enable command refuses unsupported inline-table enabled shapes without config mutation" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    cases = [
      {"nested_inline",
       """
       [plugins]
       "symphony-plus-plus-mcp@jonat-local" = { note = { enabled = false } }
       """},
      {"bare_key_suffix",
       """
       [plugins]
       "symphony-plus-plus-mcp@jonat-local" = { noteenabled = false }
       """}
    ]

    if powershell do
      for {case_name, config} <- cases do
        temp_codex_home =
          Path.join(System.tmp_dir!(), "sympp-plugin-enable-unsupported-inline-#{case_name}-#{System.unique_integer([:positive])}")

        try do
          write_activation_cache(temp_codex_home, "jonat-local")
          File.mkdir_p!(temp_codex_home)
          File.write!(Path.join(temp_codex_home, "config.toml"), config)

          {doctor_output, doctor_status} =
            System.cmd(
              powershell,
              [
                "-NoProfile",
                "-File",
                @plugin_lifecycle_diagnostic_path,
                "-CodexHome",
                temp_codex_home,
                "-MarketplaceName",
                "jonat-local",
                "-Json"
              ],
              stderr_to_stdout: true
            )

          assert doctor_status == 0, doctor_output
          readiness = doctor_output |> Jason.decode!() |> Map.fetch!("readiness")
          assert readiness["overall_status"] == "mcp_companion_config_entry_unsupported"
          assert readiness["workrequest_mcp"]["status"] == "companion_config_entry_unsupported"

          assert Enum.any?(
                   readiness["next_actions"],
                   &(&1["code"] == "rewrite_mcp_companion_config_entry")
                 )

          refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

          {output, status} =
            System.cmd(
              powershell,
              [
                "-NoProfile",
                "-File",
                @plugin_lifecycle_diagnostic_path,
                "-CodexHome",
                temp_codex_home,
                "-MarketplaceName",
                "jonat-local",
                "-EnableMcpCompanion"
              ],
              stderr_to_stdout: true
            )

          assert status != 0
          assert output =~ "Target plugin inline table contains no supported enabled = true/false entry"
          assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
          assert config_backups(temp_codex_home) == []
        after
          File.rm_rf(temp_codex_home)
        end
      end
    end
  end

  test "diagnostic rejects duplicate companion enabled keys before enable command" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-duplicate-enabled-#{System.unique_integer([:positive])}")

    config = """
    [plugins."symphony-plus-plus-mcp@jonat-local"]
    enabled = false
    enabled = true
    """

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), config)

        {doctor_output, doctor_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_output
        readiness = doctor_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "mcp_companion_config_entry_unsupported"
        assert readiness["workrequest_mcp"]["status"] == "companion_config_entry_unsupported"

        assert Enum.any?(
                 readiness["next_actions"],
                 &(&1["code"] == "rewrite_mcp_companion_config_entry")
               )

        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "multiple enabled entries"
        assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "enable command refuses default Codex home" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    if powershell do
      for default_codex_home <- [Path.join(System.user_home!(), ".codex"), "~/.codex"] do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              default_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Refusing to enable symphony-plus-plus-mcp in the default Codex home"
      end
    end
  end

  test "enable command requires explicit CodexHome even when CODEX_HOME is set" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-implicit-home-#{System.unique_integer([:positive])}")

    config = """
    [plugins."symphony-plus-plus-mcp@jonat-local"]
    enabled = false
    """

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), config)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true,
            env: [{"CODEX_HOME", temp_codex_home}]
          )

        assert status != 0
        assert output =~ "without an explicit -CodexHome"
        assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "diagnostic does not advertise enable command for missing default Codex config" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    fake_home = Path.join(System.tmp_dir!(), "sympp-plugin-default-missing-#{System.unique_integer([:positive])}")
    default_codex_home = Path.join(fake_home, ".codex")

    if powershell do
      try do
        write_activation_cache(default_codex_home, "jonat-local")

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              "~/.codex",
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true,
            env: [{"HOME", fake_home}, {"USERPROFILE", fake_home}, {"HOMEDRIVE", ""}, {"HOMEPATH", ""}]
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        create_config = Enum.find(readiness["next_actions"], &(&1["code"] == "create_codex_config"))
        assert create_config["message"] =~ "Choose a dedicated Symphony++ MCP Codex home"
        refute create_config["message"] =~ "enable command below"
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "choose_dedicated_codex_home"))
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
      after
        File.rm_rf(fake_home)
      end
    end
  end

  test "diagnostic flags MCP companion enabled in default Codex home" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    fake_home = Path.join(System.tmp_dir!(), "sympp-plugin-default-home-#{System.unique_integer([:positive])}")
    default_codex_home = Path.join(fake_home, ".codex")

    if powershell do
      try do
        write_activation_cache(default_codex_home, "jonat-local")

        File.write!(
          Path.join(default_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true

          [plugins."symphony-plus-plus-mcp@jonat-local"]
          enabled = true
          """
        )

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              "~/.codex",
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true,
            env: [{"HOME", fake_home}, {"USERPROFILE", fake_home}, {"HOMEDRIVE", ""}, {"HOMEPATH", ""}]
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "default_codex_home_mcp_companion_enabled"
        assert readiness["workrequest_mcp"]["companion_plugin_enabled"] == true

        assert Enum.any?(
                 readiness["warnings"],
                 &(&1["code"] == "default_codex_home_mcp_companion_enabled")
               )

        assert Enum.any?(
                 readiness["next_actions"],
                 &(&1["code"] == "move_mcp_companion_to_dedicated_codex_home")
               )
      after
        File.rm_rf(fake_home)
      end
    end
  end

  test "enable command handles UTF-8 BOM config headers" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-bom-#{System.unique_integer([:positive])}")

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          <<0xEF, 0xBB, 0xBF>> <>
            """
            [plugins."symphony-plus-plus-mcp@jonat-local"]
            enabled = false
            """
        )

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        result = Jason.decode!(json_output)
        assert result["status"] == "enabled_existing_section"

        config = File.read!(Path.join(temp_codex_home, "config.toml"))
        assert String.starts_with?(config, <<0xEF, 0xBB, 0xBF>>)
        assert length(Regex.scan(~r/\[plugins\."symphony-plus-plus-mcp@jonat-local"\]/, config)) == 1
        assert config =~ "enabled = true"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "enable command preserves UTF-16 Codex config encoding" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-utf16-#{System.unique_integer([:positive])}")

    config_text = """
    [plugins."symphony-plus-plus-mcp@jonat-local"]
    note = "café"
    enabled = false
    """

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)

        utf16 = :unicode.characters_to_binary(config_text, :utf8, {:utf16, :little})
        File.write!(Path.join(temp_codex_home, "config.toml"), <<0xFF, 0xFE>> <> utf16)

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        result = Jason.decode!(json_output)
        assert result["status"] == "enabled_existing_section"

        encoded = File.read!(Path.join(temp_codex_home, "config.toml"))
        assert binary_part(encoded, 0, 2) == <<0xFF, 0xFE>>

        decoded =
          encoded
          |> binary_part(2, byte_size(encoded) - 2)
          |> :unicode.characters_to_binary({:utf16, :little}, :utf8)

        assert decoded =~ ~s(note = "café")
        assert decoded =~ "enabled = true"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "enable command prints restart and smoke verification commands" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-output-#{System.unique_integer([:positive])}")

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.write!(Path.join(temp_codex_home, "config.toml"), "")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Symphony++ MCP companion enable"
        assert output =~ "Next steps:"
        assert output =~ "Restart or reload the dedicated Symphony++ MCP Codex session"
        assert output =~ "smoke-sympp-mcp-http.ps1"
        assert output =~ "Keep symphony-plus-plus-mcp out of generic worker"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "enable command refuses missing companion cache without config mutation" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-missing-cache-#{System.unique_integer([:positive])}")

    config = """
    [plugins."symphony-plus-plus@jonat-local"]
    enabled = true
    """

    if powershell do
      try do
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), config)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Cannot enable symphony-plus-plus-mcp"
        assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "diagnostic does not offer enable command while global MCP footgun exists" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    cases = [
      {"section",
       """
       [plugins."symphony-plus-plus@jonat-local"]
       enabled = true

          [ mcp_servers . symphony_plus_plus ] # dedicated old workaround
       url = "http://127.0.0.1:4057/mcp"
       """},
      {"dotted",
       """
       mcp_servers.symphony_plus_plus.url = "http://127.0.0.1:4057/mcp"

       [plugins."symphony-plus-plus@jonat-local"]
       enabled = true
       """},
      {"mcp_servers_table",
       """
       [plugins."symphony-plus-plus@jonat-local"]
       enabled = true

       [mcp_servers]
       symphony_plus_plus.url = "http://127.0.0.1:4057/mcp"
       """}
    ]

    if powershell do
      for {case_name, config} <- cases do
        temp_codex_home =
          Path.join(
            System.tmp_dir!(),
            "sympp-plugin-enable-global-footgun-#{case_name}-#{System.unique_integer([:positive])}"
          )

        try do
          write_activation_cache(temp_codex_home, "jonat-local")
          File.mkdir_p!(temp_codex_home)
          File.write!(Path.join(temp_codex_home, "config.toml"), config)

          {json_output, status} =
            System.cmd(
              powershell,
              [
                "-NoProfile",
                "-File",
                @plugin_lifecycle_diagnostic_path,
                "-CodexHome",
                temp_codex_home,
                "-MarketplaceName",
                "jonat-local",
                "-Json"
              ],
              stderr_to_stdout: true
            )

          assert status == 0, "#{case_name}: #{json_output}"
          readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
          refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
          assert Enum.any?(readiness["next_actions"], &(&1["code"] == "relocate_global_sympp_mcp_entry"))
          assert readiness["overall_status"] == "global_footgun_present"

          {output, status} =
            System.cmd(
              powershell,
              [
                "-NoProfile",
                "-File",
                @plugin_lifecycle_diagnostic_path,
                "-CodexHome",
                temp_codex_home,
                "-MarketplaceName",
                "jonat-local",
                "-EnableMcpCompanion"
              ],
              stderr_to_stdout: true
            )

          assert status != 0
          assert output =~ "Codex config already contains [mcp_servers.symphony_plus_plus]"
          assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
          assert config_backups(temp_codex_home) == []
        after
          File.rm_rf(temp_codex_home)
        end
      end
    end
  end

  test "enable command allows mixed default marketplaces when MCP companion marketplace is unique" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-mixed-default-market-#{System.unique_integer([:positive])}")

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        write_activation_cache(temp_codex_home, "other-market")
        File.rm_rf!(plugin_cache_path(temp_codex_home, [], "symphony-plus-plus-mcp", "other-market"))
        File.mkdir_p!(temp_codex_home)

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@other-market"]
          enabled = true
          """
        )

        {doctor_output, doctor_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_output
        readiness = doctor_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["workrequest_mcp"]["companion_config_key"] == "symphony-plus-plus-mcp@jonat-local"
        assert readiness["workrequest_mcp"]["status"] == "companion_installed_not_enabled"
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "rerun_with_marketplace"))

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-EnableMcpCompanion",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        result = Jason.decode!(json_output)
        assert result["plugin_key"] == "symphony-plus-plus-mcp@jonat-local"
        assert result["status"] == "added_section"

        assert File.read!(Path.join(temp_codex_home, "config.toml")) =~
                 ~s([plugins."symphony-plus-plus-mcp@jonat-local"])
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "diagnostic and enable command reject another enabled MCP companion marketplace" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-other-mcp-marketplace-#{System.unique_integer([:positive])}")

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        write_activation_cache(temp_codex_home, "other-market")
        File.mkdir_p!(temp_codex_home)

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true

          [plugins."symphony-plus-plus-mcp@other-market"]
          enabled = true
          """
        )

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "mcp_companion_enabled_in_other_marketplace"
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "resolve_mcp_companion_marketplace_conflict"))
        assert Enum.any?(readiness["warnings"], &(&1["code"] == "other_marketplace_mcp_companion_enabled"))

        {enable_output, enable_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert enable_status != 0
        assert enable_output =~ "Another symphony-plus-plus-mcp marketplace is already enabled"
        refute File.read!(Path.join(temp_codex_home, "config.toml")) =~ "symphony-plus-plus-mcp@jonat-local"
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "diagnostic requires marketplace selection for split default and companion caches" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-split-marketplace-#{System.unique_integer([:positive])}")

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        write_activation_cache(temp_codex_home, "other-market")
        File.rm_rf!(plugin_cache_path(temp_codex_home, [], "symphony-plus-plus-mcp", "jonat-local"))
        File.rm_rf!(plugin_cache_path(temp_codex_home, [], "symphony-plus-plus", "other-market"))
        File.mkdir_p!(temp_codex_home)

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true
          """
        )

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "multiple_marketplaces_need_selection"
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "rerun_with_marketplace"))
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

        {enable_output, enable_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert enable_status != 0
        assert enable_output =~ "resolve to different marketplaces"
        refute File.read!(Path.join(temp_codex_home, "config.toml")) =~ "symphony-plus-plus-mcp"
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "diagnostic scopes aggregate plugin enablement to selected marketplace" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-marketplace-summary-#{System.unique_integer([:positive])}")

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        write_activation_cache(temp_codex_home, "other-market")
        File.mkdir_p!(temp_codex_home)

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = false

          [plugins."symphony-plus-plus-mcp@jonat-local"]
          enabled = false

          [plugins."symphony-plus-plus@other-market"]
          enabled = true

          [plugins."symphony-plus-plus-mcp@other-market"]
          enabled = true
          """
        )

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        summary = Jason.decode!(json_output)
        assert summary["codex_config"]["symphony_plugin_enabled"] == false
        assert summary["codex_config"]["symphony_default_plugin_enabled"] == false
        assert summary["codex_config"]["symphony_mcp_companion_plugin_enabled"] == false
        assert summary["readiness"]["overall_status"] == "mcp_companion_enabled_in_other_marketplace"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "diagnostic offers installed-script enable command without source checkout" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-installed-enable-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])

      try do
        File.mkdir_p!(Path.dirname(installed_script_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, installed_script_path)
        write_activation_cache(temp_codex_home, "jonat-local")

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true
          """
        )

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true,
            cd: temp_codex_home
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["source_checkout"]["status"] == "not_found"

        enable_action =
          Enum.find(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

        assert enable_action
        assert enable_action["command"] =~ "-EnableMcpCompanion"
        assert enable_action["command"] =~ "-CodexHome"
        assert normalize_path_fragment(enable_action["command"]) =~ normalize_path_fragment(installed_script_path)
        refute enable_action["message"] =~ "-RepoRoot"
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "restart_codex_session"))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic makes source-only repair commands path aware from installed cache" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-readiness-source-root-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])
      installed_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])
      installed_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      companion_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_old_version_manifest_path = plugin_cache_path(temp_codex_home, ["2.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_old_version_mcp_path = plugin_cache_path(temp_codex_home, ["2.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_old_version_hint_path = plugin_cache_path(temp_codex_home, ["2.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      companion_new_version_manifest_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_new_version_mcp_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_new_version_hint_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")

      run_diagnostic = fn cwd ->
        System.cmd(
          powershell,
          [
            "-NoProfile",
            "-File",
            installed_script_path,
            "-CodexHome",
            temp_codex_home,
            "-MarketplaceName",
            "jonat-local",
            "-Json"
          ],
          stderr_to_stdout: true,
          cd: cwd
        )
      end

      try do
        File.mkdir_p!(Path.dirname(installed_script_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, installed_script_path)

        {no_config_output, no_config_status} = run_diagnostic.(temp_codex_home)
        assert no_config_status == 0, no_config_output
        no_config_readiness = no_config_output |> Jason.decode!() |> Map.fetch!("readiness")

        create_config =
          Enum.find(no_config_readiness["next_actions"], &(&1["code"] == "create_codex_config"))

        assert create_config
        refute Map.has_key?(create_config, "command")
        assert create_config["message"] =~ "config.toml"

        File.write!(Path.join(temp_codex_home, "config.toml"), "")

        {current_output, current_status} = run_diagnostic.(@repo_root)
        assert current_status == 0, current_output
        current_readiness = current_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert current_readiness["source_checkout"]["status"] == "current_working_directory"
        assert same_path?(current_readiness["source_checkout"]["root"], @repo_root)

        current_refresh =
          Enum.find(current_readiness["next_actions"], &(&1["code"] == "refresh_default_plugin_cache"))

        assert current_refresh["command"] =~ "-CodexHome"
        assert current_refresh["command"] =~ "-MarketplaceName 'jonat-local'"
        assert normalize_path_fragment(current_refresh["command"]) =~ normalize_path_fragment(temp_codex_home)

        {missing_output, missing_status} = run_diagnostic.(temp_codex_home)
        assert missing_status == 0, missing_output
        missing_readiness = missing_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert missing_readiness["source_checkout"]["status"] == "not_found"

        missing_refresh =
          Enum.find(missing_readiness["next_actions"], &(&1["code"] == "refresh_default_plugin_cache"))

        assert missing_refresh
        refute Map.has_key?(missing_refresh, "command")
        assert missing_refresh["message"] =~ "-RepoRoot <path-to-symphony-plus-plus-checkout>"

        File.write!(installed_hint_path, "#{@repo_root}\n")

        {invalid_hint_output, invalid_hint_status} = run_diagnostic.(temp_codex_home)
        assert invalid_hint_status == 0, invalid_hint_output
        invalid_hint_readiness = invalid_hint_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert invalid_hint_readiness["source_checkout"]["status"] == "not_found"

        File.mkdir_p!(Path.dirname(installed_manifest_path))
        File.write!(installed_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))

        {hint_output, hint_status} = run_diagnostic.(temp_codex_home)
        assert hint_status == 0, hint_output
        hint_readiness = hint_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert hint_readiness["source_checkout"]["status"] == "installed_cache_source_root_hint"
        assert same_path?(hint_readiness["source_checkout"]["root"], @repo_root)

        companion_refresh =
          Enum.find(hint_readiness["next_actions"], &(&1["code"] == "refresh_mcp_companion_cache"))

        normalized_refresh_script = normalize_path_fragment(@refresh_script_path)
        assert normalize_path_fragment(companion_refresh["command"]) =~ normalized_refresh_script
        assert companion_refresh["command"] =~ "-CodexHome"
        assert companion_refresh["command"] =~ "-MarketplaceName 'jonat-local'"
        assert normalize_path_fragment(companion_refresh["command"]) =~ normalize_path_fragment(temp_codex_home)
        assert companion_refresh["command"] =~ "-PluginName symphony-plus-plus-mcp"
        refute companion_refresh["command"] =~ ".\\scripts\\refresh-local-plugin.ps1"

        File.mkdir_p!(Path.dirname(companion_local_manifest_path))

        File.write!(
          companion_local_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_local_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://example.invalid/mcp"}})
        )

        File.mkdir_p!(Path.dirname(companion_old_version_manifest_path))

        File.write!(
          companion_old_version_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "2.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_old_version_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})
        )

        File.write!(companion_old_version_hint_path, "#{@repo_root}\n")
        File.mkdir_p!(Path.dirname(companion_new_version_manifest_path))

        File.write!(
          companion_new_version_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "10.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_new_version_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})
        )

        File.write!(companion_new_version_hint_path, "#{@repo_root}\n")

        {valid_version_output, valid_version_status} = run_diagnostic.(temp_codex_home)
        assert valid_version_status == 0, valid_version_output
        valid_version_readiness = valid_version_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert valid_version_readiness["workrequest_mcp"]["status"] == "companion_installed_not_enabled"
        assert valid_version_readiness["workrequest_mcp"]["cache_label"] == "10.0.0"

        refute Enum.any?(
                 valid_version_readiness["next_actions"],
                 &(&1["code"] == "refresh_mcp_companion_cache")
               )
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic uses valid versioned cache hints when local cache has no source hint" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-versioned-source-hint-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])
      companion_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_version_manifest_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_version_mcp_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_version_hint_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(installed_script_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, installed_script_path)
        File.write!(Path.join(temp_codex_home, "config.toml"), "")
        File.mkdir_p!(Path.dirname(companion_local_manifest_path))

        File.write!(
          companion_local_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "10.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_local_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})
        )

        File.mkdir_p!(Path.dirname(companion_version_manifest_path))

        File.write!(
          companion_version_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "10.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_version_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})
        )

        File.write!(companion_version_hint_path, "#{@repo_root}\n")

        {json_output, json_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true,
            cd: temp_codex_home
          )

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["source_checkout"]["status"] == "installed_cache_source_root_hint"
        assert same_path?(readiness["source_checkout"]["root"], @repo_root)

        default_refresh =
          Enum.find(readiness["next_actions"], &(&1["code"] == "refresh_default_plugin_cache"))

        assert default_refresh["command"] =~ "-CodexHome"
        assert default_refresh["command"] =~ "-MarketplaceName 'jonat-local'"
        assert normalize_path_fragment(default_refresh["command"]) =~ normalize_path_fragment(@refresh_script_path)
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic ignores non-selected valid cache hints when preferred cache has a source hint" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-selected-source-hint-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])
      companion_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")
      companion_old_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_old_mcp_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_old_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      stale_source_root = Path.join(temp_codex_home, "stale-source")

      try do
        File.mkdir_p!(Path.join(stale_source_root, "elixir"))
        File.mkdir_p!(Path.join(stale_source_root, "scripts"))
        File.write!(Path.join(stale_source_root, "elixir/mix.exs"), "")
        File.write!(Path.join(stale_source_root, "scripts/refresh-local-plugin.ps1"), "")
        File.write!(Path.join(stale_source_root, "scripts/smoke-sympp-mcp-http.ps1"), "")
        File.mkdir_p!(Path.dirname(installed_script_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, installed_script_path)
        File.write!(Path.join(temp_codex_home, "config.toml"), "")

        mcp_config = Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})

        for {manifest_path, mcp_path, hint_path, version, source_root} <- [
              {companion_local_manifest_path, companion_local_mcp_path, companion_local_hint_path, "2.0.0", @repo_root},
              {companion_old_manifest_path, companion_old_mcp_path, companion_old_hint_path, "1.0.0", stale_source_root}
            ] do
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{source_root}\n")
        end

        {json_output, json_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true,
            cd: temp_codex_home
          )

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["source_checkout"]["status"] == "installed_cache_source_root_hint"
        assert same_path?(readiness["source_checkout"]["root"], @repo_root)

        default_refresh =
          Enum.find(readiness["next_actions"], &(&1["code"] == "refresh_default_plugin_cache"))

        assert normalize_path_fragment(default_refresh["command"]) =~ normalize_path_fragment(@refresh_script_path)
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic treats enabled MCP companion as a Solo skill provider" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-readiness-mcp-only-#{System.unique_integer([:positive])}")

    if powershell do
      companion_manifest_path =
        plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      companion_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(companion_manifest_path))

        File.write!(
          companion_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})
        )

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus-mcp@jonat-local"]
          enabled = true
          """
        )

        {json_output, json_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["solo_session"]["status"] == "ready_via_mcp_companion"
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_default_plugin"))
        assert readiness["session_visibility_note"] =~ "cannot inspect tools already registered"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic marks stale or broken cache manifests incompatible" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-#{System.unique_integer([:positive])}")

    if powershell do
      stale_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      stale_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"])
      stale_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])
      superseded_manifest_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".codex-plugin", "plugin.json"])
      superseded_mcp_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".mcp.json"])
      superseded_hint_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".sympp-source-root"])
      broken_mcp_path = plugin_cache_path(temp_codex_home, ["broken", ".mcp.json"])
      broken_hint_path = plugin_cache_path(temp_codex_home, ["broken", ".sympp-source-root"])
      malformed_manifest_path = plugin_cache_path(temp_codex_home, ["malformed", ".codex-plugin", "plugin.json"])
      malformed_mcp_path = plugin_cache_path(temp_codex_home, ["malformed", ".mcp.json"])
      malformed_hint_path = plugin_cache_path(temp_codex_home, ["malformed", ".sympp-source-root"])
      bad_reference_manifest_path = plugin_cache_path(temp_codex_home, ["bad-reference", ".codex-plugin", "plugin.json"])
      bad_reference_mcp_path = plugin_cache_path(temp_codex_home, ["bad-reference", ".mcp.json"])
      bad_reference_hint_path = plugin_cache_path(temp_codex_home, ["bad-reference", ".sympp-source-root"])

      File.mkdir_p!(Path.dirname(stale_manifest_path))
      File.mkdir_p!(Path.dirname(superseded_manifest_path))
      File.mkdir_p!(Path.dirname(broken_mcp_path))
      File.mkdir_p!(Path.dirname(malformed_manifest_path))
      File.mkdir_p!(Path.dirname(bad_reference_manifest_path))

      File.write!(
        Path.join(temp_codex_home, "config.toml"),
        """
        [plugins."symphony-plus-plus@jonat-local"]
        enabled = false

        [plugins."symphony-plus-plus-mcp@jonat-local"]
        enabled = true
        """
      )

      File.write!(
        stale_manifest_path,
        Jason.encode!(%{
          "name" => "symphony-plus-plus",
          "version" => "0.1.1",
          "mcpServers" => "./.mcp.json"
        })
      )

      File.write!(
        stale_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => [
              "-NoProfile",
              "-Command",
              "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
            ],
            "cwd" => "."
          }
        })
      )

      File.write!(superseded_manifest_path, File.read!(stale_manifest_path))
      File.write!(superseded_mcp_path, File.read!(stale_mcp_path))

      File.write!(
        broken_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh"
          }
        })
      )

      File.write!(stale_hint_path, "C:/sympp/repo-one\n")
      File.write!(superseded_hint_path, "C:/sympp/repo-two\n")
      File.write!(broken_hint_path, "C:/sympp/repo-two\n")
      File.write!(malformed_manifest_path, "{")
      File.write!(malformed_hint_path, "C:/sympp/repo-three\n")

      File.write!(
        bad_reference_manifest_path,
        Jason.encode!(%{
          "name" => "symphony-plus-plus",
          "version" => "0.1.2"
        })
      )

      File.write!(
        bad_reference_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      File.write!(bad_reference_hint_path, "C:/sympp/repo-four\n")

      File.write!(
        malformed_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh"
          }
        })
      )

      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        caches = Map.fetch!(report, "installed_cache")
        config_entries = report["codex_config"]["symphony_plugin_entries"]

        stale_cache =
          caches
          |> Enum.find(&(&1["label"] == "local"))

        superseded_cache =
          caches
          |> Enum.find(&(&1["label"] == "0.1.1"))

        broken_cache =
          caches
          |> Enum.find(&(&1["label"] == "broken"))

        malformed_cache =
          caches
          |> Enum.find(&(&1["label"] == "malformed"))

        bad_reference_cache =
          caches
          |> Enum.find(&(&1["label"] == "bad-reference"))

        assert stale_cache["manifest_mcpServers_declared"] == true
        assert stale_cache["default_plugin_lifecycle_status"] == "incompatible_default_plugin_bundles_mcp"
        assert stale_cache["reference_mcp_server_status"] == "ok"
        assert stale_cache["symphony_plus_plus_server"] == "incompatible_default_plugin_bundles_mcp"

        assert superseded_cache["default_plugin_lifecycle_status"] == "incompatible_default_plugin_bundles_mcp"
        assert superseded_cache["reference_mcp_server_status"] == "ok"

        assert broken_cache["manifest_exists"] == false
        assert broken_cache["default_plugin_lifecycle_status"] == "missing_manifest"
        assert broken_cache["reference_mcp_server_status"] == "invalid_cwd"
        assert broken_cache["symphony_plus_plus_server"] == "missing_manifest"

        assert malformed_cache["default_plugin_lifecycle_status"] == "manifest_parse_error"
        assert malformed_cache["reference_mcp_server_status"] == "invalid_cwd"
        assert malformed_cache["symphony_plus_plus_server"] == "manifest_parse_error"

        assert bad_reference_cache["default_plugin_lifecycle_status"] == "incompatible_default_plugin_bundles_mcp"
        assert bad_reference_cache["reference_mcp_server_status"] == "invalid_args"
        assert bad_reference_cache["symphony_plus_plus_server"] == "incompatible_default_plugin_bundles_mcp"

        assert report["codex_config"]["symphony_plugin_enabled"] == true
        assert Enum.any?(config_entries, &(&1["plugin_name"] == "symphony-plus-plus" and &1["enabled"] == false))
        assert Enum.any?(config_entries, &(&1["plugin_name"] == "symphony-plus-plus-mcp" and &1["enabled"] == true))

        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [repo_filter] = report["process_repo_root_filters"]
        assert String.replace(repo_filter, "\\", "/") == "c:/sympp/repo-one"
        assert report["live_process_counts"]["erl_sympp_mcp"] == 0
        assert report["live_process_counts"]["start_sympp_mcp_pwsh_unattributed"] == 0
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic infers process scope from installed opt-in cache when package versions differ" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_root = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-drift-#{System.unique_integer([:positive])}")

    if powershell do
      default_version = "1.0.0"
      opt_in_version = "2.0.0"
      temp_codex_home = Path.join(temp_root, "codex-home")
      default_cache_manifest_path = plugin_cache_path(temp_codex_home, [default_version, ".codex-plugin", "plugin.json"])
      default_cache_hint_path = plugin_cache_path(temp_codex_home, [default_version, ".sympp-source-root"])
      diagnostic_path = plugin_cache_path(temp_codex_home, [default_version, "scripts", "diagnose-mcp-lifecycle.ps1"])

      opt_in_cache_manifest_path =
        plugin_cache_path(temp_codex_home, [opt_in_version, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      opt_in_cache_mcp_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_cache_hint_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".sympp-source-root"], "symphony-plus-plus-mcp")
      opt_in_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      mcp_config =
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => [
              "-NoProfile",
              "-Command",
              "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
            ],
            "cwd" => "."
          }
        })

      try do
        File.mkdir_p!(Path.dirname(default_cache_manifest_path))
        File.mkdir_p!(Path.dirname(diagnostic_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, diagnostic_path)
        File.write!(default_cache_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => default_version}))
        File.write!(default_cache_hint_path, "C:/sympp/repo-one\n")

        File.mkdir_p!(Path.dirname(opt_in_cache_manifest_path))

        File.write!(
          opt_in_cache_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => opt_in_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(opt_in_cache_mcp_path, mcp_config)
        File.write!(opt_in_cache_hint_path, "C:/sympp/repo-one\n")
        File.mkdir_p!(Path.dirname(opt_in_local_manifest_path))
        File.write!(opt_in_local_manifest_path, "{")
        File.write!(opt_in_local_mcp_path, mcp_config)
        File.write!(opt_in_local_hint_path, "C:/sympp/broken-local\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        caches = Map.fetch!(report, "installed_cache")
        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [repo_filter] = report["process_repo_root_filters"]
        assert String.replace(repo_filter, "\\", "/") == "c:/sympp/repo-one"

        assert Enum.any?(
                 caches,
                 &(&1["package_name"] == "symphony-plus-plus" and
                     &1["label"] == default_version and
                     &1["reference_mcp_server_status"] == "not_configured")
               )

        assert Enum.any?(
                 caches,
                 &(&1["package_name"] == "symphony-plus-plus-mcp" and
                     &1["label"] == opt_in_version and
                     &1["reference_mcp_server_status"] == "ok")
               )
      after
        File.rm_rf(temp_root)
      end
    end
  end

  test "lifecycle diagnostic does not scope source runs from stale installed opt-in cache versions" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-source-drift-#{System.unique_integer([:positive])}")

    if powershell do
      opt_in_version = "2.0.0"

      opt_in_cache_manifest_path =
        plugin_cache_path(temp_codex_home, [opt_in_version, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      opt_in_cache_mcp_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_cache_hint_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(opt_in_cache_manifest_path))

        File.write!(
          opt_in_cache_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => opt_in_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          opt_in_cache_mcp_path,
          Jason.encode!(%{
            "symphony_plus_plus" => %{
              "type" => "stdio",
              "command" => "pwsh",
              "args" => [
                "-NoProfile",
                "-Command",
                "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
              ],
              "cwd" => "."
            }
          })
        )

        File.write!(opt_in_cache_hint_path, "C:/sympp/repo-one\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic ignores stale opt-in local cache when source version differs" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-stale-local-#{System.unique_integer([:positive])}")

    if powershell do
      opt_in_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "0.0.1", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          opt_in_mcp_path,
          Jason.encode!(%{
            "symphony_plus_plus" => %{
              "type" => "stdio",
              "command" => "pwsh",
              "args" => [
                "-NoProfile",
                "-Command",
                "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
              ],
              "cwd" => "."
            }
          })
        )

        File.write!(opt_in_hint_path, "C:/sympp/stale-local\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic ignores opt-in local cache when no current opt-in version is known" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-unknown-current-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      opt_in_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))
        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "0.0.1", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          opt_in_mcp_path,
          Jason.encode!(%{
            "symphony_plus_plus" => %{
              "type" => "stdio",
              "command" => "pwsh",
              "args" => [
                "-NoProfile",
                "-Command",
                "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
              ],
              "cwd" => "."
            }
          })
        )

        File.write!(opt_in_hint_path, "C:/sympp/stale-local\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic scopes hinted installed default cache from opt-in local cache" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-only-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      opt_in_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))
        File.write!(default_hint_path, "C:/sympp/default\n")
        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "2.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          opt_in_mcp_path,
          Jason.encode!(%{
            "symphony_plus_plus" => %{
              "type" => "stdio",
              "command" => "pwsh",
              "args" => [
                "-NoProfile",
                "-Command",
                "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
              ],
              "cwd" => "."
            }
          })
        )

        File.write!(opt_in_hint_path, "C:/sympp/local\n")
        refute File.exists?(plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp"))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [repo_filter] = report["process_repo_root_filters"]
        assert String.replace(repo_filter, "\\", "/") == "c:/sympp/local"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic prefers current versioned opt-in cache over stale local cache" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-stale-local-versioned-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")
      versioned_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      versioned_mcp_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      versioned_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")

      mcp_config =
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => [
              "-NoProfile",
              "-Command",
              "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
            ],
            "cwd" => "."
          }
        })

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))
        File.write!(default_hint_path, "C:/sympp/default\n")

        for {manifest_path, mcp_path, hint_path, version, repo_root} <- [
              {local_manifest_path, local_mcp_path, local_hint_path, "0.0.1", "C:/sympp/stale-local"},
              {versioned_manifest_path, versioned_mcp_path, versioned_hint_path, "1.0.0", "C:/sympp/current-versioned"}
            ] do
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [repo_filter] = report["process_repo_root_filters"]
        assert String.replace(repo_filter, "\\", "/") == "c:/sympp/current-versioned"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic preserves ambiguity when current opt-in local and versioned hints differ" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-versioned-ambiguous-#{System.unique_integer([:positive])}")

    if powershell do
      mcp_config =
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => [
              "-NoProfile",
              "-Command",
              "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
            ],
            "cwd" => "."
          }
        })

      try do
        for {label, repo_root} <- [{"local", "C:/sympp/local"}, {@plugin_version, "C:/sympp/versioned"}] do
          manifest_path = plugin_cache_path(temp_codex_home, [label, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
          mcp_path = plugin_cache_path(temp_codex_home, [label, ".mcp.json"], "symphony-plus-plus-mcp")
          hint_path = plugin_cache_path(temp_codex_home, [label, ".sympp-source-root"], "symphony-plus-plus-mcp")
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_ambiguous_cache_source_root_hints"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic keeps opt-in local precedence marketplace scoped" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-marketplace-scope-#{System.unique_integer([:positive])}")

    if powershell do
      mcp_config =
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => [
              "-NoProfile",
              "-Command",
              "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
            ],
            "cwd" => "."
          }
        })

      try do
        for {marketplace, label, repo_root} <- [
              {"market-a", "local", "C:/sympp/market-a"},
              {"market-b", @plugin_version, "C:/sympp/market-b"}
            ] do
          manifest_path = plugin_cache_path(temp_codex_home, [label, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp", marketplace)
          mcp_path = plugin_cache_path(temp_codex_home, [label, ".mcp.json"], "symphony-plus-plus-mcp", marketplace)
          hint_path = plugin_cache_path(temp_codex_home, [label, ".sympp-source-root"], "symphony-plus-plus-mcp", marketplace)
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "*",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_ambiguous_cache_source_root_hints"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic prefers refreshed opt-in local cache over same-version companion" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-precedence-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      versioned_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      versioned_mcp_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      versioned_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      mcp_config =
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => [
              "-NoProfile",
              "-Command",
              "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
            ],
            "cwd" => "."
          }
        })

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))

        for {manifest_path, mcp_path, hint_path, version, repo_root} <- [
              {versioned_manifest_path, versioned_mcp_path, versioned_hint_path, "1.0.0", "C:/sympp/versioned"},
              {local_manifest_path, local_mcp_path, local_hint_path, "2.0.0", "C:/sympp/local"}
            ] do
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [repo_filter] = report["process_repo_root_filters"]
        assert String.replace(repo_filter, "\\", "/") == "c:/sympp/local"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic ignores superseded opt-in cache versions when source version is installed" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-superseded-#{System.unique_integer([:positive])}")

    if powershell do
      current_version = @plugin_version
      stale_version = "0.0.1"

      try do
        for {version, repo_root} <- [{current_version, "C:/sympp/repo-one"}, {stale_version, "C:/sympp/old-repo"}] do
          manifest_path = plugin_cache_path(temp_codex_home, [version, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
          mcp_path = plugin_cache_path(temp_codex_home, [version, ".mcp.json"], "symphony-plus-plus-mcp")
          hint_path = plugin_cache_path(temp_codex_home, [version, ".sympp-source-root"], "symphony-plus-plus-mcp")
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(
            mcp_path,
            Jason.encode!(%{
              "symphony_plus_plus" => %{
                "type" => "stdio",
                "command" => "pwsh",
                "args" => [
                  "-NoProfile",
                  "-Command",
                  "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
                ],
                "cwd" => "."
              }
            })
          )

          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [repo_filter] = report["process_repo_root_filters"]
        assert String.replace(repo_filter, "\\", "/") == "c:/sympp/repo-one"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic does not scope live process scan from default-only cache hint" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-default-only-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])

      try do
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))
        File.write!(default_hint_path, "C:/sympp/repo-one\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic prefers opt-in MCP cache hints over MCP-free default hints" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-opt-in-precedence-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])

      opt_in_manifest_path =
        plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))
        File.write!(default_hint_path, "C:/sympp/repo-one\n")

        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          opt_in_mcp_path,
          Jason.encode!(%{
            "symphony_plus_plus" => %{
              "type" => "stdio",
              "command" => "pwsh",
              "args" => [
                "-NoProfile",
                "-Command",
                "$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/start-sympp-mcp.ps1'"
              ],
              "cwd" => "."
            }
          })
        )

        File.write!(opt_in_hint_path, "C:/sympp/repo-two\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [repo_filter] = report["process_repo_root_filters"]
        assert String.replace(repo_filter, "\\", "/") == "c:/sympp/repo-two"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "refresh script installs the repo-local plugin into the requested Codex home" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        for cache_name <- ["local", @plugin_version] do
          refreshed_manifest_path = plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
          refreshed_mcp_path = plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
          default_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-solo-session", "SKILL.md"])
          root_skills_path = plugin_cache_path(temp_codex_home, [cache_name, "skills"])
          source_hint_path = plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])

          refreshed_manifest = refreshed_manifest_path |> File.read!() |> Jason.decode!()
          assert refreshed_manifest["name"] == "symphony-plus-plus"
          assert refreshed_manifest["version"] == @plugin_version
          assert refreshed_manifest["skills"] == "./skills-default/"
          refute Map.has_key?(refreshed_manifest, "mcpServers")
          assert File.read!(default_skill_path) == File.read!(@plugin_default_solo_skill_path)
          refute File.exists?(root_skills_path)
          refute File.exists?(refreshed_mcp_path)
          assert same_path?(String.trim(File.read!(source_hint_path)), @repo_root)
        end

        for cache_name <- ["local", @plugin_version] do
          mcp_manifest_path =
            plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

          mcp_config_path = plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"], "symphony-plus-plus-mcp")
          mcp_solo_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_worker_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-work-package", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_architect_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_manifest = mcp_manifest_path |> File.read!() |> Jason.decode!()
          mcp_config = mcp_config_path |> File.read!() |> Jason.decode!()
          assert mcp_manifest["name"] == "symphony-plus-plus-mcp"
          assert mcp_manifest["mcpServers"] == "./.mcp.json"
          refute File.exists?(mcp_solo_skill_path)
          assert File.read!(mcp_worker_skill_path) == File.read!(@mcp_plugin_skill_path)
          assert File.read!(mcp_architect_skill_path) == File.read!(@mcp_plugin_architect_skill_path)

          assert get_in(documented_mcp_server_map(mcp_config), ["symphony_plus_plus", "url"]) ==
                   "http://127.0.0.1:4057/mcp"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "refresh script validates installed cache MCP config and wrapper from cache roots" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      try do
        expected_version =
          @plugin_manifest_path
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("version")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home,
              "-ValidateInstalledCache"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Validated installed Symphony++ plugin cache:"
        assert output =~ "cache: local"
        assert output =~ "cache: #{expected_version}"

        for cache_name <- ["local", expected_version] do
          source_hint_path = plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])
          assert same_path?(String.trim(File.read!(source_hint_path)), @repo_root)
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "refresh script installs and validates the opt-in MCP plugin" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-mcp-refresh")

    if powershell do
      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @refresh_script_path,
              "-PluginName",
              "symphony-plus-plus-mcp",
              "-CodexHome",
              temp_codex_home,
              "-ValidateInstalledCache"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Validated installed Symphony++ plugin cache:"
        assert output =~ "cache: local"
        assert output =~ "cache: #{@plugin_version}"

        for cache_name <- ["local", @plugin_version] do
          manifest_path =
            plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

          source_hint_path = plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"], "symphony-plus-plus-mcp")

          manifest = manifest_path |> File.read!() |> Jason.decode!()
          assert manifest["name"] == "symphony-plus-plus-mcp"
          assert manifest["version"] == @plugin_version
          assert manifest["mcpServers"] == "./.mcp.json"
          refute File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session"], "symphony-plus-plus-mcp"))
          assert File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-work-package", "SKILL.md"], "symphony-plus-plus-mcp"))
          assert File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"], "symphony-plus-plus-mcp"))
          assert same_path?(String.trim(File.read!(source_hint_path)), @repo_root)
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "refresh script overlays local and manifest-version caches without deleting unrelated entries" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      for cache_name <- ["local", @plugin_version] do
        stale_manifest_path = plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
        stale_mcp_path = plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
        stale_root_solo_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"])
        stale_root_architect_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"])
        stale_mcp_solo_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"], "symphony-plus-plus-mcp")
        marker_path = plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])

        File.mkdir_p!(Path.dirname(stale_manifest_path))
        File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "stale"}))
        File.write!(stale_mcp_path, Jason.encode!(%{"mcpServers" => %{}}))
        File.mkdir_p!(Path.dirname(stale_root_solo_skill_path))
        File.write!(stale_root_solo_skill_path, "stale duplicate skill")
        File.mkdir_p!(Path.dirname(stale_root_architect_skill_path))
        File.write!(stale_root_architect_skill_path, "stale default architect skill")
        File.mkdir_p!(Path.dirname(stale_mcp_solo_skill_path))
        File.write!(stale_mcp_solo_skill_path, "stale mcp solo duplicate")
        File.mkdir_p!(Path.dirname(marker_path))
        File.write!(marker_path, "preserve #{cache_name}")
      end

      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        for cache_name <- ["local", @plugin_version] do
          manifest =
            temp_codex_home
            |> plugin_cache_path([cache_name, ".codex-plugin", "plugin.json"])
            |> File.read!()
            |> Jason.decode!()

          assert manifest["version"] == @plugin_version
          refute Map.has_key?(manifest, "mcpServers")
          refute File.exists?(plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"]))
          refute File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills"]))
          refute File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session"], "symphony-plus-plus-mcp"))
          assert File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-work-package", "SKILL.md"], "symphony-plus-plus-mcp"))
          assert File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"], "symphony-plus-plus-mcp"))

          assert File.read!(plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])) ==
                   "preserve #{cache_name}"
        end
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "refresh script rejects unresolved marketplace source paths" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")
    marketplace_path = unique_temp_path("sympp-marketplace") <> ".json"

    if powershell do
      marketplace = %{
        name: "jonat-local",
        plugins: [
          %{
            name: "symphony-plus-plus",
            source: %{source: "local", path: "missing/symphony-plus-plus"},
            policy: %{installation: "AVAILABLE", authentication: "ON_USE"},
            category: "Coding"
          }
        ]
      }

      try do
        File.write!(marketplace_path, Jason.encode!(marketplace))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-MarketplacePath",
              marketplace_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Configured plugin source path"
        refute File.exists?(plugin_cache_path(temp_codex_home, []))
      after
        File.rm(marketplace_path)
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "refresh script resolves repo-root relative source paths from marketplace file" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    marketplace_path =
      Path.join(@repo_root, "plugins/symphony-plus-plus/sympp-marketplace-test-#{unique_id()}.json")

    if powershell do
      marketplace = %{
        name: "jonat-local",
        plugins: [
          %{
            name: "symphony-plus-plus",
            source: %{source: "local", path: "./plugins/symphony-plus-plus"},
            policy: %{installation: "AVAILABLE", authentication: "ON_USE"},
            category: "Coding"
          }
        ]
      }

      try do
        File.write!(marketplace_path, Jason.encode!(marketplace))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-MarketplacePath",
              marketplace_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        refreshed_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
        refreshed_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"])

        assert refreshed_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("name") == "symphony-plus-plus"
        refute File.exists?(refreshed_mcp_path)
      after
        File.rm(marketplace_path)
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "refresh script repairs incompatible generated default caches only" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      stale_manifest_path = plugin_cache_path(temp_codex_home, ["0.0.9", ".codex-plugin", "plugin.json"])
      sentinel_path = plugin_cache_path(temp_codex_home, ["0.0.9", "already-open.txt"])
      incompatible_manifest_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".codex-plugin", "plugin.json"])
      incompatible_mcp_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".mcp.json"])
      incompatible_hint_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".sympp-source-root"])
      malformed_manifest_path = plugin_cache_path(temp_codex_home, ["malformed-old", ".codex-plugin", "plugin.json"])
      malformed_mcp_path = plugin_cache_path(temp_codex_home, ["malformed-old", ".mcp.json"])
      malformed_hint_path = plugin_cache_path(temp_codex_home, ["malformed-old", ".sympp-source-root"])
      missing_manifest_mcp_path = plugin_cache_path(temp_codex_home, ["missing-manifest", ".mcp.json"])
      missing_manifest_hint_path = plugin_cache_path(temp_codex_home, ["missing-manifest", ".sympp-source-root"])
      manual_semver_mcp_path = plugin_cache_path(temp_codex_home, ["1.2.3", ".mcp.json"])
      manual_manifest_path = plugin_cache_path(temp_codex_home, ["manual-default", ".codex-plugin", "plugin.json"])
      manual_manifest_mcp_path = plugin_cache_path(temp_codex_home, ["manual-default", ".mcp.json"])
      scratch_path = plugin_cache_path(temp_codex_home, ["scratch", "note.txt"])
      scratch_mcp_path = plugin_cache_path(temp_codex_home, ["scratch", ".mcp.json"])
      File.mkdir_p!(Path.dirname(stale_manifest_path))
      File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.0.9"}))
      File.write!(sentinel_path, "preserve")
      File.mkdir_p!(Path.dirname(incompatible_manifest_path))

      File.write!(
        incompatible_manifest_path,
        Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.1.1", "mcpServers" => "./.mcp.json"})
      )

      File.write!(incompatible_hint_path, "C:/sympp/generated\n")

      File.write!(
        incompatible_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      File.mkdir_p!(Path.dirname(malformed_manifest_path))
      File.write!(malformed_manifest_path, "{")
      File.write!(malformed_hint_path, "C:/sympp/generated\n")

      File.write!(
        malformed_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      File.mkdir_p!(Path.dirname(missing_manifest_mcp_path))
      File.write!(missing_manifest_hint_path, "C:/sympp/generated\n")

      File.write!(
        missing_manifest_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      File.mkdir_p!(Path.dirname(manual_semver_mcp_path))
      File.write!(manual_semver_mcp_path, Jason.encode!(%{"manual" => true}))
      File.mkdir_p!(Path.dirname(manual_manifest_path))

      File.write!(
        manual_manifest_path,
        Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "manual", "mcpServers" => "./.mcp.json"})
      )

      File.write!(manual_manifest_mcp_path, Jason.encode!(%{"manual" => true}))
      File.mkdir_p!(Path.dirname(scratch_path))
      File.write!(scratch_path, "do not touch")
      File.write!(scratch_mcp_path, Jason.encode!(%{"manual" => true}))

      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Repaired incompatible default Symphony++ plugin cache"

        versioned_manifest =
          plugin_cache_path(temp_codex_home, [@plugin_version, ".codex-plugin", "plugin.json"])
          |> File.read!()
          |> Jason.decode!()

        refute Map.has_key?(versioned_manifest, "mcpServers")
        refute File.exists?(plugin_cache_path(temp_codex_home, [@plugin_version, ".mcp.json"]))
        assert plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"]) |> File.exists?()

        repaired_manifest =
          plugin_cache_path(temp_codex_home, ["0.1.1", ".codex-plugin", "plugin.json"])
          |> File.read!()
          |> Jason.decode!()

        refute Map.has_key?(repaired_manifest, "mcpServers")
        refute File.exists?(plugin_cache_path(temp_codex_home, ["0.1.1", ".mcp.json"]))
        assert File.exists?(plugin_cache_path(temp_codex_home, ["malformed-old"]))
        refute File.exists?(plugin_cache_path(temp_codex_home, ["malformed-old", ".mcp.json"]))
        assert File.exists?(plugin_cache_path(temp_codex_home, ["missing-manifest"]))
        refute File.exists?(plugin_cache_path(temp_codex_home, ["missing-manifest", ".mcp.json"]))
        refute File.exists?(plugin_cache_path(temp_codex_home, ["0.0.9", ".mcp.json"]))
        assert File.exists?(manual_semver_mcp_path)
        manual_manifest = manual_manifest_path |> File.read!() |> Jason.decode!()
        assert Map.has_key?(manual_manifest, "mcpServers")
        assert File.exists?(manual_manifest_mcp_path)
        assert File.read!(sentinel_path) == "preserve"
        assert File.read!(scratch_path) == "do not touch"
        assert File.exists?(scratch_mcp_path)
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "refresh script repairs stale default MCP artifacts during MCP-only refresh" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh-mcp-only")

    if powershell do
      stale_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      stale_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"])
      stale_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])

      try do
        File.mkdir_p!(Path.dirname(stale_manifest_path))

        File.write!(
          stale_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.1.1", "mcpServers" => "./.mcp.json"})
        )

        File.write!(stale_mcp_path, Jason.encode!(%{"symphony_plus_plus" => %{"type" => "stdio", "command" => "pwsh", "args" => ["-NoProfile"], "cwd" => "."}}))
        File.write!(stale_hint_path, "C:/sympp/generated\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home,
              "-PluginName",
              "symphony-plus-plus-mcp"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Repaired incompatible default Symphony++ plugin cache"

        repaired_manifest = stale_manifest_path |> File.read!() |> Jason.decode!()
        refute Map.has_key?(repaired_manifest, "mcpServers")
        refute File.exists?(stale_mcp_path)
        assert File.exists?(plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp"))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "template skill mirrors installable skill metadata" do
    skill = File.read!(@skill_path)
    template_skill = File.read!(@template_skill_path)

    assert frontmatter(skill) == frontmatter(template_skill)

    for file <- ["worker_prompt.md", "mcp_wiring.md", "handoff.md"] do
      assert File.exists?(Path.join(@template_references_dir, file))
    end
  end

  test "handoff docs include skill installation and MCP setup" do
    handoff = File.read!(@handoff_path)
    runbook = File.read!(@runbook_path)

    for content <- [handoff, runbook] do
      assert content =~ ".codex/skills/symphony-work-package/"
      assert content =~ "plugins/symphony-plus-plus-mcp/"
      assert content =~ "mcp_wiring.md"
      assert content =~ "templates/worker_agent_prompt.md"
    end
  end

  test "MCP contract lists the current worker tools" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    actual_tools = Enum.map(contract["worker_tools"], & &1["name"])

    assert actual_tools == @worker_tools
    refute "request_context" in actual_tools
  end

  test "MCP contract enum constraints mirror runtime values" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    architect_tools = Map.new(contract["architect_tools"], &{&1["name"], &1})

    assert get_in(architect_tools, ["record_work_request_decision", "argument_constraints", "source_type"]) ==
             DecisionLogEntry.source_types()

    assert get_in(architect_tools, ["add_work_request_planned_slice", "argument_constraints", "work_package_kind"]) ==
             StateMachine.standalone_kinds()
  end

  defp frontmatter(content) do
    [_, metadata | _rest] = String.split(content, "---", parts: 3)
    String.trim(metadata)
  end

  defp same_path?(left, right) do
    Path.expand(left) |> String.downcase() == Path.expand(right) |> String.downcase()
  end

  defp normalize_path_fragment(value) do
    value
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  defp normalize_newlines(value) do
    String.replace(value, "\r\n", "\n")
  end

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
  end

  defp unique_id do
    id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
  end

  defp companion_plugin_section_present?(config) do
    Regex.match?(
      ~r/\[\s*(?:plugins|"plugins"|'plugins')\s*\.\s*(?:"symphony-plus-plus-mcp@jonat-local"|'symphony-plus-plus-mcp@jonat-local')\s*\]/,
      config
    )
  end

  defp write_activation_cache(codex_home, marketplace_name) do
    default_manifest_path =
      plugin_cache_path(codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus", marketplace_name)

    companion_manifest_path =
      plugin_cache_path(codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp", marketplace_name)

    companion_mcp_path = plugin_cache_path(codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp", marketplace_name)

    File.mkdir_p!(Path.dirname(default_manifest_path))
    File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))

    File.mkdir_p!(Path.dirname(companion_manifest_path))

    File.write!(
      companion_manifest_path,
      Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
    )

    File.write!(
      companion_mcp_path,
      Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://127.0.0.1:4057/mcp"}})
    )
  end

  defp config_backups(codex_home) do
    codex_home
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "config.toml.sympp-backup-"))
    |> Enum.map(&Path.join(codex_home, &1))
    |> Enum.sort()
  end

  defp documented_mcp_server_map(%{"mcpServers" => _}) do
    flunk("plugin .mcp.json must use a documented direct server map or wrapped mcp_servers shape")
  end

  defp documented_mcp_server_map(%{"mcp_servers" => server_map}), do: server_map
  defp documented_mcp_server_map(server_map), do: server_map

  defp plugin_cache_path(codex_home, suffix, plugin_name \\ "symphony-plus-plus", marketplace_name \\ "jonat-local") do
    Path.join([codex_home, "plugins", "cache", marketplace_name, plugin_name] ++ suffix)
  end
end
