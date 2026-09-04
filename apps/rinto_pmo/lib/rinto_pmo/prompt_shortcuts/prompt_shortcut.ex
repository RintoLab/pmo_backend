defmodule RintoPMO.PromptShortcuts.PromptShortcut do
  @moduledoc """
  One quick prompt offered beside the composer.

  ## Why it is a row and not code

  The set grows, and the wording of a prompt is tuned by reading what came
  back. Both of those are edits somebody makes while looking at the result,
  which is the same argument `RintoPMO.Settings` makes for roles: put it in
  the source and every adjustment is a deploy.

  ## `key` is not `id`

  `id` addresses the row; `key` survives the row being rewritten by a
  deployment. `RintoPMO.PromptShortcuts.Presets` has to find what it wrote last
  time, and a UUID regenerated on every run would turn its upsert into an
  insert.

  It is a random string rather than a readable slug, deliberately. Nothing
  should branch on it -- the whole point of moving these out of the client is
  that the client stops knowing which shortcuts exist -- and `k7f3q2x9m4`
  invites `if (key === ...)` far less than `review-document` does. It is
  generated here, never accepted from a caller.

  ## `default_prompt` answers two questions with one column

  What the seeding task last wrote. `prompt == default_prompt` means nobody has
  edited this row, and that single comparison carries the whole of the
  edited/unedited distinction -- there is no `modified` flag, and a client
  works it out from the two values it already has.

  It is also what makes re-seeding safe. A deployment always overwrites
  `default_prompt`, but overwrites `prompt` only where the two were equal, so
  an untouched row follows the new default while an edited one keeps its edit
  and gets the new default as what "reset" will hand it.

  `null` marks a row created through the API: there is no default to return to,
  and `RintoPMO.PromptShortcuts.reset_shortcut/1` refuses it.

  ## What is deliberately absent

  No `position` -- ordering is the client's, off the order it receives. No
  `enabled` -- a table this size is edited by deleting. No `locale` -- whoever
  writes the row picks its language. Each of these is a column that would exist
  to serve a decision nobody has had to make yet.

  `label` and `icon` belong to whoever set them: a deployment writes them once,
  when it creates the row, and never again. `icon` is a name from the client's
  own asset set and is not validated here, for the reason
  `RintoPMO.References` gives about routing -- naming somebody else's
  namespace means changing the database when they rename something.
  """

  use RintoPMO, :schema

  alias RintoPMO.References

  @type t :: %__MODULE__{}

  schema "prompt_shortcuts" do
    field :key, :string
    field :resource_type, :string
    field :label, :string
    field :icon, :string
    field :prompt, :string
    field :default_prompt, :string

    timestamps()
  end

  @doc """
  A shortcut as a caller may write one.

  `key` and `default_prompt` are not cast: the first is this module's to
  generate, the second is the seeding task's to write. A client sending either
  is ignored rather than refused, the way an unknown field is.
  """
  def changeset(%__MODULE__{} = shortcut \\ %__MODULE__{}, attrs) do
    shortcut
    |> cast(attrs, [:resource_type, :label, :icon, :prompt])
    |> validate_required([:label, :prompt])
    |> validate_resource_type()
    |> put_key()
    |> unique_constraint(:key)
  end

  @doc """
  A preset as the seeding task writes one, including the fields a caller may
  not set.

  Only for `RintoPMO.PromptShortcuts.Presets`. The re-seeding rule -- which
  fields are written again and which are written once -- lives there, because
  it is a rule about deployments rather than about a row.
  """
  def preset_changeset(%__MODULE__{} = shortcut, attrs) do
    shortcut
    |> cast(attrs, [:key, :resource_type, :label, :icon, :prompt, :default_prompt])
    |> validate_required([:key, :label, :prompt, :default_prompt])
    |> validate_resource_type()
    |> unique_constraint(:key)
  end

  @doc """
  A fresh random key.

  Base32 without padding: sixteen lowercase alphanumerics, no separators, and
  nothing that needs escaping in a URL or a shell.
  """
  @spec generate_key() :: String.t()
  def generate_key do
    10 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end

  # Validated even though `RintoPMO.References` lets an unknown type parse.
  # That leniency is about text somebody wrote years ago and must still render;
  # this is a person filling in a form, and a typo here produces a button that
  # silently never appears. Refusing it is the kinder answer.
  defp validate_resource_type(chset) do
    validate_inclusion(chset, :resource_type, Map.keys(References.types()))
  end

  defp put_key(chset) do
    case get_field(chset, :key) do
      nil -> put_change(chset, :key, generate_key())
      _already_has_one -> chset
    end
  end
end
