defmodule SymphonyElixir.SymphonyPlusPlus.SecretHandoffTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @repo_root Path.expand("../../../../", __DIR__)
  @default_worker_grant_id "ag_secret_handoff_D321"
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

      assert Path.basename(handoff.path) =~
               ~r/^wp-secret-handoff-D321-ag_secret_handoff_D321-[A-Za-z0-9_-]{16}\.secret$/

      assert handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:D321:#{@default_worker_grant_id}"
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

      assert Path.basename(handoff.path) =~
               ~r/^wp-secret-handoff-D321-ag_secret_handoff_D321-[A-Za-z0-9_-]{16}\.secret$/

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

  test "uses grant identity to namespace local paths and credential targets when display keys collide" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-grant-collision-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, first_handoff} =
               SecretHandoff.store_worker_secret(
                 %{work_package: work_package(), worker_grant: worker_grant("first-secret", id: "ag_collision_one")},
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert {:ok, second_handoff} =
               SecretHandoff.store_worker_secret(
                 %{work_package: work_package(), worker_grant: worker_grant("second-secret", id: "ag_collision_two")},
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert first_handoff.path != second_handoff.path
      assert first_handoff.target != second_handoff.target
      assert Path.basename(first_handoff.path) =~ "ag_collision_one"
      assert Path.basename(second_handoff.path) =~ "ag_collision_two"
      assert first_handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:D321:ag_collision_one"
      assert second_handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:D321:ag_collision_two"
      assert File.read!(first_handoff.path) == "first-secret"
      assert File.read!(second_handoff.path) == "second-secret"
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

  test "explicitly stores only non-secret metadata in the managed private-store metadata directory" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-metadata-#{System.unique_integer([:positive])}")
    payload = "synthetic-sensitive-payload-#{System.unique_integer([:positive])}"
    package = work_package()
    grant = worker_grant(payload)
    secret_path = metadata_local_secret_path(package, grant, store_dir)
    metadata_path = managed_metadata_file(package, grant, store_dir)

    handoff = %{
      mode: "local-private-file",
      path: secret_path,
      target: "not-used-for-local-cleanup",
      run_mcp_command: "run command containing #{payload}",
      claimed_by: "worker-local-1",
      env_var: "SYMPP_WORK_KEY_SECRET"
    }

    try do
      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, handoff, store_dir: store_dir)

      assert File.exists?(metadata_path)
      assert Path.dirname(metadata_path) == Path.join(Path.expand(store_dir), "metadata")

      metadata_json = File.read!(metadata_path)
      metadata = Jason.decode!(metadata_json)

      assert metadata == %{
               "version" => 1,
               "work_package_id" => package.id,
               "worker_grant_display_key" => grant.display_key,
               "worker_grant_id" => grant.id,
               "mode" => "local-private-file",
               "path" => Path.expand(secret_path)
             }

      refute metadata_json =~ payload
      refute Map.has_key?(metadata, "target")
      refute Map.has_key?(metadata, "run_mcp_command")
      refute Map.has_key?(metadata, "claimed_by")
      refute Map.has_key?(metadata, "env_var")
    after
      File.rm_rf!(store_dir)
    end
  end

  test "deletes a recorded local handoff by work package and worker grant identity" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-delete-by-grant-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("synthetic-delete-by-grant-payload")
    secret_path = metadata_local_secret_path(package, grant, store_dir)
    metadata_path = managed_metadata_file(package, grant, store_dir)

    try do
      File.mkdir_p!(Path.dirname(secret_path))
      File.write!(secret_path, "synthetic-delete-by-grant-payload")

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => secret_path},
                 store_dir: store_dir
               )

      assert File.exists?(secret_path)
      assert File.exists?(metadata_path)

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, grant, store_dir: store_dir)
      refute File.exists?(secret_path)
      refute File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "concurrent conflicting metadata writes preserve one cleanup coordinate" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-conflict-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("synthetic-conflict-payload")
    first_secret_path = metadata_local_secret_path(package, grant, store_dir, "first")
    second_secret_path = metadata_local_secret_path(package, grant, store_dir, "second")
    metadata_path = managed_metadata_file(package, grant, store_dir)

    try do
      File.mkdir_p!(store_dir)
      File.write!(first_secret_path, "synthetic-first-conflict-payload")
      File.write!(second_secret_path, "synthetic-second-conflict-payload")

      results =
        [first_secret_path, second_secret_path]
        |> Enum.map(fn path ->
          Task.async(fn ->
            receive do
              :write_metadata ->
                SecretHandoff.store_worker_secret_metadata(
                  package,
                  grant,
                  %{"mode" => "local-private-file", "path" => path},
                  store_dir: store_dir
                )
            end
          end)
        end)
        |> then(fn tasks ->
          Enum.each(tasks, &send(&1.pid, :write_metadata))
          Enum.map(tasks, &Task.await(&1, 5_000))
        end)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &match?({:error, {:handoff_metadata_write_failed, :conflicting_metadata}}, &1)) == 1

      assert %{"path" => recorded_path} = metadata_path |> File.read!() |> Jason.decode!()
      assert recorded_path in [first_secret_path, second_secret_path]

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, grant, store_dir: store_dir)
      refute File.exists?(recorded_path)
      refute File.exists?(metadata_path)
      assert Enum.any?([first_secret_path, second_secret_path] -- [recorded_path], &File.exists?/1)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "defaults metadata storage to the local private-store metadata directory" do
    package = work_package()
    grant = worker_grant("synthetic-default-metadata-payload", id: "ag_default_metadata_D321")
    secret_path = metadata_local_secret_path(package, grant, default_local_private_store_dir())
    metadata_path = managed_metadata_file(package, grant, default_local_private_store_dir())

    try do
      assert :ok =
               SecretHandoff.store_worker_secret_metadata(package, grant, %{
                 "mode" => "local-private-file",
                 "path" => secret_path
               })

      assert File.exists?(metadata_path)
      assert Path.dirname(metadata_path) == Path.expand(Path.join(default_local_private_store_dir(), "metadata"))
    after
      File.rm(metadata_path)
    end
  end

  test "delete by grant reports missing or invalid metadata without guessing fallback cleanup coordinates" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-bad-metadata-#{System.unique_integer([:positive])}")
    external_dir = Path.join(System.tmp_dir!(), "sympp-handoff-external-secret-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("synthetic-invalid-metadata-payload")
    secret_path = metadata_local_secret_path(package, grant, store_dir)
    external_secret_path = metadata_local_secret_path(package, grant, external_dir)
    metadata_path = managed_metadata_file(package, grant, store_dir)

    try do
      File.mkdir_p!(Path.dirname(secret_path))
      File.write!(secret_path, "synthetic-invalid-metadata-payload")
      File.mkdir_p!(Path.dirname(external_secret_path))
      File.write!(external_secret_path, "synthetic-external-payload")

      assert {:error, {:handoff_metadata_missing, ^metadata_path}} =
               SecretHandoff.delete_worker_secret_for_grant(package, grant, store_dir: store_dir)

      assert File.exists?(secret_path)

      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(metadata_path, "{")

      assert {:error, {:handoff_metadata_read_failed, :invalid_json}} =
               SecretHandoff.delete_worker_secret_for_grant(package, grant, store_dir: store_dir)

      assert File.exists?(secret_path)
      assert File.exists?(metadata_path)

      File.write!(
        metadata_path,
        Jason.encode!(%{
          "version" => 1,
          "work_package_id" => package.id,
          "worker_grant_display_key" => grant.display_key,
          "worker_grant_id" => grant.id,
          "mode" => "local-private-file",
          "path" => external_secret_path
        })
      )

      assert {:error, {:handoff_metadata_invalid, :invalid_local_path}} =
               SecretHandoff.delete_worker_secret_for_grant(package, grant, store_dir: store_dir)

      assert File.exists?(external_secret_path)
      assert File.exists?(metadata_path)

      File.write!(
        metadata_path,
        Jason.encode!(%{
          "version" => 1,
          "work_package_id" => package.id,
          "worker_grant_display_key" => grant.display_key,
          "worker_grant_id" => grant.id,
          "mode" => "local-private-file",
          "path" => Path.join(store_dir, "unrelated.secret")
        })
      )

      assert {:error, {:handoff_metadata_invalid, :invalid_local_path}} =
               SecretHandoff.delete_worker_secret_for_grant(package, grant, store_dir: store_dir)

      assert File.exists?(secret_path)
      assert File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
      File.rm_rf!(external_dir)
    end
  end

  test "rejects caller supplied handoff metadata directories" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-managed-metadata-#{System.unique_integer([:positive])}")
    metadata_dir = Path.join(System.tmp_dir!(), "sympp-handoff-arbitrary-metadata-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("synthetic-managed-metadata-payload")
    secret_path = metadata_local_secret_path(package, grant, store_dir)

    try do
      assert {:error, :unsupported_handoff_metadata_dir} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => secret_path},
                 store_dir: store_dir,
                 metadata_dir: metadata_dir
               )

      assert {:error, :unsupported_handoff_metadata_dir} =
               SecretHandoff.delete_worker_secret_for_grant(package, grant,
                 store_dir: store_dir,
                 metadata_dir: metadata_dir
               )

      refute File.exists?(metadata_dir)
    after
      File.rm_rf!(store_dir)
      File.rm_rf!(metadata_dir)
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

    assert {:error, :missing_worker_grant_identity} =
             SecretHandoff.store_worker_secret(
               %{
                 work_package: work_package(),
                 worker_grant: Map.delete(worker_grant("synthetic-secret"), :id)
               },
               mode: "local-private-file",
               claimed_by: "worker-local-1",
               repo_root: @repo_root
             )

    assert SecretHandoff.error_message(:missing_secret) =~ "one-time secret"
    assert SecretHandoff.error_message(:missing_claimed_by) =~ "claimed_by"
    assert SecretHandoff.error_message(:missing_repo_root) =~ "repository root"
    assert SecretHandoff.error_message(:missing_worker_grant_display_key) =~ "display key"
    assert SecretHandoff.error_message(:missing_worker_grant_identity) =~ "stable non-secret id"
    assert SecretHandoff.error_message(:missing_worker_grant) =~ "worker grant"
    assert SecretHandoff.error_message(:missing_work_package) =~ "work package"
    assert SecretHandoff.error_message(:unsupported_handoff_metadata_dir) =~ "managed private-store"
    assert SecretHandoff.error_message(:unsupported_secret_handoff_mode) =~ "local-private-file"
    assert SecretHandoff.error_message(:local_private_file_unavailable_on_windows) =~ "non-Windows"
    assert SecretHandoff.error_message(:windows_credential_manager_unavailable) =~ "Windows Credential Manager"
    assert SecretHandoff.error_message({:handoff_metadata_delete_failed, :eacces}) =~ "metadata cleanup failed"
    assert SecretHandoff.error_message({:handoff_metadata_invalid, :unsupported_mode}) =~ "metadata is invalid"
    assert SecretHandoff.error_message({:handoff_metadata_missing, "/tmp/missing.json"}) =~ "not found"
    assert SecretHandoff.error_message({:handoff_metadata_read_failed, :invalid_json}) =~ "metadata read failed"
    assert SecretHandoff.error_message({:handoff_metadata_write_failed, :eacces}) =~ "metadata write failed"
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
        assert handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:D321:#{@default_worker_grant_id}"
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

  test "uses grant identity to namespace Windows Credential Manager targets when display keys collide" do
    powershell = powershell_executable()

    if windows?() and powershell do
      assert {:ok, first_handoff} =
               SecretHandoff.store_worker_secret(
                 %{work_package: work_package(), worker_grant: worker_grant("first-secret", id: "ag_collision_one")},
                 mode: "windows-credential-manager",
                 repo_root: @repo_root,
                 database: "test-ledger.sqlite3",
                 claimed_by: "worker-windows-1"
               )

      assert {:ok, second_handoff} =
               SecretHandoff.store_worker_secret(
                 %{work_package: work_package(), worker_grant: worker_grant("second-secret", id: "ag_collision_two")},
                 mode: "windows-credential-manager",
                 repo_root: @repo_root,
                 database: "test-ledger.sqlite3",
                 claimed_by: "worker-windows-1"
               )

      try do
        assert first_handoff.target != second_handoff.target
        assert first_handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:D321:ag_collision_one"
        assert second_handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:D321:ag_collision_two"
      after
        remove_windows_credential!(powershell, first_handoff.target)
        remove_windows_credential!(powershell, second_handoff.target)
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

  defp worker_grant(secret \\ "synthetic-secret", attrs \\ []) do
    Map.merge(%{id: @default_worker_grant_id, display_key: "D321", secret: secret}, Map.new(attrs))
  end

  defp managed_metadata_file(%WorkPackage{} = work_package, worker_grant, store_dir) do
    filename =
      "#{safe_filename(work_package.id)}-#{safe_filename(worker_grant.display_key)}-#{safe_filename(worker_grant.id)}-#{metadata_hash(work_package.id, worker_grant.display_key, worker_grant.id)}.json"

    store_dir
    |> Path.expand()
    |> Path.join("metadata")
    |> Path.join(filename)
  end

  defp metadata_local_secret_path(%WorkPackage{} = work_package, worker_grant, store_dir, suffix \\ "manual") do
    filename =
      "#{safe_filename(work_package.id)}-#{safe_filename(worker_grant.display_key)}-#{safe_filename(worker_grant.id)}-#{suffix}.secret"

    Path.join(Path.expand(store_dir), filename)
  end

  defp default_local_private_store_dir do
    if windows?() do
      local_app_data = System.get_env("LOCALAPPDATA") || Path.join(System.user_home!(), "AppData/Local")
      Path.join([local_app_data, "SymphonyPlusPlus", "worker-secrets"])
    else
      Path.join([System.user_home!(), ".local", "share", "symphony-plus-plus", "worker-secrets"])
    end
  end

  defp safe_filename(value) when is_binary(value) do
    Regex.replace(~r/[^A-Za-z0-9._-]+/, value, "_")
  end

  defp metadata_hash(work_package_id, display_key, grant_identity) do
    hash_source = [work_package_id, 0, display_key, 0, grant_identity]

    :sha256
    |> :crypto.hash(hash_source)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
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
