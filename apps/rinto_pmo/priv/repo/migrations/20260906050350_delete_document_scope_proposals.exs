defmodule RintoPMO.Repo.Migrations.DeleteDocumentScopeProposals do
  use Ecto.Migration

  def up do
    execute("DELETE FROM block_proposals WHERE scope = 'document'")
  end

  # Deleted proposal history cannot be reconstructed during a rollback.
  def down, do: :ok
end
