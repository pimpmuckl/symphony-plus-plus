defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Stdio do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server}

  @spec run(Config.t(), keyword()) :: :ok
  def run(%Config{} = config, opts \\ []) do
    server = Server.new(config, opts)

    _server =
      IO.stream(:stdio, :line)
      |> Enum.reduce(server, &handle_line/2)

    :ok
  end

  defp handle_line(line, %Server{} = server) do
    {response, server} = line_response_state(line, server)
    emit_response(response)
    server
  end

  @doc false
  @spec line_response(String.t(), Server.t()) :: map() | [map()] | nil
  def line_response(line, %Server{} = server) do
    line
    |> line_response_state(server)
    |> elem(0)
  end

  @doc false
  @spec line_response_state(String.t(), Server.t()) :: {map() | [map()] | nil, Server.t()}
  def line_response_state(line, %Server{} = server) do
    line =
      line
      |> String.trim_trailing("\n")
      |> String.trim_trailing("\r")

    if line == "" do
      {nil, server}
    else
      case Jason.decode(line) do
        {:ok, payload} -> Server.handle_response_state(payload, server)
        {:error, _reason} -> {parse_error(), server}
      end
    end
  end

  @doc false
  @spec handle_payload(term(), Server.t()) :: map() | [map()] | nil
  def handle_payload(payload, %Server{} = server), do: Server.handle(payload, server)

  defp emit_response(nil), do: :ok
  defp emit_response([]), do: :ok

  defp emit_response(response) do
    IO.write(Jason.encode!(response))
    IO.write("\n")
  end

  defp parse_error do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_700, "message" => "Parse error", "data" => %{}}
    }
  end
end
