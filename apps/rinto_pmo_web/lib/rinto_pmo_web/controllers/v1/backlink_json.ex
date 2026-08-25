defmodule RintoPMOWeb.V1.BacklinkJSON do
  @moduledoc """
  What points at a thing, grouped by the kind of place the text lives.

  Grouped rather than flat because a backlink panel reads as sections -- the
  documents that cite this, the tasks that cite this -- and a client that wanted
  a flat list can concatenate, while one that wanted sections out of a flat list
  has to group it back itself.

  `label` is the link text as written, which is what a reader is shown when the
  target is gone. Nothing here says whether the *source* still exists: it does,
  or the row would have been purged with it.
  """

  def index(%{backlinks: backlinks}) do
    %{
      data: %{
        total: length(backlinks),
        groups:
          backlinks
          |> Enum.group_by(& &1.source_type)
          |> Enum.map(fn {source_type, entries} ->
            %{
              source_type: source_type,
              count: length(entries),
              entries: Enum.map(entries, &data/1)
            }
          end)
          |> Enum.sort_by(& &1.source_type)
      }
    }
  end

  @doc """
  One reference, as its source describes it.
  """
  def data(backlink) do
    %{
      source_type: backlink.source_type,
      source_id: backlink.source_id,
      document_id: backlink.document_id,
      document_title: backlink.document_title,
      title: backlink.title,
      excerpt: backlink.excerpt,
      label: backlink.label,
      position: backlink.position,
      archived: backlink.archived
    }
  end
end
