defmodule SymphonyElixir.SymphonyPlusPlus.PluginLifecycleDiagnosticTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @plugin_marketplace_name "symphony-plus-plus"
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
  @plugin_lifecycle_diagnostic_path Path.join(@repo_root, "plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1")
  @mcp_plugin_start_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")

  test "lifecycle doctor resolves marketplace source clone before stale cache hints" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-source-doctor")

    if powershell do
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      stale_source_root = write_minimal_stale_source(temp_codex_home)
      default_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version])
      mcp_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version], "symphony-plus-plus-mcp")

      try do
        File.write!(Path.join(temp_codex_home, "config.toml"), """
        [plugins."symphony-plus-plus-mcp@#{@plugin_marketplace_name}"]
        enabled = true
        """)

        installed_script_path = write_cached_script(default_cache_root, @plugin_lifecycle_diagnostic_path)
        write_cache_manifest(default_cache_root, "symphony-plus-plus")
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        File.write!(Path.join(default_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")
        File.write!(Path.join(mcp_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              @plugin_marketplace_name,
              "-SkipProcessScan",
              "-Json"
            ],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", ""}]
          )

        assert status == 0, output
        report = Jason.decode!(output)
        source_checkout = get_in(report, ["readiness", "source_checkout"])
        assert source_checkout["status"] == "codex_marketplace_source_clone"
        assert normalize_path_fragment(source_checkout["root"]) == normalize_path_fragment(marketplace_root)
        assert report["process_scan_scope"] == "installed_cache_source_root_hints"
        assert [process_filter] = report["process_repo_root_filters"]
        assert normalize_path_fragment(process_filter) == normalize_path_fragment(marketplace_root)
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "lifecycle doctor reports stale runtime artifacts without blocking source fallback" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-doctor-artifact-filter")

    if powershell do
      write_minimal_marketplace_source(temp_codex_home)
      default_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version])
      mcp_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version], "symphony-plus-plus-mcp")
      stale_revision = String.duplicate("a", 40)

      try do
        File.write!(Path.join(temp_codex_home, "config.toml"), """
        [plugins."symphony-plus-plus-mcp@#{@plugin_marketplace_name}"]
        enabled = true
        """)

        installed_script_path = write_cached_script(default_cache_root, @plugin_lifecycle_diagnostic_path)
        write_cache_manifest(default_cache_root, "symphony-plus-plus")
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: stale_revision,
          mcp_contract_fingerprint: expected_mcp_contract_fingerprint()
        )

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              @plugin_marketplace_name,
              "-SkipProcessScan",
              "-Json"
            ],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", ""}]
          )

        assert status == 0, output
        report = Jason.decode!(output)
        assert get_in(report, ["readiness", "workrequest_mcp", "status"]) == "ready"
        runtime_artifact = get_in(report, ["readiness", "workrequest_mcp", "runtime_artifact"])
        assert runtime_artifact["status"] == "artifact_missing"
        assert runtime_artifact["detail"] == "matching_artifact_missing"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "lifecycle doctor blocks missing runtime artifacts when source fallback is unavailable" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-doctor-artifact-blocked")

    if powershell do
      default_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version])
      mcp_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(temp_codex_home)

        File.write!(Path.join(temp_codex_home, "config.toml"), """
        [plugins."symphony-plus-plus-mcp@#{@plugin_marketplace_name}"]
        enabled = true
        """)

        installed_script_path = write_cached_script(default_cache_root, @plugin_lifecycle_diagnostic_path)
        write_cache_manifest(default_cache_root, "symphony-plus-plus")
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              @plugin_marketplace_name,
              "-SkipProcessScan",
              "-Json"
            ],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", ""}]
          )

        assert status == 0, output
        report = Jason.decode!(output)
        assert get_in(report, ["readiness", "workrequest_mcp", "status"]) == "runtime_artifact_unavailable"
        runtime_artifact = get_in(report, ["readiness", "workrequest_mcp", "runtime_artifact"])
        assert runtime_artifact["status"] == "artifact_missing"
        assert runtime_artifact["detail"] == "manifest_missing"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "lifecycle doctor rejects runtime artifacts without contract metadata" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-doctor-artifact-missing-contract")

    if powershell do
      default_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version])
      mcp_cache_root = plugin_cache_path(temp_codex_home, [@plugin_version], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(temp_codex_home)

        File.write!(Path.join(temp_codex_home, "config.toml"), """
        [plugins."symphony-plus-plus-mcp@#{@plugin_marketplace_name}"]
        enabled = true
        """)

        installed_script_path = write_cached_script(default_cache_root, @plugin_lifecycle_diagnostic_path)
        write_cache_manifest(default_cache_root, "symphony-plus-plus")
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: String.duplicate("b", 40),
          mcp_contract_fingerprint: :omit
        )

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              @plugin_marketplace_name,
              "-SkipProcessScan",
              "-Json"
            ],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", ""}]
          )

        assert status == 0, output
        report = Jason.decode!(output)
        assert get_in(report, ["readiness", "workrequest_mcp", "status"]) == "runtime_artifact_unavailable"
        runtime_artifact = get_in(report, ["readiness", "workrequest_mcp", "runtime_artifact"])
        assert runtime_artifact["status"] == "artifact_missing"
        assert runtime_artifact["detail"] == "matching_artifact_missing"
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
    File.mkdir_p!(artifact_build_root)

    File.write!(Path.join(artifact_build_root, entrypoint), """
    @echo off
    exit /b 0
    """)

    {:ok, _} =
      :zip.create(
        String.to_charlist(archive_path),
        [{String.to_charlist(entrypoint), File.read!(Path.join(artifact_build_root, entrypoint))}]
      )

    artifact =
      %{
        "platform" => runtime_platform_key(),
        "path" => Path.basename(archive_path),
        "sha256" => file_sha256(archive_path),
        "entrypoint" => entrypoint
      }
      |> maybe_put("source_revision", Keyword.get(opts, :source_revision))
      |> maybe_put_unless_omitted("mcp_contract_fingerprint", artifact_contract_fingerprint)

    File.write!(Path.join(cache_root, ".sympp-runtime-artifacts.json"), Jason.encode!(%{"artifacts" => [artifact]}))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_unless_omitted(map, _key, :omit), do: map
  defp maybe_put_unless_omitted(map, key, value), do: maybe_put(map, key, value)

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp runtime_platform_key do
    "#{runtime_os_key()}-#{runtime_arch_key()}"
  end

  defp runtime_os_key do
    case :os.type() do
      {:win32, _} -> "windows"
      {:unix, :darwin} -> "darwin"
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

  defp normalize_path_fragment(value), do: value |> to_string() |> String.replace("\\", "/") |> String.downcase()

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp plugin_cache_path(codex_home, suffix, plugin_name \\ "symphony-plus-plus") do
    Path.join([codex_home, "plugins", "cache", @plugin_marketplace_name, plugin_name] ++ suffix)
  end
end
