defmodule RintoPMO.ContentIndexRebuildTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.ContentIndex
  alias RintoPMO.Conversations
  alias RintoPMO.Documents
  alias RintoPMO.Links.Link
  alias RintoPMO.Tasks

  defp uri(type, key), do: "rinto://#{type}/#{key}"

  # Compared as a set of tuples rather than as rows: ids and timestamps are
  # regenerated on every rebuild, and none of that is the thing being checked.
  defp fingerprint do
    Link
    |> Repo.all()
    |> Enum.map(
      &{&1.source_type, &1.source_id, &1.source_document_id, &1.target_type, &1.target_id,
       &1.target_slug, &1.target_document_id, &1.label, &1.position}
    )
    |> Enum.sort()
  end

  # Everything that can carry a reference, written through the live paths, so
  # that what rebuild produces is compared against what the write side did
  # rather than against a second copy of rebuild's own logic.
  defp populate do
    actor = insert(:actor)
    project = insert(:project, slug: "infra")
    target = insert(:task)

    {:ok, document} =
      Documents.create_document(%{
        title: "上线流程",
        actor_id: actor.id,
        project_id: project.id,
        markdown: """
        ## 一

        先做 [接入](#{uri("task", target.id)})

        ## 二

        归 [基础设施](#{uri("project", "infra")}) 管，另见 [同一件事](#{uri("task", target.id)})
        """
      })

    {:ok, annotation} =
      Annotations.create_annotation(document, %{
        actor_id: actor.id,
        content: "这里要提 [那个任务](#{uri("task", target.id)})"
      })

    {:ok, _reply} =
      Annotations.create_reply(annotation, %{
        actor_id: actor.id,
        content: "同意，另见 [那篇](#{uri("document", document.id)})"
      })

    {:ok, _task} =
      Tasks.create_task(project, %{
        title: "甲",
        description: "依赖 [那个](#{uri("task", target.id)})"
      })

    {:ok, _message} =
      Conversations.append_message(insert(:conversation), %{
        actor_id: actor.id,
        role: :user,
        content: "看看 [这个](#{uri("task", target.id)})"
      })

    document
  end

  # The claim the whole design leans on: the index is derivable from the text.
  # If these two ever disagree, one of the two paths is wrong and neither is
  # obviously the wrong one.
  test "rebuilding reproduces exactly what the write path indexed" do
    populate()
    written = fingerprint()

    refute written == []

    ContentIndex.rebuild()

    assert fingerprint() == written
  end

  test "is idempotent" do
    populate()

    ContentIndex.rebuild()
    once = fingerprint()

    ContentIndex.rebuild()

    assert fingerprint() == once
  end

  test "restores an index that was dropped entirely" do
    populate()
    written = fingerprint()

    Repo.delete_all(Link)
    assert fingerprint() == []

    ContentIndex.rebuild()

    assert fingerprint() == written
  end

  # The repair job: a stale row left by some path that forgot to purge is
  # cleared, not merged with.
  test "clears rows no body accounts for" do
    populate()
    written = fingerprint()

    Repo.insert!(%Link{
      source_type: "task",
      source_id: UUIDv7.generate(),
      target_type: "task",
      target_id: UUIDv7.generate(),
      label: "早就没有的引用",
      position: 0
    })

    refute fingerprint() == written

    ContentIndex.rebuild()

    assert fingerprint() == written
  end

  test "reads only the newest revision of a document" do
    actor = insert(:actor)
    first = insert(:task)
    second = insert(:task)

    {:ok, document} =
      Documents.create_document(%{
        title: "甲",
        actor_id: actor.id,
        project_id: insert(:project).id,
        markdown: "见 [x](#{uri("task", first.id)})"
      })

    assert [link] = Repo.all(Link)

    {:ok, _revision} =
      Documents.create_revision(document, %{
        actor_id: actor.id,
        base_revision_id: document.latest_revision.id,
        block_ops: [
          %{
            op: "update",
            block_id: link.source_id,
            actor_id: actor.id,
            content: "改成 [y](#{uri("task", second.id)})"
          }
        ]
      })

    ContentIndex.rebuild()

    assert [rebuilt] = Repo.all(Link)
    assert rebuilt.target_id == second.id
  end

  test "reports what it read" do
    populate()

    tally = ContentIndex.rebuild()

    assert tally["document"] > 0
    assert tally["annotation"] == 1
    assert tally["task"] > 0
    assert tally["message"] == 1
  end

  test "on an empty system produces an empty index" do
    assert ContentIndex.rebuild()["annotation"] == 0
    assert fingerprint() == []
  end
end
