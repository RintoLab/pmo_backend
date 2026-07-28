defmodule RintoPMO.Repo do
  use Ecto.Repo,
    otp_app: :rinto_pmo,
    adapter: Ecto.Adapters.Postgres
end
