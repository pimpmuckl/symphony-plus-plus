Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CreateWorkTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "parses valid YAML create-work requests" do
    yaml = """
    kind: hotfix
    repo: kraken
    base_branch: beta
    title: Fix allocator outage
    product_description: Allocator workers are stuck.
    engineering_scope: Restore allocator claims.
    acceptance_criteria:
      - Allocator claims recover.
    policy_template: hotfix
    """

    assert {:ok, request} = CreateWork.parse_content(yaml, "request.yaml")
    assert request["kind"] == "hotfix"
    assert request["repo"] == "kraken"
    assert request["base_branch"] == "beta"
    assert request["title"] == "Fix allocator outage"
    assert request["acceptance_criteria"] == ["Allocator claims recover."]
    assert request["allowed_file_globs"] == []
    assert request["parent_id"] == nil
    assert request["policy"].template == "hotfix"
  end

  test "rejects missing repo base branch and title" do
    assert {:error, {:missing_required_field, "repo"}} =
             CreateWork.parse_request(%{base_branch: "main", title: "Missing repo"})

    assert {:error, {:missing_required_field, "base_branch"}} =
             CreateWork.parse_request(%{repo: "kraken", title: "Missing base"})

    assert {:error, {:missing_required_field, "title"}} =
             CreateWork.parse_request(%{repo: "kraken", base_branch: "main"})
  end

  test "normalizes explicit IDs and rejects blank IDs" do
    assert {:ok, request} =
             CreateWork.parse_request(%{
               id: " custom-work-id ",
               repo: "kraken",
               base_branch: "main",
               title: "Custom id",
               acceptance_criteria: ["Custom ID works."]
             })

    assert request["id"] == "custom-work-id"

    assert {:error, :invalid_work_package_id} =
             CreateWork.parse_request(%{
               id: "   ",
               repo: "kraken",
               base_branch: "main",
               title: "Blank id"
             })
  end

  test "accepts resolved policy template names and rejects blank acceptance criteria" do
    assert {:ok, request} =
             CreateWork.parse_request(%{
               kind: "mcp",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Wire MCP package",
               acceptance_criteria: ["MCP work is created."],
               review_suite_template: "mcp",
               policy_template: "worker_package"
             })

    assert request["policy"].template == "worker_package"
    assert request["kind"] == "mcp"

    assert {:error, :invalid_acceptance_criteria} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Bad acceptance",
               acceptance_criteria: ["  "]
             })

    assert {:ok, request} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Nil acceptance",
               acceptance_criteria: nil
             })

    assert request["acceptance_criteria"] == []

    assert {:error, :missing_acceptance_criteria} =
             CreateWork.parse_request(%{
               kind: "mcp",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Missing gated acceptance"
             })
  end

  test "rejects conflicting policy template fields" do
    assert {:error, :policy_template_mismatch} =
             CreateWork.parse_request(%{
               kind: "quick_fix",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Conflicting policy templates",
               acceptance_criteria: ["Conflict is rejected."],
               policy_template: "hotfix",
               review_suite_template: "worker_package"
             })

    assert {:error, :policy_template_mismatch} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Implicit quick fix cannot request worker package",
               acceptance_criteria: ["Conflict is rejected."],
               policy_template: "worker_package"
             })
  end

  test "preserves allowed file globs and rejects invalid scope constraints", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "kraken",
               base_branch: "main",
               title: "Fix scoped hotfix",
               engineering_scope: "Touch only the balance path.",
               acceptance_criteria: ["Balance regression is fixed."],
               allowed_file_globs: [" src/[0-9]/** ", "# not a heading"]
             })

    assert creation.work_package.allowed_file_globs == ["src/[0-9]/**", "# not a heading"]
    assert creation.virtual_files["context.md"] =~ "```text\nsrc/[0-9]/**\n# not a heading\n```"

    assert {:error, :invalid_allowed_file_globs} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Bad globs",
               acceptance_criteria: ["Rejected."],
               allowed_file_globs: ["   "]
             })
  end

  test "rejects parented and phase-child work" do
    assert {:error, :parent_not_supported} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Bad parent",
               parent_id: "phase_123"
             })

    assert {:error, :standalone_kind_not_supported} =
             CreateWork.parse_request(%{
               kind: "phase_child",
               repo: "kraken",
               base_branch: "main",
               title: "Bad kind"
             })
  end

  test "creates a standalone quick fix with default policy, one grant, and initial virtual files", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               repo: "kraken",
               base_branch: "beta",
               title: "Fix flaky uploader",
               product_description: "Uploader sometimes leaves jobs in pending.",
               engineering_scope: "Make uploader completion idempotent.",
               acceptance_criteria: ["Uploader pending jobs drain.", "Focused regression coverage exists."]
             })

    assert creation.work_package.kind == "quick_fix"
    assert creation.work_package.parent_id == nil
    assert creation.work_package.status == "ready_for_worker"
    assert creation.policy.template == "quick_fix"
    assert creation.policy.review_suite.required == ["review_t1"]

    assert %{secret: secret, display_key: display_key} = creation.worker_grant
    assert is_binary(secret)
    assert String.length(display_key) == 4
    assert repo.aggregate(AccessGrant, :count) == 1

    assert creation.virtual_files["context.md"] =~ "Fix flaky uploader"
    assert creation.virtual_files["task_plan.md"] =~ "Implement requested scope"
    assert creation.virtual_files["acceptance.md"] =~ "Focused regression coverage exists."
    assert creation.virtual_files["review_suite.md"] =~ "Policy template: `quick_fix`"

    assert {:ok, rendered} = PlanningRepository.get_render_state(repo, creation.work_package.id)
    refute inspect(rendered) =~ secret

    refute Enum.any?(creation.virtual_files, fn {_name, markdown} -> String.contains?(markdown, secret) end)
  end

  test "renders investigation and blank scope plan guidance correctly", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "investigation",
               repo: "kraken",
               base_branch: "main",
               title: "Investigate queue stalls",
               engineering_scope: "   "
             })

    assert creation.policy.template == "investigation"
    assert creation.virtual_files["task_plan.md"] =~ "Use the engineering scope from context.md."
    refute creation.virtual_files["task_plan.md"] =~ "Satisfy the package acceptance criteria"
    assert creation.virtual_files["acceptance.md"] =~ "No acceptance criteria recorded."
  end

  test "creates a hotfix package that a worker can claim and read through MCP", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "kraken",
               base_branch: "main",
               title: "Fix production balance regression",
               product_description: "Available balance is overstated.",
               engineering_scope: "Exclude pending withdrawals from available balance.",
               acceptance_criteria: ["Pending withdrawals are excluded.", "Hotfix review evidence exists."],
               review_suite_template: "hotfix"
             })

    server = Server.new(Config.default(repo: repo), initialized: true)

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_work_key",
            "arguments" => %{"secret" => creation.worker_grant.secret, "claimed_by" => "worker-1"}
          }
        },
        server
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == creation.work_package.id

    plan_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        claimed_server
      )

    assert get_in(plan_response, ["result", "structuredContent", "uri"]) ==
             "sympp://work-packages/#{creation.work_package.id}/task_plan.md"

    assert get_in(plan_response, ["result", "structuredContent", "text"]) =~ "Complete acceptance and review gates"

    resource_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "acceptance",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{creation.work_package.id}/acceptance.md"}
        },
        repo: repo,
        session: claimed_server.session
      )

    text = get_in(resource_response, ["result", "contents", Access.at(0), "text"])
    assert text =~ "Pending withdrawals are excluded."
    refute text =~ creation.worker_grant.secret
  end

  test "normal work package and grant reads do not expose the raw worker secret", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               repo: "kraken",
               base_branch: "main",
               title: "Fix claim typo",
               acceptance_criteria: ["Typo fixed."]
             })

    secret = creation.worker_grant.secret

    assert {:ok, work_package} = WorkPackageRepository.get(repo, creation.work_package.id)
    assert inspect(work_package) != secret

    grant = repo.one(from(grant in AccessGrant, where: grant.work_package_id == ^creation.work_package.id))
    assert grant.secret_hash
    refute inspect(grant) =~ secret
    refute grant.secret_hash == secret
  end
end
