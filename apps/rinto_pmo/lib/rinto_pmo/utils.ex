defmodule RintoPMO.Utils do
  @moduledoc """
  Shared helpers, including the module injection seam used to replace external
  implementations with Hammox mocks in tests.
  """

  @injectors Application.compile_env!(:rinto_pmo, :injectors)

  @doc """
  Resolves the implementation module registered under `name`.
  """
  @spec module(atom()) :: module()
  def module(name), do: Keyword.fetch!(@injectors, name)
end
