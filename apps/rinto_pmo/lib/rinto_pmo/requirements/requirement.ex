defmodule RintoPMO.Requirements.Requirement do
  @moduledoc """
  A requirement belongs to a Project (the business system). Repository scope
  will be derived from tasks. Workflow transitions are not writable metadata;
  this first step allows editing drafts and archiving without changing status.
  """
  use RintoPMO, :schema

  alias RintoPMO.Projects.Project

  @type t :: %__MODULE__{}

  schema "requirements" do
    field :title, :string
    field :description, :string, default: ""
    field :status, Ecto.Enum, values: [:draft, :active, :completed, :cancelled], default: :draft
    field :archived_at, :utc_datetime_usec
    belongs_to :project, Project
    timestamps()
  end

  @doc false
  def changeset(requirement, attrs) do
    requirement
    |> cast(attrs, [:title, :description], empty_values: [])
    |> update_change(:title, &trim_title/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_description()
    |> reject_managed_fields(attrs)
    |> foreign_key_constraint(:project_id)
  end

  defp trim_title(title) when is_binary(title), do: String.trim(title)
  defp trim_title(title), do: title

  defp validate_description(changeset) do
    if is_nil(get_field(changeset, :description)) do
      add_error(changeset, :description, "cannot be null")
    else
      changeset
    end
  end

  defp reject_managed_fields(changeset, attrs) do
    Enum.reduce([:project_id, :status, :archived_at], changeset, fn field, changeset ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
        add_error(changeset, field, "is managed by the system")
      else
        changeset
      end
    end)
  end
end
