defmodule RintoPMO.Requirements.EstimationContext do
  @moduledoc false
  import Ecto.Query

  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Repo
  alias RintoPMO.Requirements.Tree
  alias RintoPMO.Tasks.Task

  def load(requirement, tree) do
    ancestors = Tree.ancestry(tree, requirement.id)
    ids = Enum.map(ancestors, & &1.id)

    documents =
      Repo.all(
        from document in Document,
          join: revision in DocumentRevision,
          on: revision.document_id == document.id and revision.is_latest,
          where:
            document.requirement_id in ^ids and is_nil(document.archived_at) and
              document.kind in [:spec, :plan, :task],
          order_by: document.id,
          select: {document, revision}
      )

    # Refuse oversized context rather than silently estimating from incomplete specifications.
    context = %{
      requirements: Enum.map(ancestors, &Map.take(&1, [:id, :title, :description])),
      documents:
        Enum.map(documents, fn {document, revision} ->
          revision = Repo.preload(revision, :blocks)

          %{
            id: document.id,
            requirement_id: document.requirement_id,
            kind: document.kind,
            status: document.status,
            title: revision.title,
            content: Enum.map_join(revision.blocks, "\n\n", & &1.content)
          }
        end)
    }

    fingerprint =
      {Enum.map(ancestors, &{&1.id, &1.updated_at}),
       Enum.map(documents, fn {doc, rev} -> {doc.id, doc.status, rev.id} end)}

    if byte_size(Jason.encode!(context)) > 200_000,
      do:
        {:error, "requirement context exceeds 200 KB; narrow the requirement before estimating"},
      else: {:ok, context, fingerprint}
  end

  def history(project_id) do
    Repo.all(
      from task in Task,
        where:
          task.project_id == ^project_id and task.kind == :work and task.status == :done and
            not is_nil(task.actual_minutes),
        order_by: [desc: task.completed_at],
        limit: 50
    )
    |> Enum.map(fn task ->
      %{
        title: task.title,
        difficulty: task.difficulty,
        actual_minutes: task.actual_minutes,
        estimate:
          if(is_nil(task.estimate_optimistic),
            do: nil,
            else: %{
              optimistic: task.estimate_optimistic,
              likely: task.estimate_likely,
              pessimistic: task.estimate_pessimistic,
              expected: Task.expected(task)
            }
          )
      }
    end)
  end
end
