defmodule SymphonyElixir.MCPHarness do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server, Session}

  @spec request(term(), keyword()) :: map() | [map()] | nil
  def request(payload, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> Config.default(repo: Keyword.fetch!(opts, :repo)) end)
    session = Keyword.get(opts, :session)
    payload = normalize_payload(payload)
    initialized = Keyword.get_lazy(opts, :initialized, fn -> initialized_default(payload) end)

    Server.handle(payload, Server.new(config, session: session, initialized: initialized))
  end

  @spec session(term(), keyword()) :: Session.t()
  def session(assignment, opts \\ []), do: Session.new(assignment, opts)

  defp normalize_payload(payload) when is_map(payload) or is_list(payload), do: payload

  defp initialized_default(%{"method" => "initialize"}), do: false
  defp initialized_default(_payload), do: true
end
