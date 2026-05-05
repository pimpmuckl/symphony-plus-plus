defmodule SymphonyElixir.SymphonyPlusPlus.Policies.Templates do
  @moduledoc false

  @templates %{
    "quick_fix" => %{
      template: "quick_fix",
      constraints: %{
        expiry_seconds: 86_400,
        planning_depth: "brief",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["focused_tests", "review_t1"],
      readiness_requirements: ["implementation_complete", "tests_passed", "review_t1_green"],
      review_suite: %{required: ["review_t1"], optional: ["review_t2"]}
    },
    "hotfix" => %{
      template: "hotfix",
      constraints: %{
        expiry_seconds: 21_600,
        planning_depth: "incident",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["focused_tests", "review_t1", "review_t2", "human_merge"],
      readiness_requirements: ["implementation_complete", "tests_passed", "review_t1_green", "review_t2_green"],
      review_suite: %{required: ["review_t1", "review_t2"], optional: ["review_github"]}
    },
    "adapter" => %{
      template: "adapter",
      constraints: %{
        expiry_seconds: 86_400,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_t1", "review_t2", "human_merge"],
      readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_t1_green", "review_t2_green"],
      review_suite: %{required: ["review_t1", "review_t2"], optional: ["review_github"]}
    },
    "mcp" => %{
      template: "worker_package",
      constraints: %{
        expiry_seconds: 86_400,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_t1", "review_t2", "human_merge"],
      readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_t1_green", "review_t2_green"],
      review_suite: %{required: ["review_t1", "review_t2"], optional: ["review_github"]}
    },
    "mcp_current_pr_state" => %{
      work_package_kind: "mcp",
      template: "worker_package",
      constraints: %{
        expiry_seconds: 86_400,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_t1", "review_t2", "human_merge", "current_pr_state"],
      readiness_requirements: [
        "acceptance_criteria_met",
        "tests_passed",
        "review_t1_green",
        "review_t2_green",
        "current_pr_state"
      ],
      review_suite: %{required: ["review_t1", "review_t2"], optional: ["review_github"]}
    },
    "skill" => %{
      template: "worker_package",
      constraints: %{
        expiry_seconds: 86_400,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_t1", "review_t2", "human_merge"],
      readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_t1_green", "review_t2_green"],
      review_suite: %{required: ["review_t1", "review_t2"], optional: ["review_github"]}
    },
    "hooks" => %{
      template: "worker_package",
      constraints: %{
        expiry_seconds: 86_400,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_t1", "review_t2", "human_merge"],
      readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_t1_green", "review_t2_green"],
      review_suite: %{required: ["review_t1", "review_t2"], optional: ["review_github"]}
    },
    "phase_child" => %{
      template: "phase_child",
      constraints: %{
        expiry_seconds: 172_800,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_architect_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_t1", "review_t2", "architect_merge"],
      readiness_requirements: [
        "acceptance_criteria_met",
        "tests_passed",
        "review_t1_green",
        "review_t2_green",
        "architect_ready"
      ],
      review_suite: %{required: ["review_t1", "review_t2"], optional: ["review_github"]}
    },
    "investigation" => %{
      template: "investigation",
      constraints: %{
        expiry_seconds: 43_200,
        planning_depth: "findings",
        terminal_readiness_status: "ready_for_human_merge"
      },
      required_gates: ["findings_documented", "recommendation_artifact_recorded"],
      readiness_requirements: ["findings_complete", "recommendation_artifact_recorded"],
      review_suite: %{required: [], optional: ["review_t1"]}
    }
  }

  @type template :: %{
          template: String.t(),
          constraints: %{
            expiry_seconds: pos_integer(),
            planning_depth: String.t(),
            terminal_readiness_status: String.t()
          },
          required_gates: [String.t()],
          readiness_requirements: [String.t()],
          review_suite: %{required: [String.t()], optional: [String.t()]}
        }

  @spec expand(String.t()) :: {:ok, template()} | {:error, :unknown_policy_template}
  def expand(kind) when is_binary(kind) do
    case Map.fetch(@templates, kind) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, :unknown_policy_template}
    end
  end

  @spec resolve_key([String.t()]) ::
          {:ok, String.t(), template()} | {:error, :policy_template_mismatch | :unknown_policy_template}
  def resolve_key(templates) when is_list(templates) do
    matches =
      @templates
      |> Enum.filter(fn {key, template} ->
        Enum.all?(templates, fn requested -> requested in [key, template.template] end)
      end)

    case matches do
      [{key, template}] -> {:ok, key, template}
      [] -> unknown_or_mismatch(templates)
      _matches -> {:error, :policy_template_mismatch}
    end
  end

  defp unknown_or_mismatch(templates) do
    known? =
      Enum.all?(templates, fn requested ->
        Enum.any?(@templates, fn {key, template} -> requested in [key, template.template] end)
      end)

    if known?, do: {:error, :policy_template_mismatch}, else: {:error, :unknown_policy_template}
  end

  @spec key?(String.t()) :: boolean()
  def key?(key) when is_binary(key), do: Map.has_key?(@templates, key)

  @spec compatible_kind?(String.t(), String.t()) :: boolean()
  def compatible_kind?(kind, policy_key) when is_binary(kind) and is_binary(policy_key) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> Map.get(template, :work_package_kind, policy_key) == kind
      :error -> false
    end
  end

  def compatible_kind?(_kind, _policy_key), do: false

  @spec work_package_kind(String.t()) :: {:ok, String.t()} | {:error, :unknown_policy_template}
  def work_package_kind(policy_key) when is_binary(policy_key) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> {:ok, Map.get(template, :work_package_kind, policy_key)}
      :error -> {:error, :unknown_policy_template}
    end
  end

  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(policy_key, requested) when is_binary(policy_key) and is_binary(requested) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> requested in [policy_key, template.template, Map.get(template, :work_package_kind)]
      :error -> false
    end
  end
end
