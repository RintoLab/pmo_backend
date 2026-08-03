{:ok, _started_apps} = Application.ensure_all_started(:ex_machina)

# See the note in the rinto_pmo suite: cleared once, never from inside a test.
File.rm_rf!(RintoPMO.Attachments.Storage.root())

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(RintoPMO.Repo, :manual)
