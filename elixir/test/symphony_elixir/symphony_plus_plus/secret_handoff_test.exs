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
      assert Path.basename(handoff.path) =~ ~r/^wp-secret-handoff-ag-secret-handoff-D321-[A-Za-z0-9_-]{16}\.secret$/
      assert handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:ag-secret-handoff-D321"
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
      assert Path.basename(handoff.path) =~ ~r/^wp-secret-handoff-ag-secret-handoff-D321-[A-Za-z0-9_-]{16}\.secret$/
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

  test "keys local handoff filenames by grant id instead of display key or launch paths" do
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-collision-#{System.unique_integer([:positive])}")
    package = work_package()
    first_grant = worker_grant("first-secret", "ag-secret-handoff-first", "D321")
    second_grant = worker_grant("second-secret", "ag-secret-handoff-second", "D321")

    opts = [
      mode: "local-private-file",
      store_dir: store_dir,
      database: "ledger-a.sqlite3",
      claimed_by: "worker-local-1",
      repo_root: @repo_root
    ]

    try do
      assert {:ok, first_handoff} =
               SecretHandoff.store_worker_secret(creation("first-secret", package, first_grant), opts)

      assert {:ok, second_handoff} =
               SecretHandoff.store_worker_secret(creation("second-secret", package, second_grant), opts)

      changed_launch_opts =
        opts
        |> Keyword.put(:database, "ledger-b.sqlite3")
        |> Keyword.put(:repo_root, Path.expand("..", @repo_root))

      assert {:ok, replacement_handoff} =
               SecretHandoff.store_worker_secret(creation("replacement-secret", package, first_grant), changed_launch_opts)

      assert first_handoff.path != second_handoff.path
      assert replacement_handoff.path == first_handoff.path
      assert Path.basename(first_handoff.path) =~ "ag-secret-handoff-first"
      assert Path.basename(second_handoff.path) =~ "ag-secret-handoff-second"
      assert File.read!(first_handoff.path) == "replacement-secret"
      assert File.read!(second_handoff.path) == "second-secret"

      relabeled_first_grant = worker_grant("replacement-secret", "ag-secret-handoff-first", "Z999")
      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, relabeled_first_grant, changed_launch_opts)
      refute File.exists?(first_handoff.path)
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

  test "uses stable explicit metadata filenames across repo root and database option changes" do
    package = work_package()
    grant = public_worker_grant("ag-secret-stable-metadata-D321")
    relabeled_grant = public_worker_grant("ag-secret-stable-metadata-D321", "Z999")
    metadata_dir = Path.join(System.tmp_dir!(), "sympp-secret-stable-metadata-#{System.unique_integer([:positive])}")
    secret_dir = Path.join(System.tmp_dir!(), "sympp-secret-stable-metadata-secret-#{System.unique_integer([:positive])}")
    secret_path = stable_local_secret_path(package, grant, secret_dir)

    store_opts = [
      mode: "windows-credential-manager",
      metadata_dir: metadata_dir,
      database: "tmp/original-ledger.sqlite3",
      claimed_by: "worker-local-1",
      repo_root: @repo_root
    ]

    cleanup_opts =
      store_opts
      |> Keyword.put(:database, "tmp/renamed-ledger.sqlite3")
      |> Keyword.put(:repo_root, Path.expand("..", @repo_root))

    explicit_metadata_file = stable_handoff_metadata_file(package, grant, metadata_dir)
    default_metadata_file = stable_handoff_metadata_file(package, grant, default_handoff_metadata_dir())

    try do
      File.mkdir_p!(secret_dir)
      File.write!(secret_path, "synthetic-stable-metadata-secret")

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => secret_path},
                 store_opts
               )

      assert File.exists?(explicit_metadata_file)
      assert File.exists?(default_metadata_file)
      File.rm!(default_metadata_file)

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, relabeled_grant, cleanup_opts)
      refute File.exists?(secret_path)
      refute File.exists?(explicit_metadata_file)
    after
      File.rm(secret_path)
      File.rm(explicit_metadata_file)
      File.rm(default_metadata_file)
      File.rm_rf!(metadata_dir)
      File.rm_rf!(secret_dir)
    end
  end

  test "deletes recorded metadata mirrors without the original store_dir option" do
    package = work_package()
    grant = public_worker_grant("ag-secret-custom-mirror-D321")
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-custom-mirror-#{System.unique_integer([:positive])}")
    secret_path = stable_local_secret_path(package, grant, store_dir)

    store_opts = [
      mode: "windows-credential-manager",
      store_dir: store_dir,
      claimed_by: "worker-local-1",
      repo_root: @repo_root
    ]

    cleanup_opts = [mode: "windows-credential-manager"]

    custom_metadata_file = stable_handoff_metadata_file(package, grant, Path.join(store_dir, "metadata"))
    default_metadata_file = stable_handoff_metadata_file(package, grant, default_handoff_metadata_dir())

    try do
      File.mkdir_p!(store_dir)
      File.write!(secret_path, "synthetic-custom-mirror-secret")

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => secret_path},
                 store_opts
               )

      assert File.exists?(custom_metadata_file)
      assert File.exists?(default_metadata_file)

      metadata = default_metadata_file |> File.read!() |> Jason.decode!()
      assert Enum.sort(metadata["metadata_mirrors"]) == Enum.sort([custom_metadata_file, default_metadata_file])

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, grant, cleanup_opts)
      refute File.exists?(secret_path)
      refute File.exists?(custom_metadata_file)
      refute File.exists?(default_metadata_file)
    after
      File.rm(secret_path)
      File.rm(custom_metadata_file)
      File.rm(default_metadata_file)
      File.rm_rf!(store_dir)
    end
  end

  test "does not delete recorded metadata mirrors that are not verified handoff files" do
    package = work_package()
    grant = public_worker_grant("ag-secret-untrusted-mirror-D321")
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-untrusted-mirror-#{System.unique_integer([:positive])}")
    unrelated_dir = Path.join(System.tmp_dir!(), "sympp-secret-untrusted-other-#{System.unique_integer([:positive])}")
    secret_path = stable_local_secret_path(package, grant, store_dir)

    store_opts = [
      mode: "windows-credential-manager",
      store_dir: store_dir,
      claimed_by: "worker-local-1",
      repo_root: @repo_root
    ]

    cleanup_opts = [mode: "windows-credential-manager"]

    custom_metadata_file = stable_handoff_metadata_file(package, grant, Path.join(store_dir, "metadata"))
    default_metadata_file = stable_handoff_metadata_file(package, grant, default_handoff_metadata_dir())
    unrelated_metadata_file = Path.join(unrelated_dir, Path.basename(default_metadata_file))

    try do
      File.mkdir_p!(store_dir)
      File.write!(secret_path, "synthetic-untrusted-mirror-secret")

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => secret_path},
                 store_opts
               )

      File.mkdir_p!(unrelated_dir)
      File.write!(unrelated_metadata_file, Jason.encode!(%{"unrelated" => true}))

      metadata =
        default_metadata_file
        |> File.read!()
        |> Jason.decode!()
        |> Map.update!("metadata_mirrors", &[unrelated_metadata_file | &1])

      File.write!(default_metadata_file, Jason.encode!(metadata))

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, grant, cleanup_opts)
      refute File.exists?(secret_path)
      refute File.exists?(custom_metadata_file)
      refute File.exists?(default_metadata_file)
      assert File.exists?(unrelated_metadata_file)
    after
      File.rm(secret_path)
      File.rm(custom_metadata_file)
      File.rm(default_metadata_file)
      File.rm_rf!(store_dir)
      File.rm_rf!(unrelated_dir)
    end
  end

  test "keeps caller-selected metadata when the best-effort default mirror write fails" do
    package = work_package()
    grant = public_worker_grant("ag-secret-partial-metadata-D321")
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-partial-metadata-#{System.unique_integer([:positive])}")

    custom_metadata_file = stable_handoff_metadata_file(package, grant, Path.join(store_dir, "metadata"))
    default_metadata_file = stable_handoff_metadata_file(package, grant, default_handoff_metadata_dir())

    opts = [
      mode: "windows-credential-manager",
      store_dir: store_dir,
      claimed_by: "worker-local-1",
      repo_root: @repo_root,
      private_file_rename_fun: fn temp_path, path ->
        if Path.expand(path) == Path.expand(default_metadata_file) do
          File.rm(temp_path)
          {:error, :simulated_default_metadata_failure}
        else
          File.rename(temp_path, path)
        end
      end
    ]

    try do
      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => stable_local_secret_path(package, grant, store_dir)},
                 opts
               )

      assert File.exists?(custom_metadata_file)
      refute File.exists?(default_metadata_file)
    after
      File.rm(custom_metadata_file)
      File.rm(default_metadata_file)
      File.rm_rf!(store_dir)
    end
  end

  test "continues to a valid metadata mirror after an invalid earlier mirror" do
    package = work_package()
    grant = public_worker_grant("ag-secret-custom-mirror-fallback-D321")
    store_dir = Path.join(System.tmp_dir!(), "sympp-secret-custom-mirror-fallback-#{System.unique_integer([:positive])}")
    secret_path = stable_local_secret_path(package, grant, store_dir)

    opts = [
      mode: "windows-credential-manager",
      store_dir: store_dir,
      claimed_by: "worker-local-1",
      repo_root: @repo_root
    ]

    custom_metadata_file = stable_handoff_metadata_file(package, grant, Path.join(store_dir, "metadata"))
    default_metadata_file = stable_handoff_metadata_file(package, grant, default_handoff_metadata_dir())

    try do
      File.mkdir_p!(store_dir)
      File.write!(secret_path, "synthetic-custom-mirror-fallback-secret")

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => secret_path},
                 opts
               )

      File.write!(custom_metadata_file, "{")

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, grant, opts)
      refute File.exists?(secret_path)
      refute File.exists?(custom_metadata_file)
      refute File.exists?(default_metadata_file)
    after
      File.rm(secret_path)
      File.rm(custom_metadata_file)
      File.rm(default_metadata_file)
      File.rm_rf!(store_dir)
    end
  end

  test "prefers current metadata over a stale explicit mirror" do
    package = work_package()
    grant = public_worker_grant("ag-secret-stale-mirror-D321")
    old_store_dir = Path.join(System.tmp_dir!(), "sympp-secret-stale-old-#{System.unique_integer([:positive])}")
    new_store_dir = Path.join(System.tmp_dir!(), "sympp-secret-stale-new-#{System.unique_integer([:positive])}")
    old_secret_path = stable_local_secret_path(package, grant, old_store_dir)
    new_secret_path = stable_local_secret_path(package, grant, new_store_dir)

    old_opts = [
      mode: "windows-credential-manager",
      store_dir: old_store_dir,
      claimed_by: "worker-local-1",
      repo_root: @repo_root
    ]

    new_opts =
      old_opts
      |> Keyword.put(:store_dir, new_store_dir)

    cleanup_opts = [
      mode: "windows-credential-manager",
      store_dir: old_store_dir
    ]

    old_metadata_file = stable_handoff_metadata_file(package, grant, Path.join(old_store_dir, "metadata"))
    new_metadata_file = stable_handoff_metadata_file(package, grant, Path.join(new_store_dir, "metadata"))
    default_metadata_file = stable_handoff_metadata_file(package, grant, default_handoff_metadata_dir())

    try do
      File.mkdir_p!(old_store_dir)
      File.mkdir_p!(new_store_dir)
      File.write!(old_secret_path, "synthetic-old-stale-secret")
      File.write!(new_secret_path, "synthetic-current-secret")

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => old_secret_path},
                 old_opts
               )

      assert :ok =
               SecretHandoff.store_worker_secret_metadata(
                 package,
                 grant,
                 %{"mode" => "local-private-file", "path" => new_secret_path},
                 new_opts
               )

      assert File.exists?(old_metadata_file)
      assert File.exists?(new_metadata_file)
      assert File.exists?(default_metadata_file)

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, grant, cleanup_opts)
      assert File.exists?(old_secret_path)
      refute File.exists?(new_secret_path)
      refute File.exists?(old_metadata_file)
      refute File.exists?(new_metadata_file)
      refute File.exists?(default_metadata_file)
    after
      File.rm(old_secret_path)
      File.rm(new_secret_path)
      File.rm(old_metadata_file)
      File.rm(new_metadata_file)
      File.rm(default_metadata_file)
      File.rm_rf!(old_store_dir)
      File.rm_rf!(new_store_dir)
    end
  end

  test "does not trust primary metadata whose delete target does not belong to the grant" do
    package = work_package()
    grant = public_worker_grant("ag-secret-corrupt-primary-D321")
    unrelated_path = Path.join(System.tmp_dir!(), "sympp-secret-unrelated-#{System.unique_integer([:positive])}.secret")
    default_metadata_file = stable_handoff_metadata_file(package, grant, default_handoff_metadata_dir())

    try do
      File.mkdir_p!(Path.dirname(default_metadata_file))
      File.write!(unrelated_path, "synthetic-unrelated-secret")

      File.write!(
        default_metadata_file,
        Jason.encode!(%{
          "mode" => "local-private-file",
          "path" => unrelated_path,
          "metadata_mirrors" => [default_metadata_file]
        })
      )

      assert :ok = SecretHandoff.delete_worker_secret_for_grant(package, grant, mode: "local-private-file")
      assert File.exists?(unrelated_path)
      refute File.exists?(default_metadata_file)
    after
      File.rm(unrelated_path)
      File.rm(default_metadata_file)
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
    handoff = %{target: "SymphonyPlusPlus:worker:wp-secret-handoff:ag-secret-handoff-D321"}

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

    assert {:error, :missing_worker_grant_identity} =
             SecretHandoff.store_worker_secret(creation("synthetic-secret", work_package(), %{display_key: "D321", secret: "synthetic-secret"}),
               mode: "local-private-file",
               claimed_by: "worker-local-1",
               repo_root: @repo_root
             )

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
    assert SecretHandoff.error_message(:missing_worker_grant_identity) =~ "stable non-secret id"
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
        assert handoff.target == "SymphonyPlusPlus:worker:wp-secret-handoff:ag-secret-handoff-D321"
        assert handoff.run_mcp_command =~ ~s(& #{powershell_literal(powershell)})
        assert handoff.run_mcp_command =~ ~s(-Target #{powershell_literal(handoff.target)})
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

  defp creation(secret, work_package \\ work_package(), grant \\ nil) do
    %{
      work_package: work_package,
      worker_grant: grant || worker_grant(secret)
    }
  end

  defp work_package(id \\ "wp-secret-handoff") do
    %WorkPackage{id: id}
  end

  defp worker_grant(secret \\ "synthetic-secret", id \\ "ag-secret-handoff-D321", display_key \\ "D321") do
    %{id: id, display_key: display_key, secret: secret}
  end

  defp public_worker_grant(id, display_key \\ "D321") do
    %{id: id, display_key: display_key}
  end

  defp stable_handoff_metadata_file(%WorkPackage{} = work_package, grant, metadata_dir) do
    grant_id = Map.fetch!(grant, :id)

    filename =
      "#{safe_filename(work_package.id)}-#{safe_filename(grant_id)}-#{stable_identity_hash(work_package.id, grant_id)}.json"

    Path.join(Path.expand(metadata_dir), filename)
  end

  defp stable_local_secret_path(%WorkPackage{} = work_package, grant, store_dir) do
    grant_id = Map.fetch!(grant, :id)

    filename =
      "#{safe_filename(work_package.id)}-#{safe_filename(grant_id)}-#{stable_identity_hash(work_package.id, grant_id)}.secret"

    Path.join(Path.expand(store_dir), filename)
  end

  defp default_handoff_metadata_dir do
    Path.join(default_local_private_store_dir(), "metadata")
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

  defp stable_identity_hash(work_package_id, identity) do
    hash_source = [work_package_id, 0, identity]

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
