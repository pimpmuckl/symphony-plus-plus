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

defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.HttpClient do
  @moduledoc false

  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  @default_receive_timeout 5_000

  @spec authenticated?() :: boolean()
  def authenticated?, do: is_binary(github_token())

  @impl true
  def fetch_pull_request(%{owner: owner, repo: repo, number: number}, opts)
      when is_binary(owner) and is_binary(repo) and is_integer(number) do
    url = "https://api.github.com/repos/#{URI.encode_www_form(owner)}/#{URI.encode_www_form(repo)}/pulls/#{number}"

    url
    |> Req.get(headers: headers(), receive_timeout: receive_timeout(opts))
    |> handle_pull_request_response()
  end

  def fetch_pull_request(_ref, _opts), do: {:error, :invalid_pr_reference}

  defp handle_pull_request_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    if is_map(body), do: {:ok, body}, else: {:error, :invalid_github_response}
  end

  defp handle_pull_request_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  defp handle_pull_request_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp handle_pull_request_response({:ok, %Req.Response{status: 403}}), do: {:error, :forbidden}

  defp handle_pull_request_response({:ok, %Req.Response{status: status}}) when is_integer(status) do
    {:error, {:github_status, status}}
  end

  defp handle_pull_request_response({:error, _reason}), do: {:error, :request_failed}

  defp headers do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "symphony-plus-plus"},
      {"x-github-api-version", "2022-11-28"}
    ]
    |> maybe_put_authorization_header()
  end

  defp maybe_put_authorization_header(headers) do
    case github_token() do
      token when is_binary(token) -> [{"authorization", "Bearer #{token}"} | headers]
      nil -> headers
    end
  end

  defp github_token do
    (System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN"))
    |> case do
      token when is_binary(token) ->
        token = String.trim(token)
        if token == "", do: nil, else: token

      _token ->
        nil
    end
  end

  defp receive_timeout(opts) do
    case Keyword.get(opts, :receive_timeout, @default_receive_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> @default_receive_timeout
    end
  end
end
