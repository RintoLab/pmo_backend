defmodule RintoPMO.ContentIndexTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents
  alias RintoPMO.Projects.Project
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Task

  # Stands in for the worker that will compute these.
  defp embed!(schema, id) do
    schema
    |> where([row], row.id == ^id)
    |> Repo.update_all(set: [embedding: Pgvector.new(List.duplicate(0.1, 1024))])

    Repo.get!(schema, id)
  end

  defp document_with(markdown, opts \\ []) do
    actor = insert(:actor)
    project = Keyword.get_lazy(opts, :project, fn -> insert(:project) end)

    {:ok, document} =
      Documents.create_document(%{
        title: Keyword.get(opts, :title, "上线流程"),
        actor_id: actor.id,
        project_id: project.id,
        markdown: markdown
      })

    document
  end

  # Everything else keeps its vector on its own row, voided by the changeset
  # that rewrites the text it stood for.
  describe "resources that carry their own vector" do
    test "a task loses it on a text change and keeps it otherwise" do
      {:ok, task} = Tasks.create_task(insert(:project), %{title: "甲", description: "原来的说明"})
      embed!(Task, task.id)

      {:ok, task} = Tasks.update_task(task, %{due_on: ~D[2026-12-31]})
      assert Repo.get!(Task, task.id).embedding, "a due date change voided the vector"

      {:ok, task} = Tasks.update_task(task, %{description: "改过的说明"})
      refute Repo.get!(Task, task.id).embedding
    end

    test "a project loses it when its name changes" do
      project = insert(:project)
      embed!(Project, project.id)

      project
      |> Project.changeset(%{name: "改名了"})
      |> Repo.update!()

      refute Repo.get!(Project, project.id).embedding
    end

    # Embedded separately rather than as one thread: a reply arriving must not
    # re-embed everything above it, or a long thread re-embeds itself over and
    # over across text that keeps growing.
    test "an annotation and its replies each carry their own" do
      document = document_with("## 一\n\n内容")
      actor = insert(:actor)

      {:ok, annotation} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "问题"})

      {:ok, reply} = Annotations.create_reply(annotation, %{actor_id: actor.id, content: "回答"})

      embed!(Annotation, annotation.id)
      embed!(AnnotationReply, reply.id)

      {:ok, _second} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "再补一句"})

      assert Repo.get!(Annotation, annotation.id).embedding,
             "a new reply re-embedded the whole thread"

      {:ok, _updated} = Annotations.update_reply(reply, %{content: "改过的回答"})

      refute Repo.get!(AnnotationReply, reply.id).embedding
      assert Repo.get!(Annotation, annotation.id).embedding
    end
  end
end
