defmodule RintoPMOWeb.V1.AnnotationJSON do
  alias RintoPMO.Annotations.Annotation
  alias RintoPMOWeb.V1.AnnotationReplyJSON

  def index(%{annotations: annotations}) do
    %{data: Enum.map(annotations, &summary/1)}
  end

  def show(%{annotation: annotation}) do
    %{data: data(annotation)}
  end

  defp summary(%Annotation{} = annotation) do
    %{
      id: annotation.id,
      document_id: annotation.document_id,
      actor_id: annotation.actor_id,
      block_id: annotation.block_id,
      block_text: annotation.block_text,
      selected_text: annotation.selected_text,
      content: annotation.content,
      status: annotation.status,
      resolved_by_revision_id: annotation.resolved_by_revision_id,
      inserted_at: annotation.inserted_at,
      updated_at: annotation.updated_at
    }
  end

  defp data(%Annotation{} = annotation) do
    annotation
    |> summary()
    |> Map.put(:replies, replies(annotation))
  end

  defp replies(%Annotation{replies: replies}) when is_list(replies) do
    Enum.map(replies, &AnnotationReplyJSON.data/1)
  end

  defp replies(%Annotation{}), do: []
end
