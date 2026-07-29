defmodule RintoPMO.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: RintoPMO.Repo

  alias RintoPMO.Actors.Actor

  def actor_factory do
    %Actor{
      kind: :human,
      name: sequence(:actor_name, &"Actor #{&1}")
    }
  end
end
