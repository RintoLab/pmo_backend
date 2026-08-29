defmodule RintoPMO.Repo.Migrations.ARepositoryHoldsNoBranch do
  use Ecto.Migration

  # Which branch to read is a question the conversation asks, not one the
  # registration answers. A column here could only hold a guess made months
  # earlier by somebody who was not in that conversation.
  #
  # Nothing is lost by dropping it: a mirror holds every ref, so the branch was
  # never what made a repository available -- only what a checkout asked the
  # mirror for. See `RintoPMO.Workspace`.
  def change do
    alter table(:project_repos) do
      remove :branch, :string, null: false
    end
  end
end
