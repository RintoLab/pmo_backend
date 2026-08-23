defmodule RintoPMO.Documents.BlockEmbeddingTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Documents
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision

  defp vector, do: Pgvector.new(List.duplicate(0.1, 1024))

  defp latest_blocks(document) do
    revision =
      DocumentRevision
      |> where([r], r.document_id == ^document.id)
      |> order_by([r], desc: r.id)
      |> limit(1)
      |> Repo.one!()

    {revision, DocumentBlock |> where([b], b.revision_id == ^revision.id) |> Repo.all()}
  end

  defp embed_all!(document) do
    {revision, _blocks} = latest_blocks(document)

    DocumentBlock
    |> where([b], b.revision_id == ^revision.id)
    |> Repo.update_all(set: [embedding: vector()])
  end

  defp document_with(markdown) do
    {:ok, document} =
      Documents.create_document(%{
        title: "上线流程",
        actor_id: insert(:actor).id,
        project_id: insert(:project).id,
        markdown: markdown
      })

    document
  end

  defp commit(document, actor, ops) do
    {:ok, revision} =
      Documents.create_revision(document, %{
        actor_id: actor.id,
        base_revision_id: document.latest_revision.id,
        block_ops: ops
      })

    revision
  end

  # The claim the whole design rests on: a revision writes a new row for every
  # block, and a vector must survive that for the blocks nobody touched.
  test "a block whose content is unchanged carries its vector onto the new row" do
    actor = insert(:actor)
    document = document_with("## 改的那块\n\n原内容\n\n## 没改的那块\n\n别动我")
    embed_all!(document)

    {_revision, before} = latest_blocks(document)
    edited = Enum.find(before, &(&1.content =~ "改的那块"))

    commit(document, actor, [
      %{op: "update", block_id: edited.block_id, actor_id: actor.id, content: "## 改的那块\n\n改过的"}
    ])

    {_revision, after_commit} = latest_blocks(document)
    by_content = Map.new(after_commit, &{&1.content, &1})

    assert is_nil(by_content["## 改的那块\n\n改过的"].embedding),
           "an edited block kept a vector made from text it no longer holds"

    assert by_content["## 没改的那块\n\n别动我"].embedding,
           "an untouched block was sent back for re-embedding"
  end

  test "a block added by a revision starts with no vector" do
    actor = insert(:actor)
    document = document_with("## 一\n\n甲")
    embed_all!(document)

    {_revision, [first]} = latest_blocks(document)

    commit(document, actor, [
      %{
        op: "insert_after",
        after_block_id: first.block_id,
        actor_id: actor.id,
        content: "## 二\n\n乙"
      }
    ])

    {_revision, blocks} = latest_blocks(document)
    added = Enum.find(blocks, &(&1.content =~ "二"))

    assert is_nil(added.embedding)
  end

  # Exactly one snapshot of a block carries a vector: history is not searched,
  # and four kilobytes a row to answer nothing is not worth keeping.
  test "the superseded revision's rows give theirs up" do
    actor = insert(:actor)
    document = document_with("## 一\n\n甲")
    embed_all!(document)

    {previous, _blocks} = latest_blocks(document)
    commit(document, actor, [])

    superseded =
      DocumentBlock
      |> where([b], b.revision_id == ^previous.id)
      |> Repo.all()

    assert superseded != []
    assert Enum.all?(superseded, &is_nil(&1.embedding))
  end

  test "a document's first revision has no vectors to inherit" do
    document = document_with("## 一\n\n甲\n\n## 二\n\n乙")

    {_revision, blocks} = latest_blocks(document)

    assert length(blocks) == 2
    assert Enum.all?(blocks, &is_nil(&1.embedding))
  end

  # Nothing a caller sends can put a vector on a block: they are written by the
  # worker that computes them and inherited by the write path, never cast.
  test "a caller cannot set one" do
    document = document_with("## 一\n\n甲")
    {_revision, [block]} = latest_blocks(document)

    changeset = DocumentBlock.changeset(block, %{content: "改了", embedding: vector()})

    refute Map.has_key?(changeset.changes, :embedding)
  end
end
