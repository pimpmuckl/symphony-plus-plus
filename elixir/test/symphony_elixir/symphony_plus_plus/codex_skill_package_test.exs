defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @skill_path Path.join(@repo_root, ".codex/skills/symphony-work-package/SKILL.md")
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
  @plugin_mcp_path Path.join(@repo_root, "plugins/symphony-plus-plus/.mcp.json")
  @plugin_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-work-package/SKILL.md")
  @plugin_root_solo_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-solo-session/SKILL.md")
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
  @plugin_wiring_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-work-package/references/mcp_wiring.md")
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
    plugin_wiring = File.read!(@plugin_wiring_path)
    template_wiring = File.read!(Path.join(@template_references_dir, "mcp_wiring.md"))

    assert wiring =~ "http://127.0.0.1:4057/mcp"
    assert wiring =~ "mix sympp.cockpit --database <ledger-path>"
    assert wiring =~ "--port 0"
    assert wiring =~ "[mcp_servers.symphony_plus_plus]"
    assert wiring =~ "url = \"http://127.0.0.1:4057/mcp\""
    assert wiring =~ "sympp-worker-secret.ps1"
    assert wiring =~ "sympp-worker-secret.sh"
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

  test "Codex plugin package mirrors the repo-local worker skill" do
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
    assert File.read!(@plugin_skill_path) == File.read!(@skill_path)
    refute File.exists?(@plugin_root_solo_skill_path)
    assert File.read!(@plugin_default_solo_skill_path) =~ "name: symphony-solo-session"
    assert File.read!(@plugin_default_solo_skill_path) =~ "Do not create local"
    assert File.read!(@plugin_default_solo_skill_path) =~ "symphony-work-package"
    assert File.read!(@plugin_solo_script_path) =~ "mix sympp.solo"
    assert File.read!(@plugin_solo_script_path) =~ ".sympp-source-root"
    refute File.read!(@plugin_solo_script_path) =~ "Resolve-DefaultDatabase"
    refute File.read!(@plugin_solo_script_path) =~ "solo-sessions.sqlite3"
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
    assert File.exists?(@plugin_lifecycle_diagnostic_path)
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "start-sympp-mcp.ps1"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "sympp\\.mcp --mode stdio"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Sanitize-CommandLine self-test passed"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "installed_cache = @($cachePackages)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "live_repo_roots = @($repoRoots)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "launcher_parents = @($launcherParents)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "repo_root_filter = $RepoRoot"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "[regex]::Escape($MarketplaceName)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "RepoRoot does not look like a Symphony++ checkout"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "mise_sympp_mcp = $miseProcesses.Count"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "Find-AncestorLauncherProcessIds"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "foreach ($processId in $found)"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "enabled\\s*=\\s*(true|false)\\s*(?:#.*)?$"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "$filterAnchorProcesses"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "manifest_parse_error"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "mcp_parse_error"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "manifest_mcpServers_declared"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "manifest_exists"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "default_plugin_lifecycle_status"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "symphony-plus-plus-mcp"
    assert File.read!(@plugin_lifecycle_diagnostic_path) =~ "package_name"
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

    assert File.read!(@mcp_plugin_skill_path) == File.read!(@plugin_skill_path)
    assert File.read!(@mcp_plugin_solo_skill_path) == File.read!(@plugin_default_solo_skill_path)

    assert File.read!(@mcp_plugin_architect_skill_path) ==
             File.read!(Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-architect/SKILL.md"))

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
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")

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
          root_solo_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"])
          source_hint_path = plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])

          refreshed_manifest = refreshed_manifest_path |> File.read!() |> Jason.decode!()
          assert refreshed_manifest["name"] == "symphony-plus-plus"
          assert refreshed_manifest["version"] == @plugin_version
          assert refreshed_manifest["skills"] == "./skills-default/"
          refute Map.has_key?(refreshed_manifest, "mcpServers")
          assert File.read!(default_skill_path) == File.read!(@plugin_default_solo_skill_path)
          refute File.exists?(root_solo_skill_path)
          refute File.exists?(refreshed_mcp_path)
          assert same_path?(String.trim(File.read!(source_hint_path)), @repo_root)
        end

        for cache_name <- ["local", @plugin_version] do
          mcp_manifest_path =
            plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

          mcp_config_path = plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"], "symphony-plus-plus-mcp")
          mcp_manifest = mcp_manifest_path |> File.read!() |> Jason.decode!()
          mcp_config = mcp_config_path |> File.read!() |> Jason.decode!()
          assert mcp_manifest["name"] == "symphony-plus-plus-mcp"
          assert mcp_manifest["mcpServers"] == "./.mcp.json"

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
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")

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
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-mcp-refresh-#{System.unique_integer([:positive])}")

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
          assert same_path?(String.trim(File.read!(source_hint_path)), @repo_root)
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "refresh script overlays local and manifest-version caches without deleting unrelated entries" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")

    if powershell do
      for cache_name <- ["local", @plugin_version] do
        stale_manifest_path = plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
        stale_mcp_path = plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
        stale_root_solo_skill_path = plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"])
        marker_path = plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])

        File.mkdir_p!(Path.dirname(stale_manifest_path))
        File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "stale"}))
        File.write!(stale_mcp_path, Jason.encode!(%{"mcpServers" => %{}}))
        File.mkdir_p!(Path.dirname(stale_root_solo_skill_path))
        File.write!(stale_root_solo_skill_path, "stale duplicate skill")
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
          refute File.exists?(plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session"]))

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
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")
    marketplace_path = Path.join(System.tmp_dir!(), "sympp-marketplace-#{System.unique_integer([:positive])}.json")

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
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")

    marketplace_path =
      Path.join(@repo_root, "plugins/symphony-plus-plus/sympp-marketplace-test-#{System.unique_integer([:positive])}.json")

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
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")

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
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-mcp-only-#{System.unique_integer([:positive])}")

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

  defp frontmatter(content) do
    [_, metadata | _rest] = String.split(content, "---", parts: 3)
    String.trim(metadata)
  end

  defp same_path?(left, right) do
    Path.expand(left) |> String.downcase() == Path.expand(right) |> String.downcase()
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
