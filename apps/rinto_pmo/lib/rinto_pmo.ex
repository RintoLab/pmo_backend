defmodule RintoPMO do
  @moduledoc """
  The entrypoint for defining domain contexts and schemas.

  Use it in application modules as:

      use RintoPMO, :context
      use RintoPMO, :schema

  Keep the shared definitions focused on imports, aliases, and schema defaults.
  """

  def context do
    quote do
      import Ecto.Query

      alias RintoPMO.Repo
    end
  end

  def schema do
    quote do
      use Ecto.Schema

      import Ecto.Changeset

      @primary_key {:id, UUIDv7, autogenerate: true}
      @foreign_key_type UUIDv7
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end

  @doc """
  Dispatches to the requested domain definition.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
