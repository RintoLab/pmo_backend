defmodule RintoPMO.AIRoles.AIRole do
  @moduledoc """
  How one automatic job calls a model.

  `key` names the job -- `RintoPMO.AIRoles` lists the jobs that exist -- and the
  rest of the row is the answer: which provider, which model, how hard to think,
  and what standing instruction to put in front of the job's own prompt.

  ## Why the model configuration is here and not on an actor

  It used to be borrowed: the row held an `actor_id` and the job read the
  chosen persona's `provider`, `model` and `thinking_level` off it. That made
  configuring a job mean picking a participant, and the two are not the same
  question. An actor signs writing and holds conversations; naming a topic does
  neither. See the migration
  `20260905100000_an_ai_role_holds_its_own_model_configuration.exs` for the
  whole of the argument.

  ## The three model fields are one field

  `provider`, `model` and `thinking_level` are required together. A row with a
  provider and no model is not a partly-configured role, it is a call nobody
  can make -- and the caller would find that out a minute later, in a job,
  rather than on the request that wrote it.

  They are validated here rather than pinned by `null: false`, so that a client
  sending one of the three is told about all three at once.

  ## `system_prompt` is the one optional part

  Standing instructions, and genuinely optional: each job ships a prompt that
  owns its output contract -- what shape to answer in, what not to invent --
  and this is prepended to steer what it pays attention to, not to replace it.
  A role with none is the ordinary case.

  ## What is deliberately absent

  No `enabled`. A role that should stop running is deleted, which is also how
  it is emptied -- and an emptied role already has a meaning at both readers
  (`RintoPMO.AIRoles`). A flag would be a third state saying the same thing as
  the second.

  No `name` or `description`. The job is named by `key` and described by the
  client that renders it; a label stored here would be a second name for
  something the system already knows, in whichever language whoever typed it
  happened to use.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  schema "ai_roles" do
    field :key, :string

    field :provider, :string
    field :model, :string
    field :thinking_level, :string
    field :system_prompt, :string

    timestamps()
  end

  @doc """
  A role as a caller writes one.

  `key` is cast, but a caller does not choose it: it comes from the URL, and
  `RintoPMO.AIRoles.put_role/2` has already refused anything that is not a job
  this system has.
  """
  def changeset(%__MODULE__{} = role \\ %__MODULE__{}, attrs) do
    role
    |> cast(attrs, [:key, :provider, :model, :thinking_level, :system_prompt])
    |> validate_required([:key, :provider, :model, :thinking_level])
    |> unique_constraint(:key)
  end
end
