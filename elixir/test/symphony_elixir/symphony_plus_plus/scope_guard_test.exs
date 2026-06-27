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

  test "origin repo-qualified package base branch matches plain GitHub base ref" do
    package = %{package(["elixir/lib/**"]) | base_branch: "origin/symphony-plus-plus/beta"}

    assert ScopeGuard.failure_reasons(package, events(base_branch: "beta", changed_files: ["elixir/lib/example.ex"])) == []
    assert ScopeGuard.failure_reasons(package, events(base_branch: "symphony-plus-plus/beta", changed_files: ["elixir/lib/example.ex"])) == []
  end

  test "mismatched repo-qualified package base branch does not match plain GitHub base ref" do
    package = %{package(["elixir/lib/**"]) | base_branch: "origin/other-repo/beta"}

    reasons =
      package
      |> ScopeGuard.failure_reasons(events(base_branch: "beta", changed_files: ["elixir/lib/example.ex"]))
      |> Map.new(&{&1["code"], &1})

    assert reasons["wrong_base_branch"]["expected_base_branch"] == "origin/other-repo/beta"
    assert reasons["wrong_base_branch"]["actual_base_branch"] == "beta"
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
    assert {:error, "overbroad_allowed_file_globs"} = ScopeGuard.approve_file_globs(package, ["**/**"])
  end

  test "approved expansion repairs overbroad existing package globs" do
    package = package(["elixir/lib/**", "**"])

    assert {:ok, ["elixir/lib/**", "docs/**"]} = ScopeGuard.approve_file_globs(package, ["docs/**"])
  end

  test "overbroad configured package globs fail scope guard" do
    package = package(["**"])

    reasons =
      package
      |> ScopeGuard.failure_reasons(events(changed_files: ["docs/outside.md"]))
      |> Map.new(&{&1["code"], &1})

    assert reasons["overbroad_scope_constraints"]["allowed_file_globs"] == ["**"]
  end

  test "renamed files evaluate both previous and current paths" do
    package = package(["elixir/lib/**"])

    reasons =
      package
      |> ScopeGuard.failure_reasons(events(changed_files: [%{"path" => "elixir/lib/new.ex", "previous_path" => "docs/old.md"}]))
      |> Map.new(&{&1["code"], &1})

    assert reasons["out_of_scope_files"]["files"] == ["docs/old.md"]
  end

  test "zero changed-file count fails scope guard when paths are unavailable" do
    package = package(["elixir/lib/**"])

    events = events(changed_files: [], changed_files_available: false, changed_files_count_available: true)

    reasons =
      package
      |> ScopeGuard.failure_reasons(events)
      |> Map.new(&{&1["code"], &1})

    assert reasons["changed_files_unavailable"]["gate"] == "scope_guard"
  end

  test "empty changed-file path evidence satisfies scope guard when paths are explicitly available" do
    package = package(["elixir/lib/**"])

    events = events(changed_files: [], changed_files_available: true, changed_files_count_available: true)

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

  test "current head follows ledger sequence when DateTime term ordering would select stale branch" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}
    stale_created_at = ~U[2026-04-30 23:59:59Z]
    final_created_at = ~U[2026-05-01 00:00:00Z]
    stale_head = "e268481"
    final_head = "c4c2a71d312439ac41acf89e1907a8ca8fc6d6cf"

    assert Enum.sort_by([stale_created_at, final_created_at], & &1) == [final_created_at, stale_created_at]
    assert DateTime.compare(stale_created_at, final_created_at) == :lt

    events = [
      event(
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-V2-WR-002", "head_sha" => stale_head},
        stale_created_at
      ),
      event(
        2,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-V2-WR-002", "head_sha" => final_head},
        final_created_at
      ),
      event(
        3,
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/64", "head_sha" => final_head},
        DateTime.add(final_created_at, 1, :second)
      ),
      event(
        4,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "url" => "https://github.com/nextide/symphony-plus-plus/pull/64",
          "head_sha" => final_head,
          "base_branch" => "main",
          "changed_files" => [%{"path" => "elixir/lib/symphony_elixir/symphony_plus_plus/readiness/scope_guard.ex"}],
          "changed_files_count" => 1,
          "changed_files_available" => true,
          "changed_files_count_available" => true
        },
        DateTime.add(final_created_at, 2, :second)
      )
    ]

    assert ScopeGuard.failure_reasons(package, events) == []
  end

  test "sequenced events remain authoritative when mixed with unsequenced events" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}
    stale_head = "head-old"
    final_head = "head-final"

    events = [
      event(
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => final_head},
        ~U[2026-05-01 00:00:00Z]
      ),
      event(
        2,
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/7", "head_sha" => final_head},
        ~U[2026-05-01 00:00:01Z]
      ),
      event(
        3,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "url" => "https://github.com/nextide/symphony-plus-plus/pull/7",
          "head_sha" => final_head,
          "base_branch" => "main",
          "changed_files" => [%{"path" => "elixir/lib/example.ex"}],
          "changed_files_count" => 1,
          "changed_files_available" => true,
          "changed_files_count_available" => true
        },
        ~U[2026-05-01 00:00:02Z]
      ),
      unsequenced_event(
        "event-stale-branch",
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => stale_head},
        ~U[2026-05-01 00:00:03Z]
      )
    ]

    assert ScopeGuard.failure_reasons(package, events) == []
  end

  test "scope guard keeps the current attached PR when older PR evidence is backfilled later" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}

    events = [
      event(
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:00Z]
      ),
      event(
        2,
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/17", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:02Z]
      ),
      event(
        3,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "url" => "https://github.com/nextide/symphony-plus-plus/pull/17",
          "head_sha" => "head-a",
          "base_branch" => "main",
          "changed_files" => [%{"path" => "elixir/lib/example.ex"}],
          "changed_files_count" => 1,
          "changed_files_available" => true,
          "changed_files_count_available" => true
        },
        ~U[2026-05-01 00:00:03Z]
      ),
      event(
        4,
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/17", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:01Z]
      )
    ]

    assert ScopeGuard.failure_reasons(package, events) == []
  end

  test "scope guard accepts repaired PR attachment evidence" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}

    events = [
      event(
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:00Z]
      ),
      event(
        2,
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/16", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:01Z]
      ),
      event(
        3,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "attachment_repair" => true,
          "url" => "https://github.com/nextide/symphony-plus-plus/pull/17",
          "head_sha" => "head-a",
          "base_branch" => "main",
          "changed_files" => [%{"path" => "elixir/lib/example.ex"}],
          "changed_files_count" => 1,
          "changed_files_available" => true,
          "changed_files_count_available" => true
        },
        ~U[2026-05-01 00:00:02Z]
      )
    ]

    assert ScopeGuard.failure_reasons(package, events) == []
  end

  test "scope guard ignores sequenced PR sync metadata before a sequence-less reattach" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}

    events = [
      event(
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:00Z]
      ),
      event(
        2,
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/17", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:01Z]
      ),
      event(
        3,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "url" => "https://github.com/nextide/symphony-plus-plus/pull/17",
          "head_sha" => "head-a",
          "base_branch" => "main",
          "changed_files" => [%{"path" => "elixir/lib/example.ex"}],
          "changed_files_count" => 1,
          "changed_files_available" => true,
          "changed_files_count_available" => true
        },
        ~U[2026-05-01 00:00:02Z]
      ),
      unsequenced_event(
        "sequence-less-reattach",
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/17", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:03Z]
      )
    ]

    reasons =
      package
      |> ScopeGuard.failure_reasons(events)
      |> Map.new(&{&1["code"], &1})

    assert reasons["missing_base_branch"]["expected_base_branch"] == "main"
    assert reasons["changed_files_unavailable"]["gate"] == "scope_guard"
  end

  test "fully unsequenced event streams use normalized timestamp ordering" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}
    stale_created_at = ~U[2026-04-30 23:59:59Z]
    final_created_at = ~U[2026-05-01 00:00:00Z]
    stale_head = "head-old"
    final_head = "head-final"

    assert Enum.sort_by([stale_created_at, final_created_at], & &1) == [final_created_at, stale_created_at]

    events = [
      unsequenced_event(
        "event-stale-branch",
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => stale_head},
        stale_created_at
      ),
      unsequenced_event(
        "event-final-branch",
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => final_head},
        final_created_at
      ),
      unsequenced_event(
        "event-final-pr",
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/7", "head_sha" => final_head},
        DateTime.add(final_created_at, 1, :second)
      ),
      unsequenced_event(
        "event-final-sync",
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "url" => "https://github.com/nextide/symphony-plus-plus/pull/7",
          "head_sha" => final_head,
          "base_branch" => "main",
          "changed_files" => [%{"path" => "elixir/lib/example.ex"}],
          "changed_files_count" => 1,
          "changed_files_available" => true,
          "changed_files_count_available" => true
        },
        DateTime.add(final_created_at, 2, :second)
      )
    ]

    assert ScopeGuard.failure_reasons(package, events) == []
  end

  test "count-only sync does not reuse changed-file paths from a different base snapshot" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}

    events = [
      event(1, %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => "head-a"}),
      event(2, %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/7", "head_sha" => "head-a"}),
      event(3, %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7",
        "head_sha" => "head-a",
        "base_branch" => "main",
        "base_sha" => "base-a",
        "changed_files" => [%{"path" => "elixir/lib/example.ex"}],
        "changed_files_count" => 1,
        "changed_files_available" => true,
        "changed_files_count_available" => true
      }),
      event(4, %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7",
        "head_sha" => "head-a",
        "base_branch" => "main",
        "base_sha" => "base-b",
        "changed_files" => [],
        "changed_files_count" => 1,
        "changed_files_available" => false,
        "changed_files_count_available" => true
      })
    ]

    reasons =
      package
      |> ScopeGuard.failure_reasons(events)
      |> Map.new(&{&1["code"], &1})

    assert reasons["changed_files_unavailable"]["changed_files_count"] == 1
  end

  test "count-only sync does not reuse changed-file paths from a different head snapshot" do
    package = %{package(["elixir/lib/**"]) | base_branch: "main"}

    events = [
      event(1, %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/SYMPP-SCOPE-UNIT", "head_sha" => "abcdef1"}),
      event(2, %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/7", "head_sha" => "abcdef1"}),
      event(3, %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7",
        "head_sha" => "abcdef1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "base_branch" => "main",
        "base_sha" => "base-a",
        "changed_files" => [%{"path" => "elixir/lib/example.ex"}],
        "changed_files_count" => 1,
        "changed_files_available" => true,
        "changed_files_count_available" => true
      }),
      event(4, %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7",
        "head_sha" => "abcdef1bbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "base_branch" => "main",
        "base_sha" => "base-a",
        "changed_files" => [],
        "changed_files_count" => 1,
        "changed_files_available" => false,
        "changed_files_count_available" => true
      })
    ]

    reasons =
      package
      |> ScopeGuard.failure_reasons(events)
      |> Map.new(&{&1["code"], &1})

    assert reasons["changed_files_unavailable"]["changed_files_count"] == 1
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
        "changed_files" => Enum.map(changed_files, &changed_file_payload/1),
        "changed_files_count" => changed_files_count,
        "changed_files_available" => changed_files_available,
        "changed_files_count_available" => changed_files_count_available
      })
    ]
  end

  defp changed_file_payload(path) when is_binary(path), do: %{"path" => path}
  defp changed_file_payload(%{} = file), do: file
  defp changed_file_payload(value), do: value

  defp event(sequence, payload, created_at \\ nil) do
    %ProgressEvent{
      id: "event-#{sequence}",
      work_package_id: "SYMPP-SCOPE-UNIT",
      summary: "event #{sequence}",
      status: "recorded",
      sequence: sequence,
      payload: payload,
      created_at: created_at || DateTime.add(~U[2026-05-06 00:00:00Z], sequence, :second)
    }
  end

  defp unsequenced_event(id, payload, created_at) do
    %ProgressEvent{
      id: id,
      work_package_id: "SYMPP-SCOPE-UNIT",
      summary: id,
      status: "recorded",
      sequence: nil,
      payload: payload,
      created_at: created_at
    }
  end
end
