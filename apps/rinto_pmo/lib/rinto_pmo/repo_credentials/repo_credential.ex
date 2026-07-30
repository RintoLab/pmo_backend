defmodule RintoPMO.RepoCredentials.RepoCredential do
  @moduledoc """
  Reusable credentials for read-only Git operations over HTTPS.

  The token is write-only at the API boundary and excluded from inspected
  structs so it is not accidentally exposed in logs.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  schema "repo_credentials" do
    field :name, :string
    field :username, :string
    field :token, :string, redact: true

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = credential \\ %__MODULE__{}, attrs) do
    credential
    |> cast(attrs, [:name, :username, :token])
    |> validate_required([:name, :username, :token])
  end
end
