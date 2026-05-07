defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign_prefixed_paths()

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <meta name="live-socket-path" content={@live_socket_path} />
        <script defer src={@phoenix_html_path}></script>
        <script defer src={@phoenix_path}></script>
        <script defer src={@phoenix_live_view_path}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");
            var liveSocketPath = document
              .querySelector("meta[name='live-socket-path']")
              ?.getAttribute("content") || "/live";

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket(liveSocketPath, window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_path} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  defp assign_prefixed_paths(assigns) do
    prefix = path_prefix(assigns)

    assigns
    |> assign(:dashboard_css_path, prefixed_path(prefix, "/dashboard.css"))
    |> assign(:phoenix_html_path, prefixed_path(prefix, "/vendor/phoenix_html/phoenix_html.js"))
    |> assign(:phoenix_path, prefixed_path(prefix, "/vendor/phoenix/phoenix.js"))
    |> assign(:phoenix_live_view_path, prefixed_path(prefix, "/vendor/phoenix_live_view/phoenix_live_view.js"))
    |> assign(:live_socket_path, prefixed_path(prefix, "/live"))
  end

  defp path_prefix(%{conn: %Plug.Conn{script_name: script_name}}) when is_list(script_name) do
    case Enum.reject(script_name, &(&1 == "")) do
      [] -> ""
      parts -> "/" <> Enum.join(parts, "/")
    end
  end

  defp path_prefix(_assigns), do: ""

  defp prefixed_path("", path), do: path
  defp prefixed_path(prefix, path), do: prefix <> path

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
