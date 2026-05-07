defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Config do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @enforce_keys [:mode, :repo, :version]
  defstruct [:mode, :repo, :version, :database, :work_key_secret_env, :claimed_by]

  @type t :: %__MODULE__{
          mode: :stdio,
          repo: module(),
          version: String.t(),
          database: String.t() | nil,
          work_key_secret_env: String.t() | nil,
          claimed_by: String.t() | nil
        }

  @switches [database: :string, mode: :string, work_key_secret_env: :string, claimed_by: :string, help: :boolean]

  @spec default(keyword()) :: t()
  def default(opts \\ []) do
    %__MODULE__{
      mode: Keyword.get(opts, :mode, :stdio),
      repo: Keyword.get(opts, :repo, Repo),
      version: Keyword.get(opts, :version, application_version()),
      database: Keyword.get(opts, :database),
      work_key_secret_env: Keyword.get(opts, :work_key_secret_env),
      claimed_by: Keyword.get(opts, :claimed_by)
    }
  end

  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()} | :help
  def parse(args) when is_list(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          :help
        else
          parse_options(opts)
        end

      {_opts, _argv, _invalid} ->
        {:error, usage()}
    end
  end

  @spec usage() :: String.t()
  def usage do
    "Usage: mix sympp.mcp [--mode stdio] [--database <sqlite-path>] [--work-key-secret-env <env-var>] [--claimed-by <worker-id>]"
  end

  defp parse_options(opts) do
    with {:ok, mode} <- parse_mode(Keyword.get(opts, :mode, "stdio")),
         {:ok, work_key_secret_env} <- optional_nonblank(opts, :work_key_secret_env),
         {:ok, claimed_by} <- optional_nonblank(opts, :claimed_by),
         :ok <- require_claimed_by_for_secret_env(work_key_secret_env, claimed_by) do
      {:ok,
       default(
         mode: mode,
         database: Keyword.get(opts, :database),
         work_key_secret_env: work_key_secret_env,
         claimed_by: claimed_by
       )}
    end
  end

  defp parse_mode("stdio"), do: {:ok, :stdio}
  defp parse_mode(_mode), do: {:error, "Only STDIO MCP mode is supported for SYMPP-P3-001.\n#{usage()}"}

  defp optional_nonblank(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, usage()}, else: {:ok, value}

      {:ok, _value} ->
        {:error, usage()}

      :error ->
        {:ok, nil}
    end
  end

  defp require_claimed_by_for_secret_env(nil, _claimed_by), do: :ok
  defp require_claimed_by_for_secret_env(_env, claimed_by) when is_binary(claimed_by), do: :ok
  defp require_claimed_by_for_secret_env(_env, nil), do: {:error, usage()}

  defp application_version do
    case Application.spec(:symphony_elixir, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _missing -> "0.1.0"
    end
  end
end
