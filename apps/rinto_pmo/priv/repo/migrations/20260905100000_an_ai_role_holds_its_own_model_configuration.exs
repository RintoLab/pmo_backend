defmodule RintoPMO.Repo.Migrations.AnAIRoleHoldsItsOwnModelConfiguration do
  @moduledoc """
  The two automatic jobs configure a model directly, instead of borrowing one
  from an actor.

  `system_settings` was a pointer: `key` named a job, `actor_id` said which
  persona did it, and the model configuration came along for the ride because
  an actor happens to carry one. That indirection bought something real while
  there were five roles and a list of personas to choose between. It costs
  more than it buys now:

    * an actor is a **participant** -- somebody who signs writing and holds a
      conversation. Naming a topic and estimating a task are neither. What
      those two need is a provider, a model, a thinking level and a standing
      instruction, and every other thing an actor is was noise on the way
    * choosing a persona chose four settings at once, so tuning the thinking
      level for naming meant either editing an actor that other things also
      used, or making a near-duplicate actor nobody talks to
    * the strictness lived in the wrong place. `put_actor/2` had to refuse
      humans, disabled actors and the stand-in -- three rules that only existed
      because the column pointed at a table full of rows that were not model
      configurations

  So the configuration moves onto the row that uses it. `key` still names the
  job; the other four columns are the answer.

  ## What carries over

  Whatever the two roles were pointing at, copied out of the actor. A
  deployment that had chosen a persona for naming keeps calling the same model
  with the same instruction, and nobody has to re-pick anything after the
  deploy. Rows pointing at an actor that had no model configuration -- the
  stand-in, or a human somebody forced in past the validation -- are not
  carried: there is nothing to copy, and a row of nulls would be a role that
  looks configured and cannot run.

  The three roles that are not carried -- `decomposition_actor`,
  `annotation_actor`, `review_actor` -- are gone along with the pipelines that
  read them. Their work happens in a conversation now, under a prompt shortcut.
  See `docs/implementation-plan-prompt-shortcuts.md`.

  ## The keys are renamed

  `title_actor` becomes `topic_naming` and `estimation_actor` becomes
  `task_estimation`. The `_actor` suffix was the whole claim this change
  withdraws, and a key that still said it would be the last place in the system
  insisting the answer is a persona.
  """

  use Ecto.Migration

  def up do
    create table(:ai_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The job, named by the system. There is no check constraint, for the
      # reason `system_settings` gave and which still holds: the jobs live in
      # `RintoPMO.AIRoles` because adding one is a code change either way, and
      # a constraint would make it a migration as well.
      add :key, :string, null: false

      # Required together, and only as a set: a role with a provider and no
      # model is a call that cannot be made. Enforced by the changeset rather
      # than by `null: false`, so that the three arrive as one validation
      # failure on the request that sent them instead of as a constraint error.
      add :provider, :string, null: true
      add :model, :string, null: true
      add :thinking_level, :string, null: true

      # Standing instructions, prepended to the contract the job's own prompt
      # sets out. Null and empty both mean "nothing to add" -- see
      # `RintoPMO.Agent.TitleGenerator`.
      add :system_prompt, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ai_roles, [:key])

    # One row per role, or none. An absent row is an unconfigured role, which
    # is a state both readers already handle: naming falls back to the topic's
    # own model, estimation refuses.
    execute """
    INSERT INTO ai_roles (id, key, provider, model, thinking_level, system_prompt,
                          inserted_at, updated_at)
    SELECT gen_random_uuid(),
           CASE setting.key
             WHEN 'title_actor' THEN 'topic_naming'
             WHEN 'estimation_actor' THEN 'task_estimation'
           END,
           actor.provider,
           actor.model,
           actor.thinking_level,
           actor.system_prompt,
           NOW(),
           NOW()
      FROM system_settings AS setting
      JOIN actors AS actor ON actor.id = setting.actor_id
     WHERE setting.key IN ('title_actor', 'estimation_actor')
       AND actor.provider IS NOT NULL
       AND actor.model IS NOT NULL
       AND actor.thinking_level IS NOT NULL
    """

    drop table(:system_settings)
  end

  def down do
    create table(:system_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :actor_id, references(:actors, type: :binary_id, on_delete: :nilify_all), null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:system_settings, [:key])
    create index(:system_settings, [:actor_id])

    # Nothing is written back. A configuration cannot be turned into a pointer:
    # there is no actor to point at, and inventing one to hold four columns
    # would leave a persona behind that nobody made.
    drop table(:ai_roles)
  end
end
