defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @plugin_marketplace_name "symphony-plus-plus"
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
  @marketplace_revision String.duplicate("b", 40)
  @mcp_plugin_start_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
  @contract_path Path.join(@repo_root, "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json")

  test "installed MCP launcher treats artifact release listeners as managed backends" do
    script = File.read!(@mcp_plugin_start_script_path)

    assert script =~ "artifacts[\\\\/]mcp"
    assert script =~ "start-runtime\\.ps1"
    assert script =~ "symphony_elixir"
    assert script =~ "Test-ProcessOwnsTcpPort"
    assert script =~ "Stop-ManagedRuntimeProcess $Role $listenerPid $entryPort"
    assert script =~ "RedirectStandardInput"

    process_runtime =
      File.read!(Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-process-runtime.ps1"))

    assert process_runtime =~ "New-McpStdinReader"
    assert process_runtime =~ "OpenStandardInput"
  end

  test "installed MCP launcher falls back to marketplace source when artifact manifest is missing" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-missing")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, @marketplace_revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output
        assert output =~ "Symphony++ MCP launcher validation passed."
        assert normalize_path_fragment(output) =~ "reporoot: #{normalize_path_fragment(marketplace_root)}"
        assert output =~ "runtimeMode: source"
        assert output =~ "artifactStatus: artifact_missing"
        assert output =~ "artifactDetail: manifest_missing"
        assert output =~ "sourceFallback: enabled"
        assert output =~ "Mix 1.99.0 test"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher rejects dirty marketplace contract source" do
    powershell = System.find_executable("pwsh")
    git = System.find_executable("git")
    temp_codex_home = unique_temp_path("sympp-plugin-dirty-marketplace-contract")

    if powershell && git do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      revision = commit_marketplace_source!(marketplace_root, git)
      contract_path = Path.join(marketplace_root, "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        File.write!(contract_path, File.read!(contract_path) <> "\n")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_HOME", Path.join(temp_codex_home, "sympp-home")},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status != 0
        assert normalize_prose(output) =~ "expected MCP contract fingerprint could not be resolved"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher validate-only fails when artifact and source fallback are unavailable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-blocked")

    if powershell do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", ""}, {"SYMPP_HOME", Path.join(temp_codex_home, "sympp-home")}]
          )

        assert status != 0
        assert normalize_prose(output) =~ "expected MCP contract fingerprint could not be resolved"
        refute output =~ "Symphony++ MCP launcher validation passed."
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher direct stdio rejects verified artifacts without source fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-runtime")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      artifact_log = Path.join(temp_codex_home, "artifact.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_FAKE_ARTIFACT_LOG", artifact_log}
            ]
          )

        assert status != 0
        assert output =~ "artifact_direct_stdio_unsupported"
        refute File.exists?(artifact_log)
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher rejects invalid explicit repo root before artifact fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-invalid-explicit-root")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      invalid_root = Path.join(temp_codex_home, "not-a-checkout")

      try do
        File.mkdir_p!(invalid_root)
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", invalid_root}
            ]
          )

        assert status != 0
        assert output =~ "SYMPP_REPO_ROOT does not look like a Symphony++ checkout"
        refute output =~ "Symphony++ MCP launcher validation passed."
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher validate-only treats downloadable artifacts as launchable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-validate-selected")

    if powershell && windows?() do
      write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", Path.join(temp_codex_home, "missing-mix.cmd")},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "artifact_downloading:"
        assert output =~ "artifact_extracting:"
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "artifactDetail: cache_prepared"
        assert output =~ "sourceFallback: disabled"
        refute output =~ "runtimeMode: blocked"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher ignores stale source marker for self-contained artifacts" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-stale-installed-marker")

    if powershell && windows?() do
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      File.write!(Path.join(marketplace_root, "elixir/WORKFLOW.md"), "workflow: test\n")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      stale_revision = String.duplicate("a", 40)
      current_revision = String.duplicate("b", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, stale_revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: current_revision, entrypoint: "start-runtime.ps1")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", Path.join(temp_codex_home, "missing-mix.cmd")},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert normalize_path_fragment(output) =~ "reporoot: artifact-only"
        assert normalize_path_fragment(output) =~ "/#{String.slice(current_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(stale_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher accepts wrapper artifact without workflow file" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-no-workflow")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      revision = String.duplicate("b", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: revision,
          entrypoint: "start-runtime.ps1",
          bundled_workflow?: false
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", Path.join(temp_codex_home, "missing-mix.cmd")},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "sourceFallback: disabled"
        refute output =~ "workflow_missing"
        refute output =~ "artifact_workflow_missing"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher selects artifact when source revision is unavailable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-no-source-revision")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: nil)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "artifactDetail: cache_prepared"
        assert output =~ "sourceFallback: disabled"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher rejects pluginless artifact when source revision is unavailable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-no-plugin-identity")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: nil, plugin_identity: :omit)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status != 0
        assert output =~ "artifactDetail=channel_not_ready"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher selects matching-contract artifact with different source revision" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-source-mismatch-contract-match")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      installed_revision = String.duplicate("b", 40)
      artifact_revision = String.duplicate("a", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, installed_revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: artifact_revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert normalize_path_fragment(output) =~ "/#{String.slice(artifact_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(installed_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher uses previous stable artifact while current release is still building" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-release-race-contract-match")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      installed_revision = String.duplicate("b", 40)
      published_revision = String.duplicate("a", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, installed_revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: published_revision,
          manifest_source_revision: published_revision,
          plugin_identity: %{
            "marketplace" => @plugin_marketplace_name,
            "name" => "symphony-plus-plus-mcp",
            "version" => @plugin_version,
            "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"],
            "source_revision" => published_revision
          }
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "sourceFallback: disabled"
        assert normalize_path_fragment(output) =~ "/#{String.slice(published_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(installed_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher accepts matching-contract artifact across package version bumps" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-package-version-bump")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      installed_revision = String.duplicate("b", 40)
      published_revision = String.duplicate("a", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, installed_revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: published_revision,
          manifest_source_revision: published_revision,
          plugin_identity: %{
            "marketplace" => @plugin_marketplace_name,
            "name" => "symphony-plus-plus-mcp",
            "version" => "0.1.7",
            "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"],
            "source_revision" => published_revision
          }
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "sourceFallback: disabled"
        assert normalize_path_fragment(output) =~ "/#{String.slice(published_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(installed_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher reports contract mismatch before source mismatch" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-contract-mismatch")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, String.duplicate("b", 40))

        write_runtime_artifact!(mcp_cache_root,
          source_revision: String.duplicate("a", 40),
          mcp_contract_fingerprint: String.duplicate("c", 64)
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status != 0
        assert output =~ "artifactDetail=contract_mismatch"
        refute output =~ "source_revision_mismatch"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher rejects legacy contract marker without fingerprint" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-legacy-contract-marker")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: String.duplicate("a", 40),
          mcp_contract_fingerprint: :omit,
          manifest_contract_fingerprint: :omit,
          legacy_contract_manifest: true
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status != 0
        assert output =~ "artifactDetail=contract_mismatch"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "source checkout MCP launcher ignores artifacts unless explicitly opted in" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-source-artifact-skip")

    if powershell && windows?() do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      source_plugin_root = Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")
      artifact_log = Path.join(temp_codex_home, "artifact.log")

      try do
        write_runtime_artifact!(source_plugin_root, source_revision: String.duplicate("b", 40))
        script_path = Path.join(source_plugin_root, "scripts/start-sympp-mcp.ps1")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: marketplace_root,
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_ARTIFACT_LOG", artifact_log},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert File.read!(fake_mix_log) =~ "sympp.mcp --mode stdio --repo-root"
        refute File.exists?(artifact_log)
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "artifact manifest errors degrade to explicit source fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-invalid-fallback")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, @marketplace_revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        File.write!(Path.join(mcp_cache_root, ".sympp-runtime-artifacts.json"), "{not-json")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output
        assert output =~ "source_fallback_compiling"
        assert File.read!(fake_mix_log) =~ "sympp.mcp --mode stdio --repo-root"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "explicit repo root contract wins over stale artifact manifest contract" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-explicit-repo-contract")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")
      revision = @marketplace_revision

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: revision,
          mcp_contract_fingerprint: String.duplicate("a", 64),
          manifest_contract_fingerprint: String.duplicate("a", 64)
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", @repo_root}
            ]
          )

        assert status == 0, output
        assert output =~ "source_fallback_compiling"

        assert normalize_path_fragment(File.read!(fake_mix_log)) =~
                 "--repo-root #{normalize_path_fragment(@repo_root)}"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "explicit repo root without contract fails before artifact fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-explicit-repo-missing-contract")

    if powershell do
      explicit_repo_root = Path.join(temp_codex_home, "explicit-repo")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      revision = @marketplace_revision

      try do
        File.mkdir_p!(Path.join(explicit_repo_root, "elixir"))
        File.write!(Path.join(explicit_repo_root, "elixir/mix.exs"), "defmodule ExplicitRepo.MixProject do\nend\n")

        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", Path.join(temp_codex_home, "sympp-home")},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_REPO_ROOT", explicit_repo_root}
            ]
          )

        assert status != 0
        assert normalize_prose(output) =~ "explicit SYMPP_REPO_ROOT contract JSON"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "stale artifact metadata falls back to marketplace source when available" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-stale-source-fallback")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, String.duplicate("b", 40))
        write_runtime_artifact!(mcp_cache_root, source_revision: String.duplicate("a", 40))

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output

        assert normalize_path_fragment(File.read!(fake_mix_log)) =~
                 "--repo-root #{normalize_path_fragment(marketplace_root)}"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "artifact metadata without contract fingerprint falls back to marketplace source" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-missing-contract-fallback")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: revision,
          mcp_contract_fingerprint: :omit,
          manifest_contract_fingerprint: :omit
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output

        assert normalize_path_fragment(File.read!(fake_mix_log)) =~
                 "--repo-root #{normalize_path_fragment(marketplace_root)}"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  defp write_cached_script(cache_root, source_script_path) do
    target = Path.join([cache_root, "scripts", Path.basename(source_script_path)])
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source_script_path, target)

    for helper_name <-
          ~w(sympp-launcher-runtime.ps1 sympp-mcp-launcher-helpers.ps1 sympp-mcp-artifact-manifest.ps1 sympp-mcp-artifact-channel.ps1 sympp-mcp-artifact-runtime.ps1 sympp-mcp-process-runtime.ps1 sympp-diagnostic-runtime-artifacts.ps1 sympp-diagnostic-launcher-artifacts.ps1 sympp-diagnostic-self-test.ps1) do
      source_helper = Path.join(Path.dirname(source_script_path), helper_name)

      if File.exists?(source_helper) do
        File.cp!(source_helper, Path.join(Path.dirname(target), helper_name))
      end
    end

    target
  end

  defp write_cache_manifest(cache_root, plugin_name, opts \\ []) do
    manifest_path = Path.join(cache_root, ".codex-plugin/plugin.json")
    File.mkdir_p!(Path.dirname(manifest_path))

    manifest =
      if Keyword.get(opts, :mcp?, false) do
        %{"name" => plugin_name, "version" => @plugin_version, "mcpServers" => "./.mcp.json"}
      else
        %{"name" => plugin_name, "version" => @plugin_version}
      end

    File.write!(manifest_path, Jason.encode!(manifest))

    if Keyword.get(opts, :mcp?, false) do
      File.write!(
        Path.join(cache_root, ".mcp.json"),
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "cmd.exe",
            "args" => ["/d", "/s", "/c", "scripts/start-sympp-mcp.cmd"],
            "cwd" => "."
          }
        })
      )
    end
  end

  defp write_minimal_marketplace_source(codex_home) do
    marketplace_root = Path.join([codex_home, ".tmp", "marketplaces", @plugin_marketplace_name])
    File.mkdir_p!(marketplace_root)
    File.write!(Path.join(marketplace_root, ".codex-marketplace-install.json"), Jason.encode!(%{"revision" => @marketplace_revision}))
    File.mkdir_p!(Path.join(marketplace_root, "elixir"))
    File.write!(Path.join(marketplace_root, "elixir/mix.exs"), "defmodule SymphonyElixir.MixProject do\nend\n")
    File.mkdir_p!(Path.join(marketplace_root, "elixir/lib/mix/tasks"))
    File.write!(Path.join(marketplace_root, "elixir/lib/mix/tasks/sympp.solo.ex"), "")
    File.mkdir_p!(Path.join(marketplace_root, "scripts"))
    File.write!(Path.join(marketplace_root, "scripts/refresh-local-plugin.ps1"), "")
    File.write!(Path.join(marketplace_root, "scripts/smoke-sympp-mcp-http.ps1"), "")
    File.mkdir_p!(Path.join(marketplace_root, "implementation_docs_symphplusplus/mcp"))
    File.cp!(@contract_path, Path.join(marketplace_root, "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json"))
    File.mkdir_p!(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts"))

    File.cp!(
      @mcp_plugin_start_script_path,
      Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
    )

    for helper_name <-
          ~w(sympp-launcher-runtime.ps1 sympp-mcp-launcher-helpers.ps1 sympp-mcp-artifact-manifest.ps1 sympp-mcp-artifact-channel.ps1 sympp-mcp-artifact-runtime.ps1 sympp-mcp-process-runtime.ps1) do
      File.cp!(
        Path.join(Path.dirname(@mcp_plugin_start_script_path), helper_name),
        Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/#{helper_name}")
      )
    end

    write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus"), "symphony-plus-plus")
    write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp"), "symphony-plus-plus-mcp", mcp?: true)

    marketplace_root
  end

  defp commit_marketplace_source!(marketplace_root, git) do
    install_manifest = Path.join(marketplace_root, ".codex-marketplace-install.json")
    File.rm(install_manifest)
    run_git!(git, marketplace_root, ["init", "-q"])
    run_git!(git, marketplace_root, ["config", "user.email", "sympp-fixture@example.invalid"])
    run_git!(git, marketplace_root, ["config", "user.name", "Sympp Fixture"])
    run_git!(git, marketplace_root, ["add", "."])
    run_git!(git, marketplace_root, ["commit", "-q", "-m", "fixture"])
    revision = String.trim(run_git!(git, marketplace_root, ["rev-parse", "HEAD"]))
    File.write!(install_manifest, Jason.encode!(%{"revision" => revision}))
    revision
  end

  defp write_runtime_artifact!(cache_root, opts) do
    artifact_build_root = Path.join(cache_root, "artifact-build")
    archive_path = Path.join(cache_root, "sympp-runtime.zip")
    entrypoint = Keyword.get(opts, :entrypoint, "runtime.cmd")
    dashboard_entries = [{"dashboard-static/index.html", "<main>ok</main>"}]

    workflow_entries =
      if Keyword.get(opts, :bundled_workflow?, true) do
        [{"WORKFLOW.md", "workflow: artifact\n"}]
      else
        []
      end

    artifact_entries = [{entrypoint, fake_artifact_entrypoint(entrypoint)}] ++ workflow_entries ++ dashboard_entries
    artifact_contract_fingerprint = Keyword.get(opts, :mcp_contract_fingerprint, expected_mcp_contract_fingerprint())
    manifest_contract_fingerprint = Keyword.get(opts, :manifest_contract_fingerprint, expected_mcp_contract_fingerprint())
    File.mkdir_p!(artifact_build_root)

    File.write!(Path.join(artifact_build_root, entrypoint), fake_artifact_entrypoint(entrypoint))

    {:ok, _} =
      :zip.create(
        String.to_charlist(archive_path),
        Enum.map(artifact_entries, fn {name, content} -> {String.to_charlist(name), content} end)
      )

    sha256 = file_sha256(archive_path)

    artifact =
      %{
        "platform" => runtime_platform_key(),
        "path" => Path.basename(archive_path),
        "sha256" => sha256,
        "entrypoint" => entrypoint,
        "dashboard" => %{
          "asset_root" => "dashboard-static",
          "fingerprint" => dashboard_fingerprint(dashboard_entries)
        }
      }
      |> maybe_put("workflow", if(Keyword.get(opts, :bundled_workflow?, true), do: "WORKFLOW.md"))
      |> maybe_put("source_revision", Keyword.get(opts, :source_revision))
      |> maybe_put(
        "launcher_contract",
        if(Keyword.get(opts, :legacy_contract_manifest, false),
          do: %{"manifest" => "sympp-runtime-artifact", "version" => 1}
        )
      )
      |> maybe_put_unless_omitted("mcp_contract_fingerprint", artifact_contract_fingerprint)

    manifest =
      %{"artifacts" => [artifact]}
      |> maybe_put_unless_omitted(
        "plugin",
        Keyword.get(opts, :plugin_identity, %{
          "marketplace" => @plugin_marketplace_name,
          "name" => "symphony-plus-plus-mcp",
          "version" => @plugin_version,
          "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"]
        })
      )
      |> maybe_put("source_revision", Keyword.get(opts, :manifest_source_revision))
      |> maybe_put_unless_omitted("mcp_contract_fingerprint", manifest_contract_fingerprint)

    File.write!(Path.join(cache_root, ".sympp-runtime-artifacts.json"), Jason.encode!(manifest))
  end

  defp write_pinned_source_revision!(cache_root, revision) do
    File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{revision}\n")
  end

  defp fake_artifact_entrypoint(entrypoint) do
    if String.ends_with?(entrypoint, ".ps1") do
      """
      if ($env:SYMPP_FAKE_ARTIFACT_LOG -ne "") { [string]::Join(" ", $args) | Out-File -Append -Encoding utf8 $env:SYMPP_FAKE_ARTIFACT_LOG }
      exit 0
      """
    else
      """
      @echo off
      if not "%SYMPP_FAKE_ARTIFACT_LOG%"=="" echo %*>>"%SYMPP_FAKE_ARTIFACT_LOG%"
      exit /b 0
      """
    end
  end

  defp dashboard_fingerprint(entries) do
    entries
    |> Enum.filter(fn {name, _content} -> String.starts_with?(name, "dashboard-static/") end)
    |> Enum.map(fn {name, content} ->
      relative_name = String.replace_prefix(name, "dashboard-static/", "")
      "#{relative_name} #{sha256(content)}"
    end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> sha256()
  end

  defp sha256(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_unless_omitted(map, _key, :omit), do: map
  defp maybe_put_unless_omitted(map, key, value), do: maybe_put(map, key, value)

  defp fake_mix_executable(temp_root) do
    path = Path.join(temp_root, if(windows?(), do: "mix.cmd", else: "mix"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, fake_mix_script())

    unless windows?() do
      File.chmod!(path, 0o755)
    end

    path
  end

  defp fake_mix_script do
    if windows?() do
      """
      @echo off
      if not "%SYMPP_FAKE_MIX_LOG%"=="" echo %*>>"%SYMPP_FAKE_MIX_LOG%"
      if "%~1"=="--version" (
        echo Mix 1.99.0 test
        exit /b 0
      )
      if "%~1"=="deps.get" (
        if "%~2"=="--check-locked" exit /b 0
        exit /b 3
      )
      if "%~1"=="compile" (
        exit /b 0
      )
      if "%~1"=="sympp.mcp" (
        exit /b 0
      )
      echo unexpected mix args: %*
      exit /b 2
      """
    else
      """
      #!/usr/bin/env sh
      if [ -n "$SYMPP_FAKE_MIX_LOG" ]; then
        printf '%s\\n' "$*" >> "$SYMPP_FAKE_MIX_LOG"
      fi
      if [ "$1" = "--version" ]; then
        echo "Mix 1.99.0 test"
        exit 0
      fi
      if [ "$1" = "deps.get" ]; then
        if [ "$2" = "--check-locked" ]; then
          exit 0
        fi
        exit 3
      fi
      if [ "$1" = "compile" ]; then
        exit 0
      fi
      if [ "$1" = "sympp.mcp" ]; then
        exit 0
      fi
      echo "unexpected mix args: $*" >&2
      exit 2
      """
    end
  end

  defp windows?, do: match?({:win32, _name}, :os.type())

  defp runtime_platform_key do
    "#{runtime_os_key()}-#{runtime_arch_key()}"
  end

  defp runtime_os_key do
    case :os.type() do
      {:win32, _} -> "windows"
      {:unix, :darwin} -> "macos"
      {:unix, _} -> "linux"
    end
  end

  defp runtime_arch_key do
    architecture =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.downcase()

    cond do
      String.contains?(architecture, "aarch64") -> "aarch64"
      String.contains?(architecture, "arm64") -> "aarch64"
      String.contains?(architecture, "x86_64") -> "x86_64"
      String.contains?(architecture, "amd64") -> "x86_64"
      String.contains?(architecture, "i386") -> "x86"
      true -> "unknown"
    end
  end

  defp expected_mcp_contract_fingerprint do
    @contract_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("mcp_contract_fingerprint")
  end

  defp run_git!(git, cwd, args) do
    {output, status} = System.cmd(git, args, cd: cwd, stderr_to_stdout: true)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed: #{output}"
    end

    output
  end

  defp file_sha256(path) do
    :crypto.hash(:sha256, File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp normalize_path_fragment(value) do
    value
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  defp normalize_prose(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.replace(~r/\s+\|\s+|\s+/, " ")
  end

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
  end

  defp unique_id do
    id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
  end

  defp plugin_cache_path(codex_home, suffix, plugin_name) do
    Path.join([codex_home, "plugins", "cache", @plugin_marketplace_name, plugin_name] ++ suffix)
  end
end
