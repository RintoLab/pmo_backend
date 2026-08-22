defmodule RintoPMOWeb.V1.ReferenceJSON do
  @moduledoc """
  What a `rinto://` reference points at, as much as a client needs to render it.

  One entry per URI asked about, in the order asked, repeats included -- a
  client lines these up against the occurrences in a body, and a collapsed list
  would misalign them.

  **No URLs here, deliberately.** A result names a type and identifiers; where
  those live in the client is the client's decision. Returning paths would bind
  bodies stored in the database to the web application's routing, which is the
  thing `rinto://` exists to avoid.
  """

  def resolve(%{references: references}), do: %{data: Enum.map(references, &data/1)}

  @doc """
  One resolved reference.
  """
  def data(reference) do
    %{
      uri: reference.uri,
      type: reference.type,
      state: reference.state,
      title: reference.title,
      subtitle: reference.subtitle,
      excerpt: reference.excerpt,
      document_id: reference.document_id,
      document_title: reference.document_title,
      archived: reference.archived
    }
  end
end
