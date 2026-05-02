defmodule SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @active_statuses ["running", "retrying"]
  @terminal_statuses ["completed", "failed", "stopped"]
  @statuses @active_statuses ++ @terminal_statuses

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_package_id: String.t() | nil,
          access_grant_id: String.t() | nil,
          actor_id: String.t() | nil,
          status: String.t() | nil,
          attempt: non_neg_integer() | nil,
          worker_host: String.t() | nil,
          workspace_path: String.t() | nil,
          session_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          reason: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_agent_runs" do
    field(:work_package_id, :string)
    field(:access_grant_id, :string)
    field(:actor_id, :string)
    field(:status, :string)
    field(:attempt, :integer, default: 0)
    field(:worker_host, :string)
    field(:workspace_path, :string)
    field(:session_id, :string)
    field(:started_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:reason, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    now = DateTime.utc_now(:microsecond)

    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("status", "running")
      |> put_new_value("attempt", 0)
      |> put_new_value("started_at", now)
      |> put_new_value("last_seen_at", now)

    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :work_package_id,
      :access_grant_id,
      :actor_id,
      :status,
      :attempt,
      :worker_host,
      :workspace_path,
      :session_id,
      :started_at,
      :last_seen_at,
      :finished_at,
      :reason
    ])
    |> validate_required([:id, :work_package_id, :status, :attempt, :started_at, :last_seen_at])
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:id, name: :sympp_agent_runs_id_unique_index)
    |> unique_constraint(:work_package_id, name: :sympp_agent_runs_one_active_per_work_package_index)
    |> foreign_key_constraint(:work_package_id)
    |> foreign_key_constraint(:access_grant_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = agent_run, attrs) do
    agent_run
    |> cast(normalize_keys(attrs), [
      :access_grant_id,
      :actor_id,
      :status,
      :worker_host,
      :workspace_path,
      :session_id,
      :last_seen_at,
      :finished_at,
      :reason
    ])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:access_grant_id)
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
    "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
