defmodule RintoPMO.Agent.RequirementPrioritizerBehaviour do
  @moduledoc false
  @callback prioritize(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
end
