defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.Client do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest

  @callback fetch_pull_request(PullRequest.ref(), keyword()) :: {:ok, map()} | {:error, term()}

  @spec fetch_pull_request(module(), PullRequest.ref(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_pull_request(client, ref, opts \\ []) when is_atom(client) and is_map(ref) do
    client.fetch_pull_request(ref, opts)
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.DryClient do
  @moduledoc false

  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  @impl true
  def fetch_pull_request(_ref, opts) do
    case Keyword.get(opts, :metadata) do
      metadata when is_map(metadata) -> {:ok, metadata}
      _metadata -> {:error, :metadata_required}
    end
  end
end
