defmodule SymphonyElixir.SymphonyPlusPlus.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3
end
