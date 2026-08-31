defmodule RintoPMO.Repo.Migrations.AddChatModeToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :mode, :string, null: false, default: "actor"
      add :provider, :string
      add :model, :string
      add :thinking_level, :string
    end

    alter table(:messages) do
      # The foreign key already exists; this changes only whether attribution
      # may be absent for a plain-chat assistant turn.
      modify :actor_id, :binary_id, null: true, from: {:binary_id, null: false}
      add :provider, :string
      add :model, :string
      add :thinking_level, :string
    end

    create constraint(:conversations, :conversations_assistant_configuration,
             check: """
             (mode = 'actor' AND provider IS NULL AND model IS NULL AND thinking_level IS NULL)
             OR
             (mode = 'chat' AND assistant_actor_id IS NULL AND provider IS NOT NULL AND model IS NOT NULL AND thinking_level IS NOT NULL)
             """
           )

    create constraint(:messages, :messages_user_actor_required,
             check: "role <> 'user' OR actor_id IS NOT NULL"
           )
  end
end
