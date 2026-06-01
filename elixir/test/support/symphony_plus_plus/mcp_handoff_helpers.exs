Code.require_file("mcp_common_helpers.exs", __DIR__)
Code.require_file("mcp_session_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase.HandoffHelpers do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions
  import SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers
  import SymphonyElixir.SymphonyPlusPlus.MCPCase.SessionHelpers
  alias Ecto.Adapters.SQL
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Auth
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  @child_worker_grant_provenance "child_worker_delegation"
  @handoff_store_process_key :sympp_mcp_test_handoff_store_dir

  def child_worker_template(secret_handoff_overrides \\ %{}) do
    %{
      "secret_handoff" =>
        Map.merge(
          %{
            "mode" => test_secret_handoff_mode(),
            "store_dir" => test_handoff_store_dir()
          },
          secret_handoff_overrides
        )
    }
  end

  def windows? do
    case :os.type() do
      {:win32, _name} -> true
      _type -> false
    end
  end

  def test_secret_handoff_mode do
    "auto"
  end

  def test_handoff_store_dir do
    case Process.get(@handoff_store_process_key) do
      nil -> raise "MCP test handoff store directory was not initialized"
      store_dir -> store_dir
    end
  end

  def unique_test_handoff_store_dir do
    System.tmp_dir!()
    |> Path.join("sympp-mcp-test-worker-secrets-#{System.unique_integer([:positive])}")
    |> Path.expand()
  end

  def temporary_worker_repo_root(name) do
    repo_root = Path.join(System.tmp_dir!(), "sympp-mcp-#{name}-#{System.unique_integer([:positive])}")
    script_path = Path.join([repo_root, "scripts", local_private_file_script_name()])

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(script_path, "# synthetic worker bootstrap wrapper\n")

    repo_root
  end

  def local_private_file_script_name do
    if windows?(), do: "sympp-worker-secret.ps1", else: "sympp-worker-secret.sh"
  end

  def comparable_path(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> then(fn path -> if windows?(), do: String.downcase(path), else: path end)
  end

  def solo_workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-mcp-solo-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  def test_dispatch_handoff_store_dir do
    test_handoff_store_dir()
    |> Path.join("dispatch-#{System.unique_integer([:positive])}")
  end

  def test_handoff_opts(claimed_by, store_dir \\ test_handoff_store_dir()) do
    [
      repo_root: test_repo_root(),
      claimed_by: claimed_by,
      mode: test_secret_handoff_mode(),
      store_dir: store_dir
    ]
  end

  def sqlite_file_uri(path, query) do
    encoded_path =
      path
      |> String.replace("\\", "/")
      |> URI.encode(&sqlite_file_uri_path_char?/1)

    "file:#{encoded_path}?#{query}"
  end

  def assert_same_ledger_database(%{"database" => actual_database}, expected_path, expected_query \\ nil) do
    actual_path =
      case Repo.sqlite_file_uri_path(actual_database) do
        path when is_binary(path) and path != "" -> path
        _path -> actual_database
      end

    assert Repo.same_database_path?(actual_path, expected_path)

    if expected_query do
      assert actual_database =~ "?#{expected_query}"
    end
  end

  def sqlite_file_uri_path_char?(char), do: URI.char_unreserved?(char) or char in [?/, ?:]

  def current_main_database_path(repo) do
    assert {:ok, %{rows: rows}} = SQL.query(repo, "PRAGMA database_list", [], log: false)

    case Enum.find(rows, &main_database_row?/1) do
      [_seq, "main", path] when is_binary(path) and path != "" -> path
      row -> flunk("expected file-backed test ledger for external MCP bootstrap, got: #{inspect(row)}")
    end
  end

  def restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  def restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  def run_mcp_with_windows_credential_handoff(handoff, claimed_by, database_path, input) do
    powershell = powershell_executable!()
    input_path = Path.join(System.tmp_dir!(), "sympp-mcp-stdin-#{System.unique_integer([:positive])}.jsonl")
    runner_path = Path.join(System.tmp_dir!(), "sympp-mcp-runner-#{System.unique_integer([:positive])}.cmd")

    try do
      File.write!(input_path, input)

      File.write!(runner_path, """
      @echo off
      "%SYMPP_MCP_TEST_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%SYMPP_MCP_TEST_SCRIPT%" run-mcp -Target "%SYMPP_MCP_TEST_TARGET%" -Database "%SYMPP_MCP_TEST_DATABASE%" -ClaimedBy "%SYMPP_MCP_TEST_CLAIMED_BY%" -ElixirDir "%SYMPP_MCP_TEST_ELIXIR_DIR%" < "%SYMPP_MCP_TEST_STDIN_FILE%"
      exit /b %ERRORLEVEL%
      """)

      System.cmd(
        "cmd.exe",
        ["/d", "/s", "/c", runner_path],
        cd: test_repo_root(),
        env: [
          {"MIX_ENV", "test"},
          {"MISE_NO_CONFIG", "1"},
          {"SYMPP_MCP_TEST_STDIN_FILE", input_path},
          {"SYMPP_MCP_TEST_POWERSHELL", powershell},
          {"SYMPP_MCP_TEST_SCRIPT", Path.join(test_repo_root(), "scripts/sympp-worker-secret.ps1")},
          {"SYMPP_MCP_TEST_TARGET", Map.fetch!(handoff, "target")},
          {"SYMPP_MCP_TEST_DATABASE", database_path},
          {"SYMPP_MCP_TEST_CLAIMED_BY", claimed_by},
          {"SYMPP_MCP_TEST_ELIXIR_DIR", Path.join(test_repo_root(), "elixir")}
        ],
        stderr_to_stdout: true
      )
    after
      File.rm(input_path)
      File.rm(runner_path)
    end
  end

  def powershell_executable! do
    powershell = powershell_executable()
    assert is_binary(powershell), "Windows Credential Manager MCP bootstrap test requires powershell.exe or pwsh"
    powershell
  end

  def powershell_executable do
    Enum.find_value(["powershell.exe", "powershell", "pwsh"], &System.find_executable/1)
  end

  def windows_credential_manager_writable? do
    with true <- windows?(),
         powershell when is_binary(powershell) <- powershell_executable() do
      target = "SymphonyPlusPlus:test:wcm-probe:#{System.unique_integer([:positive])}"
      script_path = Path.join(test_repo_root(), "scripts/sympp-worker-secret.ps1")

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
        SecretHandoff.delete_worker_secret(%{"mode" => "windows-credential-manager", "target" => target}, repo_root: test_repo_root())
      end
    else
      _unavailable -> false
    end
  rescue
    _error -> false
  end

  def windows_credential_manager_integration_enabled? do
    System.get_env("SYMPP_RUN_WCM_INTEGRATION") in ["1", "true", "TRUE"] and
      windows_credential_manager_writable?()
  end

  def cleanup_test_child_worker_handoffs(repo, store_dir) do
    grants =
      repo.all(
        from(grant in AccessGrant,
          where: grant.provenance == ^@child_worker_grant_provenance
        )
      )

    Enum.each(grants, fn grant ->
      with {:ok, work_package} <- WorkPackageRepository.get(repo, grant.work_package_id) do
        SecretHandoff.delete_worker_secret_by_grant(work_package, grant, test_handoff_opts("worker-1", store_dir))
      end
    end)
  end

  def claim_phase_child_worker(repo, architect_session, child_id) do
    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template(%{"claimed_by" => "worker-1"})
      })

    claim_child_worker_from_mint_response(repo, mint_response, "worker-1")
  end

  def claim_child_worker_from_mint_response(repo, mint_response, claimed_by) do
    worker_grant = get_in(mint_response, ["result", "structuredContent", "worker_grant"])
    handoff = Map.fetch!(worker_grant, "secret_handoff")

    session =
      case Map.fetch!(handoff, "mode") do
        "local-private-file" ->
          worker_secret = File.read!(Map.fetch!(handoff, "path"))
          assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_secret, claimed_by: claimed_by)
          MCPHarness.session(worker_assignment, proof_hash: WorkKey.secret_hash(worker_secret))

        "windows-credential-manager" ->
          # Windows Credential Manager retrieval is covered by the dedicated run-mcp bootstrap test.
          claim_child_worker_without_secret(repo, Map.fetch!(worker_grant, "id"), claimed_by)
      end

    cleanup_child_worker_handoff(handoff, claimed_by)
    session
  end

  def claim_child_worker_without_secret(repo, grant_id, claimed_by) do
    now = DateTime.utc_now(:microsecond)

    assert {1, _rows} =
             repo.update_all(
               from(grant in AccessGrant, where: grant.id == ^grant_id),
               set: [claimed_at: now, claimed_by: claimed_by, updated_at: now]
             )

    assert {:ok, grant} = AccessGrantRepository.get(repo, grant_id)
    assert {:ok, session} = Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash)
    session
  end

  def cleanup_child_worker_handoff(handoff, claimed_by) do
    assert :ok = SecretHandoff.delete_worker_secret(handoff, test_handoff_opts(claimed_by))
  end

  def json_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  def handoff_secret_absent?(%{"mode" => "local-private-file", "path" => path}, text) when is_binary(text) do
    case File.read(path) do
      {:ok, secret} when is_binary(secret) and secret != "" -> not String.contains?(text, secret)
      _other -> true
    end
  end

  def handoff_secret_absent?(_handoff, text), do: is_binary(text)

  def renew_phase_architect_session(repo, anchor, capabilities, claimed_by \\ "architect-1") do
    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, anchor.phase_id,
               work_package_id: anchor.id,
               capabilities: capabilities
             )

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

    MCPHarness.session(architect_assignment, proof_hash: minted.grant.secret_hash)
  end

  def advance_child_worker_to_ci_waiting(repo, worker_session) do
    [
      {"ready_for_worker", "claimed"},
      {"claimed", "planning"},
      {"planning", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, worker_session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "advance phase child test flow"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)
  end

  def attach_phase_child_ready_evidence(repo, worker_session, child_id, head_sha) do
    append_done_plan(repo, child_id)
    attach_tool(repo, worker_session, "attach_branch", %{"branch" => "agent/#{child_id}/worker", "head_sha" => head_sha})
    attach_tool(repo, worker_session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/7003", "head_sha" => head_sha})

    attach_tool(repo, worker_session, "submit_review_package", ready_review_package_args(head_sha))
  end

  def ready_review_package_args(head_sha) do
    %{
      "summary" => "Ready for architect review",
      "tests" => ["mix test elixir/test/symphony_elixir/symphony_plus_plus/mcp"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    }
  end

  def create_child_work_package(repo, session, child_id) do
    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => child_id,
          "title" => "Implement #{child_id}",
          "acceptance_criteria" => ["Complete #{child_id}"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == child_id
    child_id
  end
end
