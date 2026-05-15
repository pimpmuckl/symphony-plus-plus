defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @skill_path Path.join(@repo_root, ".codex/skills/symphony-work-package/SKILL.md")
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_mcp_path Path.join(@repo_root, "plugins/symphony-plus-plus/.mcp.json")
  @plugin_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-work-package/SKILL.md")
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

  test "MCP wiring docs explain the stdio dependency without embedding secrets" do
    wiring = File.read!(@wiring_path)
    plugin_wiring = File.read!(@plugin_wiring_path)
    template_wiring = File.read!(Path.join(@template_references_dir, "mcp_wiring.md"))

    assert wiring =~ "mix sympp.mcp --mode stdio"
    assert wiring =~ "rejects mise shims in direct mode"
    assert wiring =~ "`mise` is opt-in"
    assert wiring =~ "[mcp_servers.symphony_plus_plus]"
    assert wiring =~ "sympp-worker-secret.ps1"
    assert wiring =~ "sympp-worker-secret.sh"
    assert wiring =~ "--work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by <stable-worker-id>"
    assert wiring =~ "should not embed raw work-key secrets or bearer tokens"
    assert wiring =~ "open a new session before treating missing `symphony_plus_plus`"
    assert wiring =~ "ValidateOnly checks the wrapper and launcher"
    assert wiring =~ "scripts/refresh-local-plugin.ps1 -ValidateInstalledCache"
    assert wiring =~ "Skill visibility, MCP server registration, and current-session tool"
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
    assert manifest["version"] == "0.1.0"
    assert manifest["skills"] == "./skills/"
    assert manifest["mcpServers"] == "./.mcp.json"
    assert manifest["interface"]["displayName"] == "Symphony++"
    assert File.read!(@plugin_skill_path) == File.read!(@skill_path)

    assert Enum.any?(marketplace["plugins"], fn plugin ->
             plugin["name"] == "symphony-plus-plus" and
               plugin["source"] == %{"source" => "local", "path" => "./plugins/symphony-plus-plus"}
           end)

    assert File.exists?(@refresh_script_path)
    assert File.exists?(@worker_secret_script_path)
    assert File.exists?(@worker_secret_shell_path)
    assert File.read!(@plugin_readme_path) =~ ~s("path": "./plugins/symphony-plus-plus")
    assert File.read!(@plugin_readme_path) =~ "manifest-version directory"
    assert File.read!(@plugin_readme_path) =~ "refresh-local-plugin.ps1 -ValidateInstalledCache"
    assert File.read!(@plugin_readme_path) =~ "Plugin skill visibility, MCP server registration, and current-session tool"
    assert File.read!(@plugin_readme_path) =~ "start a new session after reload"
    assert File.read!(@plugin_readme_path) =~ "already-running Codex host"
    refute File.read!(@plugin_readme_path) =~ "../../Code/"
    assert File.read!(@refresh_script_path) =~ "ReparsePoint"
    assert File.read!(@refresh_script_path) =~ "ValidateInstalledCache"
    assert File.read!(@refresh_script_path) =~ "Invoke-InstalledCacheValidation"

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

  test "Codex plugin package exposes a host-discoverable generic MCP entry" do
    manifest =
      @plugin_manifest_path
      |> File.read!()
      |> Jason.decode!()

    mcp_config =
      @plugin_mcp_path
      |> File.read!()
      |> Jason.decode!()

    assert manifest["mcpServers"] == "./.mcp.json"

    assert %{
             "symphony_plus_plus" => %{
               "type" => "stdio",
               "command" => "pwsh",
               "args" => args,
               "cwd" => "."
             }
           } = mcp_config["mcpServers"]

    assert "-NoProfile" in args
    assert Enum.any?(args, &String.contains?(&1, "scripts/start-sympp-mcp.ps1"))

    serialized = Jason.encode!(mcp_config)
    refute serialized =~ "SYMPP_WORK_KEY_SECRET"
    refute serialized =~ "bearer"
    refute serialized =~ "token"
    refute serialized =~ "worker-secret"
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

        for cache_name <- ["local", "0.1.0"] do
          refreshed_manifest_path = plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
          refreshed_mcp_path = plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
          source_hint_path = plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])

          refreshed_manifest = refreshed_manifest_path |> File.read!() |> Jason.decode!()
          assert refreshed_manifest["name"] == "symphony-plus-plus"
          assert refreshed_manifest["version"] == "0.1.0"
          assert refreshed_manifest["mcpServers"] == "./.mcp.json"
          assert refreshed_mcp_path |> File.read!() |> Jason.decode!() |> get_in(["mcpServers", "symphony_plus_plus", "command"]) == "pwsh"
          assert same_path?(String.trim(File.read!(source_hint_path)), @repo_root)
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
        assert output =~ "Validated installed Symphony++ plugin MCP cache:"
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

  test "refresh script overlays local and manifest-version caches without deleting unrelated entries" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")

    if powershell do
      for cache_name <- ["local", "0.1.0"] do
        stale_manifest_path = plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
        stale_mcp_path = plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
        marker_path = plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])

        File.mkdir_p!(Path.dirname(stale_manifest_path))
        File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "stale"}))
        File.write!(stale_mcp_path, Jason.encode!(%{"mcpServers" => %{}}))
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

        for cache_name <- ["local", "0.1.0"] do
          manifest =
            temp_codex_home
            |> plugin_cache_path([cache_name, ".codex-plugin", "plugin.json"])
            |> File.read!()
            |> Jason.decode!()

          mcp_command =
            temp_codex_home
            |> plugin_cache_path([cache_name, ".mcp.json"])
            |> File.read!()
            |> Jason.decode!()
            |> get_in(["mcpServers", "symphony_plus_plus", "command"])

          assert manifest["version"] == "0.1.0"
          assert manifest["mcpServers"] == "./.mcp.json"
          assert mcp_command == "pwsh"

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
        assert File.exists?(refreshed_mcp_path)
      after
        File.rm(marketplace_path)
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "refresh script updates only local and manifest-version caches" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-refresh-#{System.unique_integer([:positive])}")

    if powershell do
      stale_manifest_path = plugin_cache_path(temp_codex_home, ["0.0.9", ".codex-plugin", "plugin.json"])
      sentinel_path = plugin_cache_path(temp_codex_home, ["0.0.9", "already-open.txt"])
      scratch_path = plugin_cache_path(temp_codex_home, ["scratch", "note.txt"])
      File.mkdir_p!(Path.dirname(stale_manifest_path))
      File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.0.9"}))
      File.write!(sentinel_path, "preserve")
      File.mkdir_p!(Path.dirname(scratch_path))
      File.write!(scratch_path, "do not touch")

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
        refute output =~ "Repaired stale MCP-incomplete Codex plugin cache"

        versioned_manifest =
          plugin_cache_path(temp_codex_home, ["0.1.0", ".codex-plugin", "plugin.json"])
          |> File.read!()
          |> Jason.decode!()

        assert versioned_manifest["mcpServers"] == "./.mcp.json"
        assert File.exists?(plugin_cache_path(temp_codex_home, ["0.1.0", ".mcp.json"]))
        assert plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"]) |> File.exists?()
        refute File.exists?(plugin_cache_path(temp_codex_home, ["0.0.9", ".mcp.json"]))
        assert File.read!(sentinel_path) == "preserve"
        assert File.read!(scratch_path) == "do not touch"
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
      assert content =~ "plugins/symphony-plus-plus/"
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

  defp plugin_cache_path(codex_home, suffix) do
    Path.join([codex_home, "plugins", "cache", "jonat-local", "symphony-plus-plus"] ++ suffix)
  end
end
