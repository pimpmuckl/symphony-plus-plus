defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormatFixtures do
  @moduledoc false

  def work_package_context_payload do
    %{
      "acceptance" => [
        %{"done" => false, "source" => "Serializer supports TOON rows"},
        %{"done" => false, "source" => "Tests cover S++ fixtures"}
      ],
      "allowed_file_globs" => [
        "elixir/lib/symphony_elixir/symphony_plus_plus/agent_format/**",
        "elixir/test/symphony_elixir/symphony_plus_plus/agent_format/**"
      ],
      "base_branch" => "main",
      "branch" => "feat/sympp-toon-agent-format",
      "required_gates" => ["package_acceptance", "focused_tests", "review_normal"],
      "status" => "ready_for_worker",
      "work_package_id" => "wp_ROiof_-E5ZQP9J0TKdwVIQ"
    }
  end

  def mcp_context_payload do
    %{
      "resources" => [
        "sympp://assignment/current",
        "sympp://work-packages/wp_ROiof_-E5ZQP9J0TKdwVIQ/context.md"
      ],
      "tools" => [
        %{"name" => "get_current_assignment", "surface" => "worker"},
        %{"name" => "read_context", "surface" => "worker"},
        %{"name" => "append_progress", "surface" => "worker"}
      ],
      "transport" => %{
        "mode" => "http",
        "session_scope" => "claimed_worker"
      }
    }
  end

  def non_uniform_progress_payload do
    %{
      "progress" => [
        %{"status" => "prepared", "summary" => "Prepared WorkPackage worktree"},
        %{
          "details" => %{"review" => "pending", "suite" => "normal"},
          "status" => "in_progress",
          "summary" => "Review Suite pending"
        }
      ]
    }
  end
end
