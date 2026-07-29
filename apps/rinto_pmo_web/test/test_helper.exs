{:ok, _started_apps} = Application.ensure_all_started(:ex_machina)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(RintoPMO.Repo, :manual)
