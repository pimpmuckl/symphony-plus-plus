defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @skill_path Path.join(@repo_root, ".codex/skills/symphony-work-package/SKILL.md")
  @prompt_path Path.join(@repo_root, ".codex/skills/symphony-work-package/references/worker_prompt.md")
  @wiring_path Path.join(@repo_root, ".codex/skills/symphony-work-package/references/mcp_wiring.md")
  @template_skill_path Path.join(@repo_root, "implementation_docs_symphplusplus/templates/SKILL.md")
  @template_prompt_path Path.join(@repo_root, "implementation_docs_symphplusplus/templates/worker_agent_prompt.md")
  @contract_path Path.join(@repo_root, "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json")

  @worker_tools [
    "claim_work_key",
    "get_current_assignment",
    "read_context",
    "read_task_plan",
    "update_task_plan",
    "append_finding",
    "append_progress",
    "set_status",
    "report_blocker",
    "resolve_blocker",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "submit_review_package",
    "mark_ready"
  ]

  test "skill package has required metadata and worker MCP workflow" do
    skill = File.read!(@skill_path)

    assert skill =~ "name: symphony-work-package"
    assert skill =~ "description:"

    for tool <- @worker_tools do
      assert skill =~ tool
    end

    assert skill =~ "sympp://work-packages/{id}/acceptance.md"
    assert skill =~ "Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as"
    assert skill =~ "Worker grants are scoped to exactly one WorkPackage."
    assert skill =~ "`state_key` preserves initialized MCP handshake continuity only."
    refute skill =~ "request_context"
  end

  test "worker prompt is paste-ready and MCP-backed" do
    prompt = File.read!(@prompt_path)
    template_prompt = File.read!(@template_prompt_path)

    for content <- [prompt, template_prompt] do
      assert content =~ "```text"
      assert content =~ "<WORK_PACKAGE_ID>"
      assert content =~ "claim_work_key(secret, claimed_by)"
      assert content =~ "update_task_plan(patch, expected_version)"
      assert content =~ "resolve_blocker(blocker_id, resolution, summary, idempotency_key)"
      assert content =~ "request_scope_expansion(summary, idempotency_key, payload)"
      assert content =~ "attach_pr(url, head_sha)"
      assert content =~ "Do not create local planning files as the WorkPackage source of truth."
      assert content =~ "Do not use broad Linear/GitHub state as permission authority."
      refute content =~ "attach_pr(pr_url"
      refute content =~ "request_context"
    end
  end

  test "MCP wiring docs explain the stdio dependency without embedding secrets" do
    wiring = File.read!(@wiring_path)

    assert wiring =~ "mise exec -- mix sympp.mcp --mode stdio"
    assert wiring =~ "[mcp_servers.symphony_plus_plus]"
    assert wiring =~ "claim_work_key(secret, claimed_by)"
    assert wiring =~ "should not embed raw work-key secrets or bearer tokens"
    refute wiring =~ "sympp_live_"
  end

  test "template skill mirrors installable skill metadata" do
    skill = File.read!(@skill_path)
    template_skill = File.read!(@template_skill_path)

    assert frontmatter(skill) == frontmatter(template_skill)
  end

  test "MCP contract lists the current worker tools" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    actual_tools = Enum.map(contract["worker_tools"], & &1["name"])

    assert actual_tools == @worker_tools
    refute "request_context" in actual_tools
  end

  defp frontmatter(content) do
    [_, metadata | _rest] = String.split(content, "---", parts: 3)
    String.trim(metadata)
  end
end
