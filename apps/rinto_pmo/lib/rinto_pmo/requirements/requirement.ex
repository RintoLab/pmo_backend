defmodule RintoPMO.Requirements.Requirement do
  @moduledoc """
  A requirement belongs to a Project (the business system). Repository scope
  is derived from tasks. Status is a reversible progress marker, not an execution gate.
  """
  use RintoPMO, :schema

  alias RintoPMO.Projects.Project

  @type t :: %__MODULE__{}

  schema "requirements" do
    field :title, :string
    field :description, :string, default: ""
    field :priority, :integer, default: 3

    field :status, Ecto.Enum,
      values: [:draft, :analyzed, :active, :completed, :cancelled],
      default: :draft

    field :archived_at, :utc_datetime_usec
    belongs_to :project, Project
    belongs_to :parent, __MODULE__
    field :child_count, :integer, virtual: true, default: 0
    field :workload, :map, virtual: true
    timestamps()
  end

  @doc false
  def changeset(requirement, attrs) do
    requirement
    |> metadata_changeset(attrs)
    |> cast(attrs, [:status], empty_values: [])
    |> validate_required([:status])
    |> validate_inclusion(:status, [:draft, :analyzed, :active, :completed])
    |> reject_fields(attrs, [:parent_id])
  end

  @doc false
  def creation_changeset(requirement, attrs) do
    requirement
    |> metadata_changeset(attrs)
    |> reject_fields(attrs, [:status])
  end

  defp metadata_changeset(requirement, attrs) do
    requirement
    |> cast(attrs, [:title, :description, :priority], empty_values: [])
    |> update_change(:title, &trim_title/1)
    |> validate_required([:title, :priority])
    |> validate_inclusion(:priority, 1..5)
    |> check_constraint(:priority, name: :requirements_priority_check)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_description()
    |> reject_fields(attrs, [:project_id, :archived_at])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:parent_id)
    |> check_constraint(:parent_id, name: :requirements_parent_not_self)
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

  defp reject_fields(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
        add_error(changeset, field, "is managed by the system")
      else
        changeset
      end
    end)
  end
end
