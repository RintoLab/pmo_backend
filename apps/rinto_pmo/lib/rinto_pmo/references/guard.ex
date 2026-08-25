defmodule RintoPMO.References.Guard do
  @moduledoc """
  Refuses a body whose `rinto://` references point at nothing.

  ## Why this is worth a refusal rather than a warning

  Addresses are bare UUIDs. Nobody types one correctly from memory, and the
  agent skills say so -- but a body with a mistyped address **saves without
  complaint** and renders as a dead link nobody notices until a reader follows
  it. The failure is silent, which is the argument for making it loud at the
  only moment somebody can still fix it.

  There is no legitimate reading of a dangling address here, unlike a wiki
  where linking to an unwritten page is how pages get started: an address comes
  from search or from the call that created the thing, so one that resolves to
  nothing is a typo every time.

  ## Where it does not apply

  **Messages.** A chat message is a person or a model thinking out loud, and
  refusing to send one over a mistyped link would be the wrong trade -- the
  conversation matters more than the index. Its references are still extracted;
  the broken one simply does not become a link.
  """

  alias RintoPMO.References.Resolver

  @doc """
  Returns `:ok`, or the refusal shape `RintoPMOWeb.FallbackController` renders.
  """
  @spec check(String.t() | nil) :: :ok | {:error, :unresolvable_references, map()}
  def check(text) do
    case Resolver.validate(text) do
      :ok -> :ok
      {:error, uris} -> {:error, :unresolvable_references, %{uris: uris}}
    end
  end

  @doc """
  Checks several bodies at once, answering every bad address across all of them.

  A revision carries one body per block it touches, and a caller told about the
  first bad address would fix it and be refused again for the second.
  """
  @spec check_all([String.t() | nil]) :: :ok | {:error, :unresolvable_references, map()}
  def check_all(texts) when is_list(texts) do
    texts
    |> Enum.flat_map(fn text ->
      case Resolver.validate(text) do
        :ok -> []
        {:error, uris} -> uris
      end
    end)
    |> Enum.uniq()
    |> case do
      [] -> :ok
      uris -> {:error, :unresolvable_references, %{uris: uris}}
    end
  end
end
