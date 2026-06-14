import Config

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "work_key", "work_key_secret", "grant_secret", "secret", "operator_bootstrap"]
config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
