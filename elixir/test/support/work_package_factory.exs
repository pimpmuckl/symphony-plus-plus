defmodule SymphonyElixir.WorkPackageFactory do
  @moduledoc false

  @spec attrs(keyword()) :: map()
  def attrs(overrides \\ []) do
    defaults = %{
      kind: "standard_pr",
      title: "Implement package",
      repo: "nextide/example",
      base_branch: "main",
      branch_pattern: "agent/example",
      product_description: "Product context",
      engineering_scope: "Engineering scope",
      acceptance_criteria: ["Create and fetch package"],
      parent_id: nil,
      owner_id: "agent-1"
    }

    Enum.into(overrides, defaults)
  end

  @spec database_path() :: Path.t()
  def database_path do
    Path.join(System.tmp_dir!(), "sympp-work-packages-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
