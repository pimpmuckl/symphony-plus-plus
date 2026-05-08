defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Stdio do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server}

  @spec run(Config.t(), keyword()) :: :ok
  def run(%Config{} = config, opts \\ []) do
    server = Server.new(config, opts)
    read_loop(server)
  end

  defp read_loop(%Server{} = server) do
    case read_line() do
      :eof ->
        :ok

      {:error, reason} ->
        raise IO.StreamError, reason: reason

      line when is_binary(line) ->
        line
        |> handle_line(server)
        |> read_loop()
    end
  end

  defp read_line do
    if string_io_group_leader?(), do: IO.read(:stdio, :line), else: IO.binread(:stdio, :line)
  end

  defp string_io_group_leader? do
    case Process.info(:erlang.group_leader(), :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$initial_call") == {StringIO, :init, 1}
      _info -> false
    end
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
  def handle_payload(payload, %Server{} = server) do
    payload
    |> Server.handle_response_state(server)
    |> elem(0)
  end

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
