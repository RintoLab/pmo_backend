defmodule RintoPMOWeb.V1.DocumentJSON do
  alias RintoPMO.Documents.Document
  alias RintoPMOWeb.V1.DocumentRevisionJSON

  def index(%{documents: documents}) do
    %{data: Enum.map(documents, &summary/1)}
  end

  def show(%{document: document}) do
    %{data: data(document)}
  end

  def preview_blocks(%{contents: contents}) do
    blocks =
      contents
      |> Enum.with_index()
      |> Enum.map(fn {content, position} -> %{position: position, content: content} end)

    %{data: %{blocks: blocks}}
  end

  defp summary(%Document{} = document) do
    %{
      id: document.id,
      project_id: document.project_id,
      archived_at: document.archived_at,
      status: document.status,
      latest_revision: DocumentRevisionJSON.summary(document.latest_revision),
      inserted_at: document.inserted_at,
      updated_at: document.updated_at
    }
  end

  defp data(%Document{} = document) do
    document
    |> summary()
    |> Map.put(:latest_revision, DocumentRevisionJSON.data(document.latest_revision))
  end
end
