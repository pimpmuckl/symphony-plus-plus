defmodule SymphonyElixir.SymphonyPlusPlus.ScopeGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  test "glob matching supports recursive globs and character classes" do
    assert ScopeGuard.glob_match?("elixir/lib/**", "elixir/lib/symphony_elixir/example.ex")
    assert ScopeGuard.glob_match?("src/[0-9]/**", "src/7/generated/file.ex")
    assert ScopeGuard.glob_match?("docs/*.md", "docs/plan.md")
    assert ScopeGuard.glob_match?("docs/**/*.md", "docs/plan.md")
    assert ScopeGuard.glob_match?("docs/**/*.md", "docs/nested/plan.md")

    refute ScopeGuard.glob_match?("docs/*.md", "docs/nested/plan.md")
    refute ScopeGuard.glob_match?("src/[0-9]/**", "src/a/generated/file.ex")
  end

  test "wrong base branch fails scope guard" do
    package = package(["elixir/lib/**"])

    reasons =
      package
      |> ScopeGuard.failure_reasons(events(base_branch: "main", changed_files: ["elixir/lib/example.ex"]))
      |> Map.new(&{&1["code"], &1})

    assert reasons["wrong_base_branch"]["expected_base_branch"] == "symphony-plus-plus/beta"
    assert reasons["wrong_base_branch"]["actual_base_branch"] == "main"
  end

  test "repo-qualified package base branch matches plain GitHub base ref" do
    package = package(["elixir/lib/**"])

    assert ScopeGuard.failure_reasons(package, events(base_branch: "beta", changed_files: ["elixir/lib/example.ex"])) == []
  end

  test "out-of-scope changed file fails scope guard" do
    package = package(["elixir/lib/**"])

    reasons =
      package
      |> ScopeGuard.failure_reasons(events(changed_files: ["elixir/lib/example.ex", "docs/outside.md"]))
      |> Map.new(&{&1["code"], &1})

    assert reasons["out_of_scope_files"]["files"] == ["docs/outside.md"]
    assert reasons["out_of_scope_files"]["allowed_file_globs"] == ["elixir/lib/**"]
  end

  test "approved expansion preserves existing globs and permits new files" do
    package = package(["elixir/lib/**"])
    changed_files = events(changed_files: ["elixir/lib/example.ex", "docs/inside.md"])

    assert [%{"code" => "out_of_scope_files"}] = ScopeGuard.failure_reasons(package, changed_files)
    assert {:ok, effective_globs} = ScopeGuard.approve_file_globs(package, ["docs/**"])

    expanded_package = %{package | allowed_file_globs: effective_globs}

    assert effective_globs == ["elixir/lib/**", "docs/**"]
    assert ScopeGuard.failure_reasons(expanded_package, changed_files) == []
  end

  test "approved expansion rejects repo-wide catch-all globs" do
    package = package(["elixir/lib/**"])

    assert {:error, "overbroad_allowed_file_globs"} = ScopeGuard.approve_file_globs(package, ["**"])
    assert {:error, "overbroad_allowed_file_globs"} = ScopeGuard.approve_file_globs(package, ["./**/*"])
  end

  test "overbroad configured package globs fail scope guard" do
    package = package(["**"])

    reasons =
      package
      |> ScopeGuard.failure_reasons(events(changed_files: ["docs/outside.md"]))
      |> Map.new(&{&1["code"], &1})

    assert reasons["overbroad_scope_constraints"]["allowed_file_globs"] == ["**"]
  end

  test "zero changed-file count satisfies scope guard when paths are unavailable" do
    package = package(["elixir/lib/**"])

    events = events(changed_files: [], changed_files_available: false, changed_files_count_available: true)

    assert ScopeGuard.failure_reasons(package, events) == []
  end

  test "nonzero changed-file count without paths fails scope guard" do
    package = package(["elixir/lib/**"])

    opts = [
      changed_files: [],
      changed_files_available: false,
      changed_files_count_available: true,
      changed_files_count: 2
    ]

    events = events(opts)

    reasons =
      package
      |> ScopeGuard.failure_reasons(events)
      |> Map.new(&{&1["code"], &1})

    assert reasons["changed_files_unavailable"]["changed_files_count"] == 2
  end

  test "missing changed-file path and count evidence fails scope guard" do
    package = package(["elixir/lib/**"])
    opts = [changed_files: [], changed_files_available: false, changed_files_count_available: false]

    reasons =
      package
      |> ScopeGuard.failure_reasons(events(opts))
      |> Map.new(&{&1["code"], &1})

    assert reasons["changed_files_unavailable"]["gate"] == "scope_guard"
  end

  defp package(allowed_file_globs) do
    %WorkPackage{
      id: "SYMPP-SCOPE-UNIT",
      kind: "mcp",
      title: "Scope guard unit",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta",
      allowed_file_globs: allowed_file_globs,
      policy_template: "mcp_changed_file_scope_guard",
      acceptance_criteria: ["Scope is enforced."],
      status: "ci_waiting"
    }
  end

  defp events(opts) do
    base_branch = Keyword.get(opts, :base_branch, "symphony-plus-plus/beta")
    changed_files = Keyword.fetch!(opts, :changed_files)
    changed_files_count = Keyword.get(opts, :changed_files_count, length(changed_files))
    changed_files_available = Keyword.get(opts, :changed_files_available, true)
    changed_files_count_available = Keyword.get(opts, :changed_files_count_available, true)

    [
      event(1, %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => "head-a"}),
      event(2, %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/7", "head_sha" => "head-a"}),
      event(3, %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7",
        "head_sha" => "head-a",
        "base_branch" => base_branch,
        "changed_files" => Enum.map(changed_files, &%{"path" => &1}),
        "changed_files_count" => changed_files_count,
        "changed_files_available" => changed_files_available,
        "changed_files_count_available" => changed_files_count_available
      })
    ]
  end

  defp event(sequence, payload) do
    %ProgressEvent{
      id: "event-#{sequence}",
      work_package_id: "SYMPP-SCOPE-UNIT",
      summary: "event #{sequence}",
      status: "recorded",
      sequence: sequence,
      payload: payload,
      created_at: DateTime.add(~U[2026-05-06 00:00:00Z], sequence, :second)
    }
  end
end
