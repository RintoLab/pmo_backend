{:ok, _started_apps} = Application.ensure_all_started(:ex_machina)

# Attachment blobs outlive the database sandbox, so they are cleared once here
# rather than per test: async tests share the storage root, and wiping it from
# inside one of them would delete another's bytes mid-read.
File.rm_rf!(RintoPMO.Attachments.Storage.root())

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(RintoPMO.Repo, :manual)
