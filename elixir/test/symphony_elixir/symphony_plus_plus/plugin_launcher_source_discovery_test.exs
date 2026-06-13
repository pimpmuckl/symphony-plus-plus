defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherSourceDiscoveryTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @plugin_marketplace_name "symphony-plus-plus"
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
  @plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus/scripts/sympp-solo.ps1")
  @mcp_plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1")
  @mcp_plugin_start_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")

  test "installed launchers resolve marketplace source clone despite missing or stale cache hints" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-source")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      stale_source_root = write_minimal_stale_source(temp_codex_home)
      default_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"])
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(default_cache_root)
        File.write!(Path.join(default_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")
        File.mkdir_p!(mcp_cache_root)
        File.write!(Path.join(mcp_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")

        launchers = [
          {write_cached_script(default_cache_root, @plugin_solo_script_path), "Symphony++ Solo Session wrapper validation passed."},
          {write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path), "Symphony++ Solo Session wrapper validation passed."},
          {write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path), "Symphony++ MCP launcher validation passed."}
        ]

        for {script_path, expected} <- launchers do
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
                {"SYMPP_SOURCE_FALLBACK", "1"}
              ]
            )

          assert status == 0, output
          assert output =~ expected
          assert normalize_path_fragment(output) =~ "reporoot: #{normalize_path_fragment(marketplace_root)}"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed launchers default to mise for source checkouts with mise config" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-mise-default")

    if powershell do
      fake_mise = fake_mise_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      File.write!(Path.join(marketplace_root, "elixir/mise.toml"), "[tools]\nelixir = \"1.19.5-otp-28\"\n")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        launchers = [
          {write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path), "Symphony++ Solo Session wrapper validation passed."},
          {write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path), "Symphony++ MCP launcher validation passed."}
        ]

        for {script_path, expected} <- launchers do
          {output, status} =
            System.cmd(
              powershell,
              ["-NoProfile", "-File", script_path, "-ValidateOnly"],
              cd: Path.dirname(Path.dirname(script_path)),
              stderr_to_stdout: true,
              env: [
                {"SYMPP_MISE", fake_mise},
                {"SYMPP_REPO_ROOT", ""},
                {"SYMPP_HOME", sympp_home},
                {"SYMPP_SOURCE_FALLBACK", "1"}
              ]
            )

          assert status == 0, output
          assert output =~ expected
          assert output =~ "Mix 1.98.0 mise"
          assert output =~ "launcher: mise"
          assert normalize_path_fragment(output) =~ "mixbuildroot: #{normalize_path_fragment(sympp_home)}"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
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
              {"SYMPP_HOME", sympp_home}
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
        assert output =~ "Cannot infer the Symphony++ runtime source"
        refute output =~ "Symphony++ MCP launcher validation passed."
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher direct stdio runs verified artifact before source fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-runtime")

    if powershell && windows?() do
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      artifact_log = Path.join(temp_codex_home, "artifact.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: String.duplicate("b", 40))

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

        assert status == 0, output
        assert output =~ "artifact_downloading:"
        assert output =~ "artifact_extracting:"
        assert output =~ "ready: verified Symphony++ runtime artifact selected"
        artifact_call = File.read!(artifact_log)
        assert artifact_call =~ "sympp.mcp --mode stdio --repo-root"
        assert normalize_path_fragment(artifact_call) =~ normalize_path_fragment(marketplace_root)
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher direct stdio runs verified artifact without source checkout" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-runtime-no-source")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      artifact_log = Path.join(temp_codex_home, "artifact.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: String.duplicate("b", 40))

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

        assert status == 0, output
        assert output =~ "ready: verified Symphony++ runtime artifact selected"
        artifact_call = File.read!(artifact_log)
        assert artifact_call =~ "sympp.mcp --mode stdio"
        refute artifact_call =~ "--repo-root"
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
        write_runtime_artifact!(mcp_cache_root, source_revision: String.duplicate("b", 40))

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
        write_runtime_artifact!(mcp_cache_root, source_revision: String.duplicate("b", 40))

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
        assert output =~ "artifactDetail: download_required"
        assert output =~ "sourceFallback: enabled"
        refute output =~ "runtimeMode: blocked"
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
        assert output =~ "artifact_manifest_invalid"
        assert File.read!(fake_mix_log) =~ "sympp.mcp --mode stdio --repo-root"
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
              {"SYMPP_REPO_ROOT", ""}
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

        write_runtime_artifact!(mcp_cache_root,
          source_revision: String.duplicate("b", 40),
          mcp_contract_fingerprint: :omit
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
              {"SYMPP_REPO_ROOT", ""}
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

  test "Solo wrapper keeps direct default for source checkouts without mise config" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-direct-default")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [{"SYMPP_MIX", fake_mix}, {"SYMPP_REPO_ROOT", ""}, {"SYMPP_HOME", sympp_home}]
          )

        assert status == 0, output
        assert output =~ "Symphony++ Solo Session wrapper validation passed."
        assert output =~ "Mix 1.99.0 test"
        assert output =~ "launcher: direct"
        assert normalize_path_fragment(output) =~ "mixbuildroot: #{normalize_path_fragment(sympp_home)}"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "direct stdio launcher fetches locked deps before running MCP from marketplace source clone" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-elixir-deps")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")
      setup_stderr_log = Path.join(temp_codex_home, "setup.stderr.log")
      log_dir = Path.join(temp_codex_home, "logs")

      try do
        File.mkdir_p!(mcp_cache_root)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-Command",
              "& { param($ScriptPath, $ErrorLog) $writer = [System.IO.StreamWriter]::new($ErrorLog); [Console]::SetError($writer); try { & $ScriptPath } finally { $writer.Flush(); $writer.Dispose() } }",
              script_path,
              setup_stderr_log
            ],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: false,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_LOG_DIR", log_dir},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output
        assert output == ""

        assert normalize_path_fragment(File.read!(setup_stderr_log)) =~
                 "ensuring symphony++ elixir dependencies are available in #{normalize_path_fragment(Path.join(marketplace_root, "elixir"))}."

        fake_mix_calls =
          fake_mix_log
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(
            &(String.contains?(&1, "deps.get") or &1 == "compile" or
                String.starts_with?(&1, "sympp.mcp "))
          )

        assert ["deps.get --check-locked", "compile", mcp_call] = fake_mix_calls
        assert String.starts_with?(mcp_call, "sympp.mcp ")
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  defp write_cached_script(cache_root, source_script_path) do
    target = Path.join([cache_root, "scripts", Path.basename(source_script_path)])
    helper_target = Path.join(Path.dirname(target), "sympp-launcher-runtime.ps1")
    source_helper = Path.join(Path.dirname(source_script_path), "sympp-launcher-runtime.ps1")
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source_script_path, target)

    if File.exists?(source_helper) do
      File.cp!(source_helper, helper_target)
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
    File.write!(Path.join(marketplace_root, ".codex-marketplace-install.json"), Jason.encode!(%{"revision" => String.duplicate("b", 40)}))
    File.mkdir_p!(Path.join(marketplace_root, "elixir"))
    File.write!(Path.join(marketplace_root, "elixir/mix.exs"), "defmodule SymphonyElixir.MixProject do\nend\n")
    File.mkdir_p!(Path.join(marketplace_root, "elixir/lib/mix/tasks"))
    File.write!(Path.join(marketplace_root, "elixir/lib/mix/tasks/sympp.solo.ex"), "")
    File.mkdir_p!(Path.join(marketplace_root, "scripts"))
    File.write!(Path.join(marketplace_root, "scripts/refresh-local-plugin.ps1"), "")
    File.write!(Path.join(marketplace_root, "scripts/smoke-sympp-mcp-http.ps1"), "")
    File.mkdir_p!(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts"))

    File.cp!(
      @mcp_plugin_start_script_path,
      Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
    )

    File.cp!(
      Path.join(Path.dirname(@mcp_plugin_start_script_path), "sympp-launcher-runtime.ps1"),
      Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-launcher-runtime.ps1")
    )

    write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus"), "symphony-plus-plus")
    write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp"), "symphony-plus-plus-mcp", mcp?: true)

    marketplace_root
  end

  defp write_minimal_stale_source(codex_home) do
    source_root = Path.join(codex_home, "stale-source")
    File.mkdir_p!(Path.join(source_root, "elixir/lib/mix/tasks"))
    File.write!(Path.join(source_root, "elixir/mix.exs"), "defmodule Stale.MixProject do\nend\n")
    File.write!(Path.join(source_root, "elixir/lib/mix/tasks/sympp.solo.ex"), "")
    source_root
  end

  defp write_runtime_artifact!(cache_root, opts) do
    artifact_build_root = Path.join(cache_root, "artifact-build")
    archive_path = Path.join(cache_root, "sympp-runtime.zip")
    entrypoint = "runtime.cmd"
    artifact_contract_fingerprint = Keyword.get(opts, :mcp_contract_fingerprint, expected_mcp_contract_fingerprint())
    manifest_contract_fingerprint = Keyword.get(opts, :manifest_contract_fingerprint)
    File.mkdir_p!(artifact_build_root)

    File.write!(Path.join(artifact_build_root, entrypoint), """
    @echo off
    if not "%SYMPP_FAKE_ARTIFACT_LOG%"=="" echo %*>>"%SYMPP_FAKE_ARTIFACT_LOG%"
    exit /b 0
    """)

    {:ok, _} =
      :zip.create(
        String.to_charlist(archive_path),
        [{String.to_charlist(entrypoint), File.read!(Path.join(artifact_build_root, entrypoint))}]
      )

    sha256 = file_sha256(archive_path)

    artifact =
      %{
        "platform" => runtime_platform_key(),
        "path" => Path.basename(archive_path),
        "sha256" => sha256,
        "entrypoint" => entrypoint
      }
      |> maybe_put("source_revision", Keyword.get(opts, :source_revision))
      |> maybe_put_unless_omitted("mcp_contract_fingerprint", artifact_contract_fingerprint)

    manifest =
      %{"artifacts" => [artifact]}
      |> maybe_put("source_revision", Keyword.get(opts, :manifest_source_revision))
      |> maybe_put_unless_omitted("mcp_contract_fingerprint", manifest_contract_fingerprint)

    File.write!(Path.join(cache_root, ".sympp-runtime-artifacts.json"), Jason.encode!(manifest))
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

  defp fake_mise_executable(temp_root) do
    path = Path.join(temp_root, if(windows?(), do: "mise.cmd", else: "mise"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, fake_mise_script())

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

  defp fake_mise_script do
    if windows?() do
      """
      @echo off
      if not "%SYMPP_FAKE_MISE_LOG%"=="" echo %*>>"%SYMPP_FAKE_MISE_LOG%"
      if "%~1"=="exec" if "%~2"=="--" if "%~3"=="mix" if "%~4"=="--version" (
        echo Mix 1.98.0 mise
        exit /b 0
      )
      echo unexpected mise args: %*
      exit /b 2
      """
    else
      """
      #!/usr/bin/env sh
      if [ -n "$SYMPP_FAKE_MISE_LOG" ]; then
        printf '%s\\n' "$*" >> "$SYMPP_FAKE_MISE_LOG"
      fi
      if [ "$1" = "exec" ] && [ "$2" = "--" ] && [ "$3" = "mix" ] && [ "$4" = "--version" ]; then
        echo "Mix 1.98.0 mise"
        exit 0
      fi
      echo "unexpected mise args: $*" >&2
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
    [_, fingerprint] =
      Regex.run(
        ~r/\$ExpectedMcpContractFingerprint\s*=\s*"([0-9a-fA-F]{64})"/,
        File.read!(@mcp_plugin_start_script_path)
      )

    String.downcase(fingerprint)
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

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
  end

  defp unique_id do
    id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
  end

  defp plugin_cache_path(codex_home, suffix, plugin_name \\ "symphony-plus-plus") do
    Path.join([codex_home, "plugins", "cache", @plugin_marketplace_name, plugin_name] ++ suffix)
  end
end
