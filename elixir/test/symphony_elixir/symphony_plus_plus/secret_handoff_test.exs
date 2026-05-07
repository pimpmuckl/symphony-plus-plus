defmodule SymphonyElixir.SymphonyPlusPlus.SecretHandoffTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @repo_root Path.expand("../../../../", __DIR__)
  @windows match?({:win32, _}, :os.type())

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "stores a worker secret in a caller-selected private local file" do
    secret = "synthetic-local-secret-#{System.unique_integer([:positive])}"
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-handoff-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert handoff.mode == "local-private-file"
      assert handoff.status == "stored"
      assert handoff.store == "user-local private file"
      assert handoff.claimed_by == "worker-local-1"
      assert handoff.claimed_by_required == true
      assert handoff.secret_in_stdout == false
      assert Path.dirname(handoff.path) == Path.expand(store_dir)
      assert Path.basename(handoff.path) =~ ~r/^wp-secret-handoff-D321-[A-Za-z0-9_-]{16}\.secret$/
      assert local_file_run_mcp_command_uses_platform_wrapper?(handoff.run_mcp_command)
      assert local_file_run_mcp_command_claims_worker?(handoff.run_mcp_command, "worker-local-1")
      refute handoff.run_mcp_command =~ "<claimed-by>"
      assert File.read!(handoff.path) == secret
      refute inspect(handoff) =~ secret
    after
      File.rm_rf!(store_dir)
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "expands relative local file paths and can delete a stored local secret" do
    secret = "synthetic-local-secret-#{System.unique_integer([:positive])}"
    relative_store_dir = "tmp/sympp-secret-handoff-#{System.unique_integer([:positive])}"
    absolute_store_dir = Path.expand(relative_store_dir)

    try do
      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "local-private-file",
                 store_dir: relative_store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert Path.type(handoff.path) == :absolute
      assert Path.dirname(handoff.path) == absolute_store_dir
      assert Path.basename(handoff.path) =~ ~r/^wp-secret-handoff-D321-[A-Za-z0-9_-]{16}\.secret$/
      assert handoff.run_mcp_command =~ handoff.path
      assert File.read!(handoff.path) == secret

      assert :ok = SecretHandoff.delete_worker_secret(handoff, repo_root: @repo_root)
      refute File.exists?(handoff.path)
    after
      File.rm_rf!(absolute_store_dir)
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "escapes generated local MCP command arguments" do
    secret = "synthetic-local-secret-#{System.unique_integer([:positive])}"
    store_dir = Path.join(System.tmp_dir!(), "sympp secret store 'quoted' #{System.unique_integer([:positive])}")
    database = "tmp/sympp db 'quoted' $(touch injected) \"double\".sqlite3"
    claimed_by = "worker 'quoted' $(touch injected) \"double\""

    try do
      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 database: database,
                 claimed_by: claimed_by,
                 repo_root: @repo_root
               )

      if windows?() do
        assert handoff.run_mcp_command =~ ~s(-SecretFile #{powershell_literal(handoff.path)})
        assert handoff.run_mcp_command =~ ~s(-Database #{powershell_literal(database)})
        assert handoff.run_mcp_command =~ ~s(-ClaimedBy #{powershell_literal(claimed_by)})
      else
        assert handoff.run_mcp_command =~ ~s(--path #{shell_literal(handoff.path)})
        assert handoff.run_mcp_command =~ ~s(--database #{shell_literal(database)})
        assert handoff.run_mcp_command =~ ~s(--claimed-by #{shell_literal(claimed_by)})
      end
    after
      File.rm_rf!(store_dir)
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "namespaces local handoff filenames beyond sanitized ids" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-collision-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, first_handoff} =
               SecretHandoff.store_worker_secret(creation("first-secret", work_package("a/b")),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 database: "ledger-a.sqlite3",
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert {:ok, second_handoff} =
               SecretHandoff.store_worker_secret(creation("second-secret", work_package("a?b")),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 database: "ledger-a.sqlite3",
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert {:ok, third_handoff} =
               SecretHandoff.store_worker_secret(creation("third-secret", work_package("a/b")),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 database: "ledger-b.sqlite3",
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert first_handoff.path != second_handoff.path
      assert first_handoff.path != third_handoff.path
      assert File.read!(first_handoff.path) == "first-secret"
      assert File.read!(second_handoff.path) == "second-secret"
      assert File.read!(third_handoff.path) == "third-secret"
    after
      File.rm_rf!(store_dir)
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "does not delete an existing local handoff file when a retry fails before publishing replacement" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-retry-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation("working-secret"),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert {:error, {:local_private_file_failed, {:chmod, :eacces}}} =
               SecretHandoff.store_worker_secret(creation("replacement-secret"),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root,
                 chmod_fun: fn path, mode ->
                   if mode == 0o600 do
                     assert File.read!(path) == ""
                     {:error, :eacces}
                   else
                     :ok
                   end
                 end
               )

      assert File.read!(handoff.path) == "working-secret"
    after
      File.rm_rf!(store_dir)
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "replaces an existing local handoff file when retry publishes a new secret" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-replace-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, first_handoff} =
               SecretHandoff.store_worker_secret(creation("old-secret"),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert {:ok, second_handoff} =
               SecretHandoff.store_worker_secret(creation("new-secret"),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert second_handoff.path == first_handoff.path
      assert File.read!(second_handoff.path) == "new-secret"
    after
      File.rm_rf!(store_dir)
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "preserves an existing local handoff file when replacement publish fails" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-publish-fail-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation("working-secret"),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert {:error, {:local_private_file_failed, _reason}} =
               SecretHandoff.store_worker_secret(creation("replacement-secret"),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root,
                 private_file_rename_fun: fn _temp_path, _path -> {:error, :simulated_rename_failure} end,
                 private_file_replace_fun: fn _temp_path, _path -> {:error, :simulated_replace_failure} end
               )

      assert File.read!(handoff.path) == "working-secret"
    after
      File.rm_rf!(store_dir)
    end
  end

  test "deletes local handoff files from serialized metadata and reports Windows cleanup input errors" do
    path = Path.join(System.tmp_dir!(), "sympp-secret-delete-#{System.unique_integer([:positive])}.secret")
    File.write!(path, "synthetic-local-secret")

    try do
      assert :ok = SecretHandoff.delete_worker_secret(%{"mode" => "local-private-file", "path" => path})
      refute File.exists?(path)
      assert :ok = SecretHandoff.delete_worker_secret(%{"mode" => "local-private-file", "path" => path})
      assert :ok = SecretHandoff.delete_worker_secret(%{"mode" => "unknown"})
      assert :ok = SecretHandoff.delete_worker_secret(%{"mode" => "windows-credential-manager"})

      assert {:error, {:windows_credential_manager_delete_failed, :missing_repo_root}} =
               SecretHandoff.delete_worker_secret(%{"mode" => "windows-credential-manager", "target" => "synthetic"})

      assert SecretHandoff.error_message({:local_private_file_delete_failed, :eacces}) =~ "cleanup failed"

      assert SecretHandoff.error_message({:windows_credential_manager_delete_failed, :missing_repo_root}) =~
               "cleanup failed"
    after
      File.rm(path)
    end
  end

  test "redacts worker grant secrets and reports handoff input errors" do
    handoff = %{target: "SymphonyPlusPlus:worker:wp-secret-handoff:D321"}

    redacted =
      %{"secret" => "string-secret", display_key: "D321", secret: "atom-secret"}
      |> SecretHandoff.redacted_worker_grant(handoff)

    refute Map.has_key?(redacted, :secret)
    refute Map.has_key?(redacted, "secret")
    assert redacted.secret_handoff == handoff

    assert SecretHandoff.valid_modes() == ["auto", "windows-credential-manager", "local-private-file"]
    assert {:error, :missing_secret} = SecretHandoff.store_worker_secret(creation(""), mode: "local-private-file")
    assert {:error, :missing_worker_grant} = SecretHandoff.store_worker_secret(%{work_package: work_package()}, [])
    assert {:error, :missing_work_package} = SecretHandoff.store_worker_secret(%{worker_grant: worker_grant()}, [])

    assert {:error, :unsupported_secret_handoff_mode} =
             SecretHandoff.store_worker_secret(creation("synthetic-secret"), mode: "unsupported")

    assert {:error, :missing_claimed_by} =
             SecretHandoff.store_worker_secret(creation("synthetic-secret"),
               mode: "local-private-file",
               repo_root: @repo_root
             )

    assert {:error, :missing_repo_root} =
             SecretHandoff.store_worker_secret(creation("synthetic-secret"),
               mode: "local-private-file",
               claimed_by: "worker-local-1"
             )

    assert SecretHandoff.error_message(:missing_secret) =~ "one-time secret"
    assert SecretHandoff.error_message(:missing_claimed_by) =~ "claimed_by"
    assert SecretHandoff.error_message(:missing_repo_root) =~ "repository root"
    assert SecretHandoff.error_message(:missing_worker_grant) =~ "worker grant"
    assert SecretHandoff.error_message(:missing_work_package) =~ "work package"
    assert SecretHandoff.error_message(:unsupported_secret_handoff_mode) =~ "local-private-file"
    assert SecretHandoff.error_message(:local_private_file_unavailable_on_windows) =~ "non-Windows"
    assert SecretHandoff.error_message(:windows_credential_manager_unavailable) =~ "Windows Credential Manager"
    assert SecretHandoff.error_message({:local_private_file_failed, RuntimeError}) =~ "RuntimeError"
    assert SecretHandoff.error_message({:windows_credential_manager_failed, 1}) =~ "exit status 1"
  end

  test "rejects local private-file handoff on Windows" do
    if windows?() do
      assert {:error, :local_private_file_unavailable_on_windows} =
               SecretHandoff.store_worker_secret(creation("synthetic-secret"),
                 mode: "local-private-file",
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "fails and removes the private local file when chmod fails" do
    secret = "synthetic-local-secret-#{System.unique_integer([:positive])}"
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-handoff-#{System.unique_integer([:positive])}")

    try do
      assert {:error, {:local_private_file_failed, {:chmod, :eacces}}} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root,
                 chmod_fun: fn path, mode ->
                   if mode == 0o600 do
                     assert File.read!(path) == ""
                     {:error, :eacces}
                   else
                     :ok
                   end
                 end
               )

      assert Path.wildcard(Path.join(store_dir, "*.secret")) == []
    after
      File.rm_rf!(store_dir)
    end
  end

  test "stores a synthetic secret in Windows Credential Manager without returning the secret" do
    powershell = powershell_executable()

    if windows?() and powershell do
      secret = "synthetic-windows-secret-#{System.unique_integer([:positive])}"

      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "windows-credential-manager",
                 repo_root: @repo_root,
                 database: "test-ledger.sqlite3",
                 claimed_by: "worker-windows-1"
               )

      try do
        assert handoff.mode == "windows-credential-manager"
        assert handoff.status == "stored"
        assert handoff.store == "Windows Credential Manager"
        assert handoff.run_mcp_command =~ ~s(& #{powershell_literal(powershell)})
        assert handoff.run_mcp_command =~ "sympp-worker-secret.ps1"
        assert handoff.run_mcp_command =~ ~s(-ClaimedBy #{powershell_literal("worker-windows-1")})
        assert handoff.secret_in_stdout == false
        refute inspect(handoff) =~ secret
      after
        if is_binary(handoff.target) do
          remove_windows_credential!(powershell, handoff.target)
        end
      end
    end
  end

  defp creation(secret, work_package \\ work_package()) do
    %{
      work_package: work_package,
      worker_grant: worker_grant(secret)
    }
  end

  defp work_package(id \\ "wp-secret-handoff") do
    %WorkPackage{id: id}
  end

  defp worker_grant(secret \\ "synthetic-secret") do
    %{display_key: "D321", secret: secret}
  end

  defp remove_windows_credential!(powershell, target) do
    script_path = Path.join(@repo_root, "scripts/sympp-worker-secret.ps1")

    System.cmd(
      powershell,
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path, "remove", "-Target", target],
      stderr_to_stdout: true
    )
  end

  defp powershell_executable do
    System.find_executable("powershell.exe") ||
      System.find_executable("pwsh") ||
      System.find_executable("powershell")
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp local_file_run_mcp_command_uses_platform_wrapper?(command) do
    command =~ "sympp-worker-secret.sh" and command =~ "run-mcp-local-file"
  end

  defp local_file_run_mcp_command_claims_worker?(command, claimed_by) do
    command =~ ~s(--claimed-by #{shell_literal(claimed_by)})
  end

  defp powershell_literal(value) do
    "'#{String.replace(to_string(value), "'", "''")}'"
  end

  defp shell_literal(value) do
    "'#{String.replace(to_string(value), "'", "'\"'\"'")}'"
  end
end
