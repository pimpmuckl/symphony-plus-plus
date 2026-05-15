defmodule SymphonyElixir.SymphonyPlusPlus.SecretHandoffTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @repo_root Path.expand("../../../../", __DIR__)
  @default_worker_grant_id "ag_secret_handoff_D321"
  @windows match?({:win32, _}, :os.type())

  test "local operator repo root fails closed for an invalid configured root" do
    invalid_repo_root =
      Path.join(System.tmp_dir!(), "sympp-invalid-repo-root-#{System.unique_integer([:positive])}")

    previous_repo_root = Application.get_env(:symphony_elixir, :sympp_repo_root)
    Application.put_env(:symphony_elixir, :sympp_repo_root, invalid_repo_root)

    on_exit(fn ->
      restore_repo_root_env(previous_repo_root)
      File.rm_rf(invalid_repo_root)
    end)

    assert SecretHandoff.local_operator_repo_root() == nil
  end

  test "rejects storing a handoff when repo root lacks worker-secret helper scripts" do
    invalid_repo_root =
      Path.join(System.tmp_dir!(), "sympp-invalid-handoff-root-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(invalid_repo_root)

      assert {:error, :invalid_repo_root} =
               SecretHandoff.store_worker_secret(creation("invalid-root-secret"),
                 mode: "auto",
                 store_dir: Path.join(System.tmp_dir!(), "sympp-invalid-root-store"),
                 claimed_by: "worker-local-1",
                 repo_root: invalid_repo_root
               )
    after
      File.rm_rf!(invalid_repo_root)
    end
  end

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

  test "checks local private file availability and integrity without returning the secret" do
    secret = "synthetic-local-integrity-#{System.unique_integer([:positive])}"
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-integrity-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "local-private-file",
                 store_dir: store_dir,
                 repo_root: @repo_root,
                 claimed_by: "worker-local-integrity"
               )

      secret_hash = WorkKey.secret_hash(secret)
      assert SecretHandoff.worker_secret_availability(handoff, repo_root: @repo_root) == :available
      assert SecretHandoff.worker_secret_integrity(handoff, secret_hash, repo_root: @repo_root) == :match

      File.write!(handoff.path, "corrupted-secret")
      assert SecretHandoff.worker_secret_availability(handoff, repo_root: @repo_root) == :available
      assert SecretHandoff.worker_secret_integrity(handoff, secret_hash, repo_root: @repo_root) == :mismatch

      unless windows?() do
        File.chmod!(handoff.path, 0o000)
        assert SecretHandoff.worker_secret_availability(handoff, repo_root: @repo_root) == :unknown
        assert SecretHandoff.worker_secret_integrity(handoff, secret_hash, repo_root: @repo_root) == :unknown

        File.chmod!(handoff.path, 0o600)
      end

      File.rm!(handoff.path)
      assert SecretHandoff.worker_secret_availability(handoff, repo_root: @repo_root) == :missing
      assert SecretHandoff.worker_secret_integrity(handoff, secret_hash, repo_root: @repo_root) == :mismatch
    after
      File.rm_rf!(store_dir)
    end
  end

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

  if @windows, do: @tag(skip: "POSIX chmod failure hook is non-Windows only")

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

  if not @windows, do: @tag(skip: "Windows file replacement command is Windows only")

  test "Windows local handoff replacement honors the injected PowerShell executable" do
    store_dir =
      Path.join(System.tmp_dir!(), "sympp-secret-windows-replace-#{System.unique_integer([:positive])}")

    package = work_package()
    grant_attrs = [id: "ag_windows_replace_override"]
    parent = self()

    windows_file_replace_command = fn powershell, args, cmd_opts ->
      assert powershell == "synthetic-powershell"
      assert "-Command" in args

      env = Keyword.fetch!(cmd_opts, :env)
      source = env |> List.keyfind("SYMPP_PRIVATE_FILE_SOURCE", 0) |> elem(1)
      destination = env |> List.keyfind("SYMPP_PRIVATE_FILE_DESTINATION", 0) |> elem(1)

      send(parent, {:windows_file_replace_command, powershell, destination})

      File.rm!(destination)
      File.rename!(source, destination)

      {"", 0}
    end

    try do
      assert {:ok, first_handoff} =
               SecretHandoff.store_worker_secret(
                 %{work_package: package, worker_grant: worker_grant("old-secret", grant_attrs)},
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      assert {:ok, second_handoff} =
               SecretHandoff.store_worker_secret(
                 %{work_package: package, worker_grant: worker_grant("new-secret", grant_attrs)},
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root,
                 private_file_rename_fun: fn _temp_path, _path -> {:error, :simulated_rename_failure} end,
                 powershell_executable: "synthetic-powershell",
                 windows_file_replace_command: windows_file_replace_command
               )

      assert second_handoff.path == first_handoff.path
      assert File.read!(second_handoff.path) == "new-secret"
      expected_path = second_handoff.path
      assert_receive {:windows_file_replace_command, "synthetic-powershell", ^expected_path}
    after
      File.rm_rf!(store_dir)
    end
  end

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

  test "stores managed handoff metadata using exact non-secret namespace identity" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-metadata-#{System.unique_integer([:positive])}")
    hidden_value = "runtime-sensitive-value-#{System.unique_integer([:positive])}"
    package = work_package("wp/raw:id")
    grant = worker_grant(hidden_value, id: "ag/raw:identity", display_key: "D/21?")
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    handoff_path = local_private_file_path(package, grant, opts)
    metadata_path = managed_metadata_file(package, grant, opts)

    handoff = %{
      mode: "local-private-file",
      path: handoff_path,
      target: "not-used-for-local-coordinate",
      run_mcp_command: "command text #{hidden_value}",
      claimed_by: "worker-local-1",
      secret: hidden_value,
      work_key: hidden_value,
      token: hidden_value,
      bearer: hidden_value
    }

    try do
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "metadata fixture")

      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, handoff, opts)

      assert File.exists?(metadata_path)
      assert Path.basename(metadata_path) == "handoff-#{metadata_hash(package.id, grant.display_key, grant.id, opts)}.json"

      metadata_json = File.read!(metadata_path)
      metadata = Jason.decode!(metadata_json)

      assert metadata == %{
               "version" => 1,
               "work_package_id" => package.id,
               "worker_grant_display_key" => grant.display_key,
               "worker_grant_id" => grant.id,
               "mode" => "local-private-file",
               "path" => Path.expand(handoff_path)
             }

      refute metadata_json =~ hidden_value
      refute Map.has_key?(metadata, "handoff")
      refute metadata_json =~ "run_mcp_command"
      refute metadata_json =~ "claimed_by"
      refute metadata_json =~ "work_key"
      refute metadata_json =~ "token"
      refute metadata_json =~ "bearer"
    after
      File.rm_rf!(store_dir)
    end
  end

  test "metadata persistence API requires handoff opts and namespaces repo database and store dir" do
    first_store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-context-a-#{System.unique_integer([:positive])}")
    second_store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-context-b-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()

    first_opts = [
      mode: "local-private-file",
      store_dir: first_store_dir,
      repo_root: @repo_root,
      database: "first.sqlite3",
      claimed_by: "worker-local-1"
    ]

    second_opts = Keyword.put(first_opts, :database, "second.sqlite3")
    third_opts = Keyword.put(first_opts, :store_dir, second_store_dir)

    try do
      for opts <- [first_opts, second_opts, third_opts] do
        handoff_path = local_private_file_path(package, grant, opts)
        File.mkdir_p!(Path.dirname(handoff_path))
        File.write!(handoff_path, "metadata fixture")

        assert :ok =
                 SecretHandoff.store_worker_secret_metadata(
                   package,
                   grant,
                   %{"mode" => "local-private-file", "path" => handoff_path},
                   opts
                 )
      end

      assert function_exported?(SecretHandoff, :store_worker_secret_metadata, 4)
      refute function_exported?(SecretHandoff, :store_worker_secret_metadata, 3)

      first_metadata_path = managed_metadata_file(package, grant, first_opts)
      second_metadata_path = managed_metadata_file(package, grant, second_opts)
      third_metadata_path = managed_metadata_file(package, grant, third_opts)

      assert first_metadata_path != second_metadata_path
      assert first_metadata_path != third_metadata_path
      assert File.exists?(first_metadata_path)
      assert File.exists?(second_metadata_path)
      assert File.exists?(third_metadata_path)

      credential_opts = [
        mode: "windows-credential-manager",
        store_dir: first_store_dir,
        repo_root: @repo_root,
        claimed_by: "worker-windows-1"
      ]

      equivalent_credential_opts = Keyword.put(credential_opts, :repo_root, Path.join(@repo_root, "."))
      credential_metadata_path = managed_metadata_file(package, grant, credential_opts)
      target = credential_target(package, grant)

      assert managed_metadata_file(package, grant, equivalent_credential_opts) == credential_metadata_path

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "windows-credential-manager", "target" => target},
                 credential_opts
               )

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "windows-credential-manager", "target" => target},
                 equivalent_credential_opts
               )
    after
      File.rm_rf!(first_store_dir)
      File.rm_rf!(second_store_dir)
    end
  end

  test "deletes local private-file handoff and metadata by grant identity" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-delete-local-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("cleanup-secret")
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    handoff_path = local_private_file_path(package, grant, opts)
    metadata_path = managed_metadata_file(package, grant, opts)
    handoff = %{"mode" => "local-private-file", "path" => handoff_path}

    try do
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "cleanup fixture")

      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, handoff, opts)
      assert :ok = SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)
      refute File.exists?(handoff_path)
      refute File.exists?(metadata_path)

      File.write!(handoff_path, "cleanup fixture")
      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, handoff, opts)
      File.rm!(handoff_path)

      assert :ok = SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)
      refute File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "delete by grant requires managed metadata and namespace inputs" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-delete-inputs-#{System.unique_integer([:positive])}")
    metadata_dir = Path.join(System.tmp_dir!(), "sympp-handoff-delete-arbitrary-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    metadata_path = managed_metadata_file(package, grant, opts)

    try do
      assert function_exported?(SecretHandoff, :delete_worker_secret_by_grant, 3)
      refute function_exported?(SecretHandoff, :delete_worker_secret_by_grant, 2)

      assert {:error, :missing_repo_root} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, Keyword.delete(opts, :repo_root))

      assert {:error, :unsupported_handoff_metadata_location} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, Keyword.put(opts, :metadata_dir, metadata_dir))

      assert {:error, {:handoff_metadata_read_failed, :enoent}} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)

      File.mkdir_p!(Path.dirname(local_private_file_path(package, grant, opts)))
      File.write!(local_private_file_path(package, grant, opts), "missing metadata cleanup fixture")

      assert {:error, {:handoff_metadata_read_failed, :enoent}} =
               SecretHandoff.delete_worker_secret_by_grant(
                 package,
                 grant,
                 Keyword.put(opts, :cleanup_unreadable_metadata?, true)
               )

      assert File.exists?(local_private_file_path(package, grant, opts))

      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(metadata_path, "{not json")
      File.write!(local_private_file_path(package, grant, opts), "cleanup fixture")

      assert {:error, {:handoff_metadata_read_failed, :invalid_json}} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)

      assert File.exists?(local_private_file_path(package, grant, opts))
      assert File.exists?(metadata_path)

      assert {:error, {:handoff_metadata_read_failed, :invalid_json}} =
               SecretHandoff.delete_worker_secret_by_grant(
                 package,
                 grant,
                 Keyword.put(opts, :cleanup_unreadable_metadata?, true)
               )

      assert File.exists?(local_private_file_path(package, grant, opts))
      assert File.exists?(metadata_path)

      File.rm!(local_private_file_path(package, grant, opts))

      File.write!(
        metadata_path,
        Jason.encode!(metadata_record(package, grant, "local-private-file", %{"path" => local_private_file_path(package, grant, opts)}))
      )

      assert :ok =
               SecretHandoff.delete_worker_secret_by_grant(
                 package,
                 grant,
                 Keyword.put(opts, :cleanup_unreadable_metadata?, true)
               )

      refute File.exists?(local_private_file_path(package, grant, opts))
      refute File.exists?(metadata_path)

      auto_opts = Keyword.put(opts, :mode, "auto")
      File.write!(metadata_path, "{not json")

      assert {:error, {:handoff_metadata_read_failed, :invalid_json}} =
               SecretHandoff.delete_worker_secret_by_grant(
                 package,
                 grant,
                 Keyword.put(auto_opts, :cleanup_unreadable_metadata?, true)
               )

      assert File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
      File.rm_rf!(metadata_dir)
    end
  end

  test "delete by grant takes the metadata lock before reading the record" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-delete-lock-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()

    opts = [
      mode: "local-private-file",
      store_dir: store_dir,
      claimed_by: "worker-local-1",
      repo_root: @repo_root,
      metadata_lock_attempts: 1,
      metadata_lock_sleep_ms: 0,
      metadata_lock_stale_seconds: 3_600
    ]

    metadata_path = managed_metadata_file(package, grant, opts)
    lock_path = "#{metadata_path}.lock"

    try do
      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(lock_path, "active")

      assert {:error, {:handoff_metadata_write_failed, {:lock, :timeout}}} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)

      assert File.exists?(lock_path)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "delete by grant rejects mismatched metadata without deleting local files" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-delete-mismatch-#{System.unique_integer([:positive])}")
    package = work_package("wp/delete")
    grant = worker_grant("cleanup-secret", id: "ag/delete", display_key: "D/21?")
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    expected_path = local_private_file_path(package, grant, opts)
    arbitrary_path = Path.join(store_dir, "arbitrary.secret")
    metadata_path = managed_metadata_file(package, grant, opts)
    metadata = metadata_record(package, grant, "local-private-file", %{"path" => expected_path})

    try do
      File.mkdir_p!(Path.dirname(expected_path))
      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(expected_path, "cleanup fixture")
      File.write!(arbitrary_path, "not a generated handoff")

      for {key, value, reason} <- [
            {"work_package_id", "other-package", {:metadata_mismatch, "work_package_id"}},
            {"worker_grant_display_key", "other-key", {:metadata_mismatch, "worker_grant_display_key"}},
            {"worker_grant_id", "other-grant", {:metadata_mismatch, "worker_grant_id"}},
            {"mode", "unsupported", {:unsupported_mode, "unsupported"}}
          ] do
        File.write!(metadata_path, Jason.encode!(Map.put(metadata, key, value)))

        assert {:error, {:handoff_metadata_invalid, ^reason}} =
                 SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)

        assert File.exists?(expected_path)
        assert File.exists?(metadata_path)
      end

      File.write!(metadata_path, Jason.encode!(Map.put(metadata, "path", arbitrary_path)))

      assert {:error, {:handoff_metadata_invalid, :local_path_mismatch}} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)

      assert File.exists?(expected_path)
      assert File.exists?(arbitrary_path)
      assert File.exists?(metadata_path)

      assert {:error, {:handoff_metadata_invalid, :local_path_mismatch}} =
               SecretHandoff.delete_worker_secret_by_grant(
                 package,
                 grant,
                 Keyword.put(opts, :cleanup_unreadable_metadata?, true)
               )

      assert File.exists?(expected_path)
      assert File.exists?(arbitrary_path)
      assert File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "delete by grant validates Windows credential metadata before cleanup and preserves failed cleanup metadata" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-delete-credential-#{System.unique_integer([:positive])}")
    missing_repo_root = Path.join(store_dir, "missing-repo")
    package = work_package()
    grant = worker_grant()

    opts = [
      mode: "windows-credential-manager",
      store_dir: store_dir,
      claimed_by: "worker-windows-1",
      repo_root: missing_repo_root
    ]

    target = credential_target(package, grant)
    metadata_path = managed_metadata_file(package, grant, opts)
    metadata = metadata_record(package, grant, "windows-credential-manager", %{"target" => target})

    try do
      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(metadata_path, Jason.encode!(Map.put(metadata, "target", "other-target")))

      assert {:error, {:handoff_metadata_invalid, :credential_target_mismatch}} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)

      assert File.exists?(metadata_path)

      assert {:error, {:handoff_metadata_invalid, :credential_target_mismatch}} =
               SecretHandoff.delete_worker_secret_by_grant(
                 package,
                 grant,
                 Keyword.put(opts, :cleanup_unreadable_metadata?, true)
               )

      assert File.exists?(metadata_path)

      File.write!(metadata_path, "{not json")

      assert {:error, {:handoff_metadata_read_failed, :invalid_json}} =
               SecretHandoff.delete_worker_secret_by_grant(
                 package,
                 grant,
                 Keyword.put(opts, :cleanup_unreadable_metadata?, true)
               )

      assert File.exists?(metadata_path)

      File.write!(metadata_path, Jason.encode!(metadata))

      assert {:error, {:windows_credential_manager_delete_failed, _reason}} =
               SecretHandoff.delete_worker_secret_by_grant(package, grant, opts)

      assert File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "omits metadata run command when repo root no longer validates" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-no-command-#{System.unique_integer([:positive])}")
    repo_root = Path.join(System.tmp_dir!(), "sympp-handoff-repo-root-#{System.unique_integer([:positive])}")
    script_path = Path.join([repo_root, "scripts", local_private_file_script_name()])
    package = work_package()
    grant = worker_grant("display-secret", claimed_by: "claimed-worker-1")
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: repo_root]
    handoff_path = local_private_file_path(package, grant, opts)
    handoff = %{"mode" => "local-private-file", "path" => handoff_path}

    try do
      File.mkdir_p!(Path.dirname(script_path))
      File.write!(script_path, "#!/bin/sh\n")
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "display fixture")

      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, handoff, opts)
      assert {:ok, display} = SecretHandoff.read_worker_secret_metadata(package, grant, opts)
      assert display.run_mcp_command =~ "run-mcp-local-file"

      File.rm!(script_path)

      assert {:ok, display_without_command} = SecretHandoff.read_worker_secret_metadata(package, grant, opts)
      assert display_without_command.path == handoff_path
      refute Map.has_key?(display_without_command, :run_mcp_command)
    after
      File.rm_rf!(store_dir)
      File.rm_rf!(repo_root)
    end
  end

  test "reads redacted managed metadata by grant identity for operator handoff display" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-read-local-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("display-secret", claimed_by: "claimed-worker-1")
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    handoff_path = local_private_file_path(package, grant, opts)
    handoff = %{"mode" => "local-private-file", "path" => handoff_path}

    try do
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "display fixture")

      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, handoff, opts)
      assert {:ok, display} = SecretHandoff.read_worker_secret_metadata(package, grant, opts)

      assert display.mode == "local-private-file"
      assert display.status == "stored"
      assert display.work_package_id == package.id
      assert display.grant_id == grant.id
      assert display.display_key == grant.display_key
      assert display.target == credential_target(package, grant)
      assert display.path == handoff_path
      assert display.claimed_by == "claimed-worker-1"
      assert display.suggested_claimed_by == "worker-local-1"
      assert display.secret_in_stdout == false
      assert display.run_mcp_command =~ "run-mcp-local-file"
      assert local_file_run_mcp_command_claims_worker?(display.run_mcp_command, "claimed-worker-1")
      refute inspect(display) =~ "display-secret"

      File.rm!(handoff_path)
      assert {:ok, stale_display} = SecretHandoff.read_worker_secret_metadata(package, grant, opts)
      assert stale_display.path == handoff_path
      assert local_file_run_mcp_command_claims_worker?(stale_display.run_mcp_command, "claimed-worker-1")

      unclaimed_grant = worker_grant("unclaimed-display-secret", id: "grant-unclaimed-display", display_key: "U321")
      unclaimed_path = local_private_file_path(package, unclaimed_grant, opts)
      File.write!(unclaimed_path, "unclaimed display fixture")

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 unclaimed_grant,
                 %{"mode" => "local-private-file", "path" => unclaimed_path},
                 opts
               )

      assert {:ok, unclaimed_display} = SecretHandoff.read_worker_secret_metadata(package, unclaimed_grant, opts)
      assert unclaimed_display.claimed_by == nil
      assert unclaimed_display.suggested_claimed_by == "worker-local-1"
      assert local_file_run_mcp_command_claims_worker?(unclaimed_display.run_mcp_command, "worker-local-1")

      File.write!(managed_metadata_file(package, grant, opts), Jason.encode!(metadata_record(package, grant, "local-private-file", %{"path" => Path.join(store_dir, "other.secret")})))

      assert {:error, {:handoff_metadata_invalid, :local_path_mismatch}} =
               SecretHandoff.read_worker_secret_metadata(package, grant, opts)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "metadata namespace canonicalizes equivalent filesystem database paths" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-db-namespace-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("canonical-database-secret")
    database_path = Path.join(File.cwd!(), "tmp/sympp-handoff-db-#{System.unique_integer([:positive])}.sqlite3")
    relative_database = Path.relative_to(database_path, File.cwd!())

    absolute_opts = [
      mode: "local-private-file",
      store_dir: store_dir,
      repo_root: @repo_root,
      database: database_path,
      claimed_by: "worker-local-1"
    ]

    relative_opts = Keyword.put(absolute_opts, :database, relative_database)

    assert managed_metadata_file(package, grant, absolute_opts) ==
             managed_metadata_file(package, grant, relative_opts)

    assert local_private_file_path(package, grant, absolute_opts) ==
             local_private_file_path(package, grant, relative_opts)
  end

  test "metadata persistence treats nil store dir as the default store" do
    package = work_package()
    grant = worker_grant()

    nil_store_opts = [
      mode: "local-private-file",
      store_dir: nil,
      repo_root: @repo_root,
      claimed_by: "worker-local-1"
    ]

    default_store_opts = Keyword.delete(nil_store_opts, :store_dir)
    handoff_path = local_private_file_path(package, grant, default_store_opts)

    assert managed_metadata_file(package, grant, nil_store_opts) ==
             managed_metadata_file(package, grant, default_store_opts)

    assert {:error, {:handoff_metadata_invalid, :missing_local_file}} =
             SecretHandoff.store_worker_secret_metadata(
               package,
               grant,
               %{"mode" => "local-private-file", "path" => handoff_path},
               nil_store_opts
             )
  end

  test "rejects arbitrary existing local files instead of accepting path ownership lookalikes" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-local-reject-#{System.unique_integer([:positive])}")
    package = work_package("a/b")
    grant = worker_grant("synthetic-secret", id: "ag/one", display_key: "D/21?")
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    expected_path = local_private_file_path(package, grant, opts)
    arbitrary_path = Path.join(store_dir, "a_b-D_21_-ag_one-existing.secret")

    try do
      File.mkdir_p!(Path.dirname(expected_path))
      File.write!(expected_path, "metadata fixture")
      File.write!(arbitrary_path, "not the generated handoff path")

      assert {:error, {:handoff_metadata_invalid, :local_path_mismatch}} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => arbitrary_path},
                 opts
               )

      assert {:error, {:handoff_metadata_invalid, :local_path_mismatch}} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => Path.dirname(expected_path)},
                 opts
               )
    after
      File.rm_rf!(store_dir)
    end
  end

  test "accepts identical metadata replay and rejects conflicting coordinates without overwrite" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-replay-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    handoff_path = local_private_file_path(package, grant, opts)
    metadata_path = managed_metadata_file(package, grant, opts)
    target = credential_target(package, grant)

    try do
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "metadata fixture")

      first_handoff = %{"mode" => "local-private-file", "path" => handoff_path}
      second_handoff = %{"mode" => "windows-credential-manager", "target" => target}

      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, first_handoff, opts)
      first_metadata_json = File.read!(metadata_path)

      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, first_handoff, opts)
      assert File.read!(metadata_path) == first_metadata_json

      assert {:error, :handoff_metadata_conflict} =
               SecretHandoff.store_worker_secret_metadata(package, grant, second_handoff, opts)

      assert File.read!(metadata_path) == first_metadata_json
    after
      File.rm_rf!(store_dir)
    end
  end

  test "recovers stale metadata locks without ignoring live lock contention" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-lock-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    handoff_path = local_private_file_path(package, grant, opts)
    metadata_path = managed_metadata_file(package, grant, opts)
    lock_path = "#{metadata_path}.lock"
    handoff = %{"mode" => "local-private-file", "path" => handoff_path}

    try do
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "metadata fixture")
      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(lock_path, "active")

      active_lock_opts = Keyword.merge(opts, metadata_lock_attempts: 1, metadata_lock_sleep_ms: 0, metadata_lock_stale_seconds: 3_600)

      assert {:error, {:handoff_metadata_write_failed, {:lock, :timeout}}} =
               SecretHandoff.store_worker_secret_metadata(package, grant, handoff, active_lock_opts)

      assert File.exists?(lock_path)

      File.touch!(lock_path, System.os_time(:second) - 3_600)

      stale_lock_opts = Keyword.merge(opts, metadata_lock_attempts: 2, metadata_lock_sleep_ms: 0, metadata_lock_stale_seconds: 60)

      assert :ok = SecretHandoff.store_worker_secret_metadata(package, grant, handoff, stale_lock_opts)

      refute File.exists?(lock_path)
      assert File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
    end
  end

  test "concurrent conflicting metadata writes preserve one coordinate" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-concurrent-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    handoff_path = local_private_file_path(package, grant, opts)
    metadata_path = managed_metadata_file(package, grant, opts)
    target = credential_target(package, grant)

    try do
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "metadata fixture")

      results =
        [
          %{"mode" => "local-private-file", "path" => handoff_path},
          %{"mode" => "windows-credential-manager", "target" => target}
        ]
        |> Enum.map(fn handoff ->
          Task.async(fn ->
            receive do
              :write_metadata -> SecretHandoff.store_worker_secret_metadata(package, grant, handoff, opts)
            end
          end)
        end)
        |> then(fn tasks ->
          Enum.each(tasks, &send(&1.pid, :write_metadata))
          Enum.map(tasks, &Task.await(&1, 5_000))
        end)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :handoff_metadata_conflict})) == 1

      metadata = metadata_path |> File.read!() |> Jason.decode!()

      assert Map.take(metadata, ["mode", "path"]) == %{"mode" => "local-private-file", "path" => handoff_path} or
               Map.take(metadata, ["mode", "target"]) == %{"mode" => "windows-credential-manager", "target" => target}
    after
      File.rm_rf!(store_dir)
    end
  end

  test "stores Windows credential metadata only for the generated target" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-target-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()
    opts = [mode: "windows-credential-manager", store_dir: store_dir, claimed_by: "worker-windows-1", repo_root: @repo_root]
    target = credential_target(package, grant)
    metadata_path = managed_metadata_file(package, grant, opts)

    try do
      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "windows-credential-manager", "target" => target},
                 opts
               )

      assert %{
               "mode" => "windows-credential-manager",
               "target" => ^target
             } = metadata_path |> File.read!() |> Jason.decode!()

      refute File.read!(metadata_path) =~ "path"

      assert {:error, {:handoff_metadata_invalid, :credential_target_mismatch}} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "windows-credential-manager", "target" => "other-target"},
                 opts
               )
    after
      File.rm_rf!(store_dir)
    end
  end

  test "rejects unsupported managed metadata inputs" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-invalid-#{System.unique_integer([:positive])}")
    metadata_dir = Path.join(System.tmp_dir!(), "sympp-handoff-arbitrary-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant()
    opts = [mode: "local-private-file", store_dir: store_dir, claimed_by: "worker-local-1", repo_root: @repo_root]
    handoff_path = local_private_file_path(package, grant, opts)

    try do
      File.mkdir_p!(Path.dirname(handoff_path))
      File.write!(handoff_path, "metadata fixture")

      assert {:error, :missing_worker_grant_display_key} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 Map.delete(grant, :display_key),
                 %{"mode" => "local-private-file", "path" => handoff_path},
                 opts
               )

      assert {:error, :missing_worker_grant_identity} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 Map.delete(grant, :id),
                 %{"mode" => "local-private-file", "path" => handoff_path},
                 opts
               )

      assert {:error, :missing_claimed_by} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => handoff_path},
                 Keyword.delete(opts, :claimed_by)
               )

      assert {:error, :unsupported_handoff_metadata_location} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => handoff_path},
                 Keyword.put(opts, :metadata_dir, metadata_dir)
               )

      assert {:error, :unsupported_handoff_metadata_location} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => handoff_path},
                 Keyword.put(opts, :metadata_path, Path.join(metadata_dir, "arbitrary.json"))
               )

      assert {:error, {:handoff_metadata_invalid, :missing_local_path}} =
               SecretHandoff.store_worker_secret_metadata(package, grant, %{"mode" => "local-private-file"}, opts)

      missing_file_opts = Keyword.put(opts, :database, "missing-file.sqlite3")

      assert {:error, {:handoff_metadata_invalid, :missing_local_file}} =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => local_private_file_path(package, grant, missing_file_opts)},
                 missing_file_opts
               )

      refute File.exists?(metadata_dir)
    after
      File.rm_rf!(store_dir)
      File.rm_rf!(metadata_dir)
    end
  end

  test "does not persist managed metadata during worker secret storage" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-handoff-explicit-only-#{System.unique_integer([:positive])}")
    package = work_package()
    grant = worker_grant("runtime-storage-value-#{System.unique_integer([:positive])}")

    metadata_path =
      managed_metadata_file(package, grant,
        mode: "local-private-file",
        store_dir: store_dir,
        claimed_by: "worker-local-1",
        repo_root: @repo_root
      )

    try do
      assert {:ok, _handoff} =
               SecretHandoff.store_worker_secret(
                 %{work_package: package, worker_grant: grant},
                 mode: "local-private-file",
                 store_dir: store_dir,
                 claimed_by: "worker-local-1",
                 repo_root: @repo_root
               )

      refute File.exists?(metadata_path)
    after
      File.rm_rf!(store_dir)
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
    assert SecretHandoff.error_message(:unsupported_handoff_metadata_location) =~ "managed metadata"
    assert SecretHandoff.error_message(:unsupported_secret_handoff_mode) =~ "local-private-file"
    assert SecretHandoff.error_message(:handoff_metadata_conflict) =~ "different coordinates"
    assert SecretHandoff.error_message(:local_private_file_unavailable_on_windows) =~ "local-private-file"
    assert SecretHandoff.error_message(:windows_credential_manager_unavailable) =~ "Windows handoff helpers"
    assert SecretHandoff.error_message({:handoff_metadata_invalid, :missing_mode}) =~ "metadata is invalid"
    assert SecretHandoff.error_message({:handoff_metadata_delete_failed, :eacces}) =~ "metadata cleanup failed"
    assert SecretHandoff.error_message({:handoff_metadata_read_failed, :invalid_json}) =~ "metadata read failed"
    assert SecretHandoff.error_message({:handoff_metadata_write_failed, :eacces}) =~ "metadata write failed"
    assert SecretHandoff.error_message({:local_private_file_failed, RuntimeError}) =~ "RuntimeError"
    assert SecretHandoff.error_message({:windows_credential_manager_failed, 1}) =~ "exit status 1"
  end

  test "auto mode stores a local private-file handoff" do
    secret = "synthetic-auto-local-secret-#{System.unique_integer([:positive])}"
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-auto-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "auto",
                 store_dir: store_dir,
                 claimed_by: "worker-auto-1",
                 repo_root: @repo_root
               )

      assert handoff.mode == "local-private-file"
      assert handoff.secret_in_stdout == false
      assert local_file_run_mcp_command_uses_platform_wrapper?(handoff.run_mcp_command)
      assert File.read!(handoff.path) == secret
    after
      File.rm_rf!(store_dir)
    end
  end

  if @windows, do: @tag(skip: "POSIX chmod failure hook is non-Windows only")

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

  test "explicit Windows Credential Manager mode uses command result without local fallback" do
    secret = "synthetic-windows-command-#{System.unique_integer([:positive])}"

    command = fn powershell, args, cmd_opts ->
      assert powershell == "synthetic-powershell"
      assert "store" in args
      assert "-Target" in args
      assert Keyword.fetch!(cmd_opts, :env) == [{"SYMPP_WORK_KEY_SECRET", secret}]
      {"stored", 0}
    end

    assert {:ok, handoff} =
             SecretHandoff.store_worker_secret(creation(secret),
               mode: "windows-credential-manager",
               repo_root: @repo_root,
               database: "test-ledger.sqlite3",
               claimed_by: "worker-windows-1",
               powershell_executable: "synthetic-powershell",
               windows_credential_command: command
             )

    assert handoff.mode == "windows-credential-manager"
    assert handoff.store == "Windows Credential Manager"
    assert handoff.run_mcp_command =~ "synthetic-powershell"
    assert handoff.run_mcp_command =~ handoff.target
    refute inspect(handoff) =~ secret
  end

  test "explicit Windows Credential Manager store failure is reported" do
    command = fn _powershell, args, _cmd_opts ->
      assert "store" in args
      {"failed", 1}
    end

    assert {:error, {:windows_credential_manager_failed, 1}} =
             SecretHandoff.store_worker_secret(creation("synthetic-windows-failure"),
               mode: "windows-credential-manager",
               repo_root: @repo_root,
               claimed_by: "worker-windows-1",
               powershell_executable: "synthetic-powershell",
               windows_credential_command: command
             )
  end

  test "stores a synthetic secret in Windows Credential Manager without returning the secret" do
    powershell = powershell_executable()

    if windows_credential_manager_integration_enabled?(powershell) do
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

  test "checks Windows Credential Manager handoff availability without returning the secret" do
    powershell = powershell_executable()

    if windows_credential_manager_integration_enabled?(powershell) do
      secret = "synthetic-windows-availability-#{System.unique_integer([:positive])}"

      assert {:ok, handoff} =
               SecretHandoff.store_worker_secret(creation(secret),
                 mode: "windows-credential-manager",
                 repo_root: @repo_root,
                 database: "test-ledger.sqlite3",
                 claimed_by: "worker-windows-availability"
               )

      try do
        secret_hash = WorkKey.secret_hash(secret)
        assert SecretHandoff.worker_secret_availability(handoff, repo_root: @repo_root) == :available
        assert SecretHandoff.worker_secret_available?(handoff, repo_root: @repo_root)
        assert SecretHandoff.worker_secret_integrity(handoff, secret_hash, repo_root: @repo_root) == :match
        refute inspect(handoff) =~ secret

        remove_windows_credential!(powershell, handoff.target)

        assert SecretHandoff.worker_secret_availability(handoff, repo_root: @repo_root) == :missing
        assert SecretHandoff.worker_secret_integrity(handoff, secret_hash, repo_root: @repo_root) == :mismatch
        refute SecretHandoff.worker_secret_available?(handoff, repo_root: @repo_root)
        refute inspect(handoff) =~ secret
      after
        if is_binary(handoff.target) do
          remove_windows_credential!(powershell, handoff.target)
        end
      end
    end
  end

  test "reports Windows Credential Manager availability as unknown when the helper cannot run" do
    handoff = %{
      mode: "windows-credential-manager",
      target: "SymphonyPlusPlus:worker:missing-helper:D321:#{@default_worker_grant_id}"
    }

    missing_repo_root = Path.join(System.tmp_dir!(), "sympp-missing-helper-#{System.unique_integer([:positive])}")

    assert SecretHandoff.worker_secret_availability(handoff, repo_root: missing_repo_root) == :unknown
    refute SecretHandoff.worker_secret_available?(handoff, repo_root: missing_repo_root)
  end

  test "uses grant identity to namespace Windows Credential Manager targets when display keys collide" do
    powershell = powershell_executable()

    if windows_credential_manager_integration_enabled?(powershell) do
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

  defp metadata_record(%WorkPackage{} = work_package, worker_grant, mode, coordinates) do
    %{
      "version" => 1,
      "work_package_id" => work_package.id,
      "worker_grant_display_key" => worker_grant.display_key,
      "worker_grant_id" => worker_grant.id,
      "mode" => mode
    }
    |> Map.merge(coordinates)
  end

  defp managed_metadata_file(%WorkPackage{} = work_package, worker_grant, opts) do
    opts
    |> metadata_store_dir()
    |> Path.join("metadata")
    |> Path.join("handoff-#{metadata_hash(work_package.id, worker_grant.display_key, worker_grant.id, opts)}.json")
  end

  defp metadata_hash(work_package_id, display_key, grant_identity, opts) do
    hash_source = [
      "v1",
      0,
      opts |> Keyword.get(:repo_root, "") |> to_string() |> Path.expand(),
      0,
      database_hash_value(opts),
      0,
      metadata_store_dir(opts),
      0,
      work_package_id,
      0,
      display_key,
      0,
      grant_identity
    ]

    :sha256
    |> :crypto.hash(hash_source)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp metadata_store_dir(opts) do
    store_dir = Keyword.get(opts, :store_dir) || default_local_private_store_dir()
    Path.expand(store_dir)
  end

  defp local_private_file_path(%WorkPackage{} = work_package, worker_grant, opts) do
    store_dir = Keyword.get(opts, :store_dir) || default_local_private_store_dir()
    display_key = worker_grant.display_key
    grant_identity = String.trim(worker_grant.id)

    filename =
      "#{safe_filename(work_package.id)}-#{safe_filename(display_key)}-#{safe_filename(grant_identity)}-#{handoff_filename_hash(work_package, display_key, grant_identity, opts)}.secret"

    Path.join(Path.expand(store_dir), filename)
  end

  defp handoff_filename_hash(%WorkPackage{} = work_package, display_key, grant_identity, opts) do
    hash_source = [
      opts |> Keyword.get(:repo_root, "") |> to_string() |> Path.expand(),
      0,
      database_hash_value(opts),
      0,
      work_package.id,
      0,
      display_key,
      0,
      grant_identity
    ]

    :sha256
    |> :crypto.hash(hash_source)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp database_hash_value(opts) do
    case Keyword.get(opts, :database) do
      database when is_binary(database) ->
        database
        |> String.trim()
        |> database_hash_value(database)

      nil ->
        ""

      database ->
        :erlang.term_to_binary(database)
    end
  end

  defp database_hash_value("", _database), do: ""
  defp database_hash_value(_trimmed, database), do: database |> Repo.database_key() |> :erlang.term_to_binary()

  defp credential_target(%WorkPackage{id: work_package_id}, worker_grant) do
    "SymphonyPlusPlus:worker:#{work_package_id}:#{worker_grant.display_key}:#{String.trim(worker_grant.id)}"
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

  defp remove_windows_credential!(powershell, target) do
    script_path = Path.join(@repo_root, "scripts/sympp-worker-secret.ps1")

    System.cmd(
      powershell,
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path, "remove", "-Target", target],
      stderr_to_stdout: true
    )
  end

  defp windows_credential_manager_writable?(powershell) when is_binary(powershell) do
    if windows?() do
      target = "SymphonyPlusPlus:test:wcm-probe:#{System.unique_integer([:positive])}"
      script_path = Path.join(@repo_root, "scripts/sympp-worker-secret.ps1")

      try do
        case System.cmd(
               powershell,
               [
                 "-NoProfile",
                 "-ExecutionPolicy",
                 "Bypass",
                 "-File",
                 script_path,
                 "store",
                 "-Target",
                 target,
                 "-UserName",
                 "sympp-wcm-probe"
               ],
               env: [{"SYMPP_WORK_KEY_SECRET", "synthetic-wcm-probe-secret"}],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> true
          {_output, _status} -> false
        end
      after
        remove_windows_credential!(powershell, target)
      end
    else
      false
    end
  rescue
    _error -> false
  end

  defp windows_credential_manager_writable?(_powershell), do: false

  defp windows_credential_manager_integration_enabled?(powershell) do
    System.get_env("SYMPP_RUN_WCM_INTEGRATION") in ["1", "true", "TRUE"] and
      windows_credential_manager_writable?(powershell)
  end

  defp powershell_executable do
    System.find_executable("powershell.exe") ||
      System.find_executable("pwsh") ||
      System.find_executable("powershell")
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp local_file_run_mcp_command_uses_platform_wrapper?(command) do
    if windows?() do
      command =~ "sympp-worker-secret.ps1" and command =~ "run-mcp-local-file" and command =~ "-SecretFile"
    else
      command =~ "sympp-worker-secret.sh" and command =~ "run-mcp-local-file"
    end
  end

  defp local_file_run_mcp_command_claims_worker?(command, claimed_by) do
    if windows?() do
      command =~ ~s(-ClaimedBy #{powershell_literal(claimed_by)})
    else
      command =~ ~s(--claimed-by #{shell_literal(claimed_by)})
    end
  end

  defp local_private_file_script_name do
    if windows?(), do: "sympp-worker-secret.ps1", else: "sympp-worker-secret.sh"
  end

  defp powershell_literal(value) do
    "'#{String.replace(to_string(value), "'", "''")}'"
  end

  defp shell_literal(value) do
    "'#{String.replace(to_string(value), "'", "'\"'\"'")}'"
  end

  defp restore_repo_root_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_root)
  defp restore_repo_root_env(repo_root), do: Application.put_env(:symphony_elixir, :sympp_repo_root, repo_root)
end
