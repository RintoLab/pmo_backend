defmodule RintoPMO.Repo.Migrations.AddAssistantActorToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Which AI persona this topic is a conversation *with*. A property of the
      # topic rather than of each message: it decides who the replies are
      # attributed to, and a client that could change it per prompt would be
      # able to make one topic's history look like two actors talking.
      #
      # `actor_id` remains whoever started the topic.
      add :assistant_actor_id, references(:actors, type: :binary_id), null: true
    end

    create index(:conversations, [:assistant_actor_id])
  end
end
