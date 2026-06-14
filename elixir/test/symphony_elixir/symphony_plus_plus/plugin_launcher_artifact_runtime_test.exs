defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactRuntimeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server

  @repo_root Path.expand("../../../../", __DIR__)
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
  @start_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
  @contract_fingerprint Server.mcp_contract_identity()["fingerprint"]
  @source_revision "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  test "installed MCP launcher validates against a matching runtime artifact without source fallback" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-runtime")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_packaged_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status == 0, output
        assert output =~ "Symphony++ MCP launcher validation passed."
        assert output =~ "repoRoot: artifact-only"
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "sourceFallback: disabled"

        assert normalize_path_fragment(output) =~
                 normalize_path_fragment("artifacts/mcp/#{current_platform()}/#{String.slice(@source_revision, 0, 12)}")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher accepts nested per-platform artifact manifest entries" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-nested")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "nested-runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_nested_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status == 0, output
        assert output =~ "Symphony++ MCP launcher validation passed."
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher rejects direct stdio artifact validation before launch" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-direct-stdio")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_packaged_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path, [{"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"}])
          )

        assert status != 0
        assert_shell_output_contains(output, "direct_stdio_unsupported")
        assert_shell_output_contains(output, "no verified runtime artifact is launchable")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher rejects matching artifacts when package source revision is missing" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-missing-revision")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        write_packaged_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status != 0
        assert_shell_output_contains(output, "no verified runtime artifact is launchable")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher rejects mixed plugin and release source revisions" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-mixed-revision")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_mixed_revision_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status != 0
        assert_shell_output_contains(output, "no verified runtime artifact is launchable")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher rejects mixed artifact entry source revisions" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-mixed-entry-revision")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_mixed_entry_revision_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status != 0
        assert_shell_output_contains(output, "no verified runtime artifact is launchable")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher rejects conflicting archive locations" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-conflicting-location")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_conflicting_location_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status != 0
        assert_shell_output_contains(output, "multiple archive locations")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher rejects ambiguous matching artifacts" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-ambiguous-match")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_ambiguous_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status != 0
        assert_shell_output_contains(output, "multiple matching artifacts")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher fails closed when no verified artifact or explicit fallback exists" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-missing")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: [{"SYMPP_HOME", Path.join(temp_root, "sympp-home")}, {"SYMPP_REPO_ROOT", ""}]
          )

        assert status != 0
        assert_shell_output_contains(output, "no verified runtime artifact is launchable")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher rejects artifact manifests for a different plugin package identity" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-plugin-identity")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_packaged_artifact_manifest(cache_root, artifact_path, plugin_name: "other-plugin")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status != 0
        assert_shell_output_contains(output, "no verified runtime artifact is launchable")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher accepts manifests generated by the repo artifact builder" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-builder-manifest")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_builder_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status == 0, output
        assert output =~ "artifactStatus: artifact_selected"
        dashboard_path = Path.join([artifact_cache_root(output), "runtime", "dashboard-static", "index.html"])
        File.write!(dashboard_path, "<main>tampered</main>")

        {second_output, second_status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert second_status == 0, second_output
        assert second_output =~ "artifact_extracting"
        assert File.read!(dashboard_path) == "<main>verified</main>"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher resolves published channel manifests before selecting artifacts" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-channel-manifest")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        built_manifest_path = Path.join(temp_root, "runtime-artifact.manifest.json")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_builder_manifest_file(built_manifest_path, cache_root, artifact_path)
        write_channel_artifact_manifest(cache_root, built_manifest_path, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status == 0, output
        assert output =~ "artifactStatus: artifact_selected"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher ValidateOnly rejects an artifact archive without the declared entrypoint" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-missing-entrypoint")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        write_runtime_artifact!(artifact_path, [{"other-file.txt", "not a launcher"}], entrypoints?: false)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_packaged_artifact_manifest(cache_root, artifact_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert status != 0
        assert_shell_output_contains(output, "did not contain entrypoint")
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "installed MCP launcher refreshes extracted cache when dashboard assets do not match manifest fingerprint" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-plugin-artifact-dashboard-fingerprint")

    if powershell do
      try do
        cache_root = plugin_cache_path(temp_root)
        script_path = write_cached_launcher(cache_root)
        artifact_path = Path.join(temp_root, "runtime-artifact.zip")
        workflow_path = write_workflow(temp_root)
        dashboard_entries = [{"dashboard-static/index.html", "<main>verified</main>"}]
        write_runtime_artifact!(artifact_path, dashboard_entries)
        write_cache_manifest(cache_root)
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{@source_revision}\n")
        write_packaged_artifact_manifest(cache_root, artifact_path, dashboard_entries: dashboard_entries)

        {first_output, first_status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert first_status == 0, first_output
        assert first_output =~ "artifactStatus: artifact_selected"
        dashboard_path = Path.join([artifact_cache_root(first_output), "runtime", "dashboard-static", "index.html"])
        assert File.exists?(dashboard_path)
        File.write!(dashboard_path, "<main>tampered</main>")

        {second_output, second_status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: cache_root,
            stderr_to_stdout: true,
            env: artifact_env(temp_root, workflow_path)
          )

        assert second_status == 0, second_output
        assert first_output =~ "artifact_downloading"
        assert second_output =~ "artifact_extracting"
        assert File.read!(dashboard_path) == "<main>verified</main>"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  defp write_cached_launcher(cache_root) do
    target = Path.join([cache_root, "scripts", "start-sympp-mcp.ps1"])
    File.mkdir_p!(Path.dirname(target))
    File.cp!(@start_script_path, target)

    for helper_name <-
          ~w(sympp-launcher-runtime.ps1 sympp-mcp-launcher-helpers.ps1 sympp-mcp-artifact-manifest.ps1 sympp-mcp-artifact-channel.ps1 sympp-mcp-artifact-runtime.ps1 sympp-mcp-process-runtime.ps1) do
      File.cp!(
        Path.join(Path.dirname(@start_script_path), helper_name),
        Path.join(Path.dirname(target), helper_name)
      )
    end

    target
  end

  defp write_cache_manifest(cache_root) do
    manifest_path = Path.join(cache_root, ".codex-plugin/plugin.json")
    File.mkdir_p!(Path.dirname(manifest_path))

    File.write!(
      manifest_path,
      Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
    )
  end

  defp write_packaged_artifact_manifest(cache_root, artifact_path, opts \\ []) do
    dashboard_entries = Keyword.get(opts, :dashboard_entries, default_dashboard_entries())

    File.write!(
      Path.join(cache_root, ".sympp-runtime-artifacts.json"),
      Jason.encode!(%{
        "schema_version" => 1,
        "status" => "built",
        "source_revision" => @source_revision,
        "plugin" => plugin_identity(opts),
        "mcp_contract_fingerprint" => @contract_fingerprint,
        "platform" => builder_platform(),
        "target_abi" => current_abi(),
        "artifact" => %{
          "file" => Path.basename(artifact_path),
          "relative_path" => Path.relative_to(artifact_path, cache_root),
          "sha256" => sha256(artifact_path)
        },
        "backend" => %{
          "kind" => "mix_release",
          "entrypoints" => %{
            "unix" => "start-runtime.sh",
            "windows" => "start-runtime.ps1"
          }
        },
        "dashboard" => dashboard_manifest(dashboard_entries),
        "launcher_contract" => %{
          "manifest" => "sympp-runtime-artifact",
          "version" => 1,
          "mcp_contract_fingerprint" => @contract_fingerprint
        }
      })
    )
  end

  defp write_nested_artifact_manifest(cache_root, artifact_path) do
    {os, arch} = current_platform_parts()

    File.write!(
      Path.join(cache_root, ".sympp-runtime-artifacts.json"),
      Jason.encode!(%{
        "release" => %{"source_revision" => @source_revision},
        "plugin" => plugin_identity(),
        "mcp_contract_fingerprint" => @contract_fingerprint,
        "artifacts" => [
          %{
            "platform" => %{"os" => os, "arch" => arch, "abi" => current_abi()},
            "dashboard" => dashboard_manifest(default_dashboard_entries()),
            "archive" => %{
              "path" => artifact_path,
              "sha256" => sha256(artifact_path)
            },
            "runtime" => %{
              "command" => if(windows?(), do: "start-runtime.ps1", else: "start-runtime.sh")
            }
          }
        ]
      })
    )
  end

  defp write_mixed_revision_artifact_manifest(cache_root, artifact_path) do
    {os, arch} = current_platform_parts()

    File.write!(
      Path.join(cache_root, ".sympp-runtime-artifacts.json"),
      Jason.encode!(%{
        "release" => %{"source_revision" => @source_revision},
        "plugin" => plugin_identity(source_revision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        "source_revision" => @source_revision,
        "mcp_contract_fingerprint" => @contract_fingerprint,
        "artifacts" => [
          %{
            "platform" => %{"os" => os, "arch" => arch, "abi" => current_abi()},
            "dashboard" => dashboard_manifest(default_dashboard_entries()),
            "archive" => %{
              "path" => artifact_path,
              "sha256" => sha256(artifact_path)
            },
            "runtime" => %{
              "command" => if(windows?(), do: "start-runtime.ps1", else: "start-runtime.sh")
            }
          }
        ]
      })
    )
  end

  defp write_mixed_entry_revision_artifact_manifest(cache_root, artifact_path) do
    {os, arch} = current_platform_parts()

    File.write!(
      Path.join(cache_root, ".sympp-runtime-artifacts.json"),
      Jason.encode!(%{
        "release" => %{"source_revision" => @source_revision},
        "plugin" => plugin_identity(),
        "mcp_contract_fingerprint" => @contract_fingerprint,
        "artifacts" => [
          %{
            "release" => %{"source_revision" => @source_revision},
            "plugin" => %{"source_revision" => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
            "source_revision" => @source_revision,
            "platform" => %{"os" => os, "arch" => arch, "abi" => current_abi()},
            "dashboard" => dashboard_manifest(default_dashboard_entries()),
            "archive" => %{
              "path" => artifact_path,
              "sha256" => sha256(artifact_path)
            },
            "runtime" => %{
              "command" => if(windows?(), do: "start-runtime.ps1", else: "start-runtime.sh")
            }
          }
        ]
      })
    )
  end

  defp write_conflicting_location_artifact_manifest(cache_root, artifact_path) do
    {os, arch} = current_platform_parts()

    File.write!(
      Path.join(cache_root, ".sympp-runtime-artifacts.json"),
      Jason.encode!(%{
        "release" => %{"source_revision" => @source_revision},
        "plugin" => plugin_identity(),
        "mcp_contract_fingerprint" => @contract_fingerprint,
        "artifacts" => [
          %{
            "platform" => %{"os" => os, "arch" => arch, "abi" => current_abi()},
            "dashboard" => dashboard_manifest(default_dashboard_entries()),
            "archive" => %{
              "path" => artifact_path,
              "url" => "file:///#{String.replace(artifact_path, "\\", "/")}",
              "sha256" => sha256(artifact_path)
            },
            "runtime" => %{
              "command" => if(windows?(), do: "start-runtime.ps1", else: "start-runtime.sh")
            }
          }
        ]
      })
    )
  end

  defp write_ambiguous_artifact_manifest(cache_root, artifact_path) do
    {os, arch} = current_platform_parts()

    artifact = %{
      "platform" => %{"os" => os, "arch" => arch, "abi" => current_abi()},
      "dashboard" => dashboard_manifest(default_dashboard_entries()),
      "archive" => %{
        "path" => artifact_path,
        "sha256" => sha256(artifact_path)
      },
      "runtime" => %{
        "command" => if(windows?(), do: "start-runtime.ps1", else: "start-runtime.sh")
      }
    }

    File.write!(
      Path.join(cache_root, ".sympp-runtime-artifacts.json"),
      Jason.encode!(%{
        "release" => %{"source_revision" => @source_revision},
        "plugin" => plugin_identity(),
        "mcp_contract_fingerprint" => @contract_fingerprint,
        "artifacts" => [artifact, artifact]
      })
    )
  end

  defp write_builder_artifact_manifest(cache_root, artifact_path) do
    write_builder_manifest_file(Path.join(cache_root, ".sympp-runtime-artifacts.json"), cache_root, artifact_path)
  end

  defp write_builder_manifest_file(manifest_path, cache_root, artifact_path) do
    File.write!(
      manifest_path,
      Jason.encode!(%{
        "schema_version" => 1,
        "status" => "built",
        "source_revision" => @source_revision,
        "platform" => builder_platform(),
        "artifact" => %{
          "relative_path" => Path.relative_to(artifact_path, cache_root),
          "sha256" => sha256(artifact_path)
        },
        "backend" => %{
          "entrypoints" => %{
            "unix" => "start-runtime.sh",
            "windows" => "start-runtime.ps1"
          }
        },
        "dashboard" => %{
          "relative_path" => "dashboard-static",
          "index" => "dashboard-static/index.html",
          "vite_manifest" => "dashboard-static/.vite/manifest.json"
        },
        "launcher_contract" => %{
          "manifest" => "sympp-runtime-artifact",
          "version" => 1
        }
      })
    )
  end

  defp write_channel_artifact_manifest(cache_root, built_manifest_path, artifact_path) do
    File.write!(
      Path.join(cache_root, ".sympp-runtime-artifacts.json"),
      Jason.encode!(%{
        "schema_version" => 1,
        "status" => "published",
        "source_revision" => @source_revision,
        "platform" => builder_platform(),
        "artifact" => %{
          "relative_path" => Path.relative_to(artifact_path, cache_root),
          "sha256" => sha256(artifact_path)
        },
        "manifest" => %{
          "relative_path" => Path.relative_to(built_manifest_path, cache_root),
          "sha256" => sha256(built_manifest_path)
        },
        "launcher_contract" => %{
          "manifest" => "sympp-runtime-artifact",
          "version" => 1
        }
      })
    )
  end

  defp sha256(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp write_runtime_artifact!(path, extra_entries \\ [], opts \\ []) do
    base_entries =
      if Keyword.get(opts, :entrypoints?, true) do
        [
          {"start-runtime.ps1", "Write-Output ok\n"},
          {"start-runtime.sh", "#!/usr/bin/env sh\necho ok\n"}
        ]
      else
        []
      end

    entries =
      base_entries ++
        [
          {"WORKFLOW.md", "# workflow\n"}
        ] ++ default_dashboard_entries() ++ extra_entries

    {:ok, {_zip_name, zip_binary}} =
      :zip.create(
        ~c"runtime-artifact.zip",
        Enum.map(entries, fn {name, content} -> {String.to_charlist(name), content} end),
        [:memory]
      )

    File.write!(path, zip_binary)
  end

  defp dashboard_manifest([]), do: nil

  defp dashboard_manifest(entries) do
    %{
      "asset_root" => "dashboard-static",
      "fingerprint" => dashboard_fingerprint(entries)
    }
  end

  defp dashboard_fingerprint(entries) do
    entries
    |> Enum.filter(fn {name, _content} -> String.starts_with?(name, "dashboard-static/") end)
    |> Enum.map(fn {name, content} ->
      relative_name = String.replace_prefix(name, "dashboard-static/", "")
      file_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      "#{relative_name} #{file_sha}"
    end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp artifact_cache_root(output), do: ~r/artifactCache:\s*(.+)/ |> Regex.run(output) |> List.last() |> String.trim()

  defp default_dashboard_entries, do: [{"dashboard-static/index.html", "<main>verified</main>"}]

  defp plugin_identity(opts \\ []) do
    %{
      "name" => Keyword.get(opts, :plugin_name, "symphony-plus-plus-mcp"),
      "version" => Keyword.get(opts, :plugin_version, @plugin_version),
      "source_revision" => Keyword.get(opts, :source_revision, @source_revision)
    }
  end

  defp write_workflow(temp_root) do
    workflow_path = Path.join(temp_root, "WORKFLOW.md")
    File.write!(workflow_path, "# test workflow\n")
    workflow_path
  end

  defp artifact_env(temp_root, workflow_path, extra \\ []) do
    [{"SYMPP_HOME", Path.join(temp_root, "sympp-home")}, {"SYMPP_REPO_ROOT", ""}, {"SYMPP_WORKFLOW_FILE", workflow_path}] ++
      extra
  end

  defp current_platform, do: current_platform_parts() |> then(fn {os, arch} -> "#{os}-#{arch}" end)

  defp builder_platform do
    {os, arch} = current_platform_parts()

    builder_arch =
      case arch do
        "x86_64" -> "x64"
        "aarch64" -> "arm64"
        other -> other
      end

    "#{os}-#{builder_arch}"
  end

  defp current_platform_parts do
    os =
      case :os.type() do
        {:win32, _} -> "windows"
        {:unix, :darwin} -> "macos"
        {:unix, _} -> "linux"
      end

    {os, current_arch()}
  end

  defp current_arch do
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.downcase()

    cond do
      String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") -> "aarch64"
      String.contains?(arch, "x86_64") or String.contains?(arch, "amd64") -> "x86_64"
      String.contains?(arch, "i386") or String.contains?(arch, "i686") -> "x86"
      true -> "x86_64"
    end
  end

  defp current_abi do
    case :os.type() do
      {:win32, _} -> "msvc"
      {:unix, :linux} -> "gnu"
      _other -> nil
    end
  end

  defp windows?, do: match?({:win32, _name}, :os.type())

  defp normalize_path_fragment(value) do
    value
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  defp assert_shell_output_contains(output, expected) do
    assert normalize_shell_output(output) =~ expected
  end

  defp normalize_shell_output(output) do
    output
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.replace(~r/\s+\|\s+/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
  end

  defp unique_id do
    id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
  end

  defp plugin_cache_path(temp_root) do
    Path.join([temp_root, "plugins", "cache", "symphony-plus-plus", "symphony-plus-plus-mcp", "1.0.0"])
  end
end
