defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @kinds [
    "quick_fix",
    "hotfix",
    "standard_pr",
    "phase_child",
    "investigation",
    "review_only",
    "setup",
    "core",
    "adapter",
    "mcp",
    "skill",
    "hooks",
    "product",
    "dashboard",
    "integration",
    "security",
    "delegation",
    "hardening",
    "pilot",
    "docs",
    "e2e",
    "analysis"
  ]

  @statuses [
    "created",
    "ready_for_worker",
    "claimed",
    "planning",
    "implementing",
    "reviewing",
    "ci_waiting",
    "ready_for_human_merge",
    "ready_for_architect_merge",
    "merging_into_phase",
    "merged_into_phase",
    "merged",
    "closed",
    "blocked",
    "abandoned"
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: String.t() | nil,
          title: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          branch_pattern: String.t() | nil,
          product_description: String.t() | nil,
          engineering_scope: String.t() | nil,
          acceptance_criteria: [String.t()],
          status: String.t() | nil,
          parent_id: String.t() | nil,
          owner_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_packages" do
    field(:kind, :string)
    field(:title, :string)
    field(:repo, :string)
    field(:base_branch, :string)
    field(:branch_pattern, :string)
    field(:product_description, :string)
    field(:engineering_scope, :string)
    field(:acceptance_criteria, StringList, default: [])
    field(:status, :string)
    field(:parent_id, :string)
    field(:owner_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("status", "created")

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_work_packages_id_unique_index)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = work_package, attrs) do
    work_package
    |> changeset(Map.drop(normalize_keys(attrs), ["id", "inserted_at", "updated_at", "created_at"]))
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = work_package, attrs) do
    work_package
    |> cast(normalize_keys(attrs), [
      :id,
      :kind,
      :title,
      :repo,
      :base_branch,
      :branch_pattern,
      :product_description,
      :engineering_scope,
      :acceptance_criteria,
      :status,
      :parent_id,
      :owner_id
    ])
    |> validate_required([:id, :kind, :title, :repo, :base_branch, :acceptance_criteria, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp stable_id do
    "wp_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
