Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageEnableSelectionTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

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
        assert output =~ "-RepoRoot"
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
        assert normalize_prose(output) =~ "Cannot enable symphony-plus-plus-mcp"
        assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag timeout: 180_000
  test "diagnostic does not offer enable command while global MCP footgun exists" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    cases = [
      {"section",
       """
       [plugins."symphony-plus-plus@jonat-local"]
       enabled = true

          [ mcp_servers . symphony_plus_plus ] # dedicated old workaround
       url = "http://127.0.0.1:19998/mcp"
       """},
      {"dotted",
       """
       mcp_servers.symphony_plus_plus.url = "http://127.0.0.1:19998/mcp"

       [plugins."symphony-plus-plus@jonat-local"]
       enabled = true
       """},
      {"mcp_servers_table",
       """
       [plugins."symphony-plus-plus@jonat-local"]
       enabled = true

       [mcp_servers]
       symphony_plus_plus.url = "http://127.0.0.1:19998/mcp"
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
          assert normalize_prose(output) =~ "Codex config already contains [mcp_servers.symphony_plus_plus]"
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
        assert normalize_prose(enable_output) =~ "Another symphony-plus-plus-mcp marketplace is already enabled"
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
        assert normalize_prose(enable_output) =~ "resolve to different marketplaces"
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
end
