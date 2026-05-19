defmodule SymphonyElixirWeb.ReactDashboardController do
  @moduledoc """
  Bridges human-facing UI routes to the Vite-served React dashboard.
  """

  use Phoenix.Controller, formats: [:html]

  alias Plug.Conn
  alias SymphonyElixirWeb.SymppDashboardApiController

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    conn
    |> maybe_put_local_operator_session()
    |> serve_dashboard_shell()
  end

  defp maybe_put_local_operator_session(conn) do
    if SymppDashboardApiController.local_operator_browser?(conn) do
      SymppDashboardApiController.put_local_operator_session(conn)
    else
      conn
    end
  end

  defp serve_dashboard_shell(conn) do
    case dashboard_origin() do
      {:ok, origin} -> redirect(conn, external: dashboard_url(conn, origin))
      :error -> serve_built_dashboard_shell(conn)
    end
  end

  defp serve_built_dashboard_shell(conn) do
    case File.read(index_path()) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)

      {:error, _reason} ->
        conn
        |> put_status(503)
        |> html("""
        <!doctype html>
        <html lang="en">
          <head><meta charset="utf-8"><title>Symphony++ Dashboard</title></head>
          <body><main id="root">Dashboard assets have not been built yet.</main></body>
        </html>
        """)
    end
  end

  defp index_path do
    :symphony_elixir
    |> :code.priv_dir()
    |> Path.join("static/index.html")
  end

  defp dashboard_origin do
    :symphony_elixir
    |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
    |> Keyword.get(:sympp_dashboard_origin)
    |> normalize_dashboard_origin()
  end

  defp normalize_dashboard_origin(origin) when is_binary(origin) do
    case String.trim(origin) do
      "" -> :error
      value -> {:ok, String.trim_trailing(value, "/")}
    end
  end

  defp normalize_dashboard_origin(_origin), do: :error

  defp dashboard_url(conn, origin) do
    query = if conn.query_string == "", do: "", else: "?#{conn.query_string}"
    "#{origin}#{conn.request_path}#{query}"
  end
end
