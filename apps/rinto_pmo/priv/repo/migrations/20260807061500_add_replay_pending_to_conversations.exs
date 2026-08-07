defmodule RintoPMO.Repo.Migrations.AddReplayPendingToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Set when a topic is given a fresh pi process, cleared by the first
      # prompt that goes to it. pi runs with `--no-session`, so that process
      # starts empty and the first prompt has to carry the recent turns back.
      #
      # A column rather than process state because the fact belongs to the
      # topic, not to whichever channel happens to send that prompt -- and
      # because it has to survive everything between the two, including a
      # deploy.
      add :replay_pending, :boolean, null: false, default: false
    end
  end
end
