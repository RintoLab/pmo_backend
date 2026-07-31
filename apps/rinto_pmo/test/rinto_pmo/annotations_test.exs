defmodule RintoPMO.AnnotationsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.Annotations.Annotation

  describe "annotations" do
    test "creates an annotation with optional anchor snapshots" do
      document = insert(:document)
      actor = insert(:actor)
      block_id = UUIDv7.generate()

      assert {:ok, %Annotation{} = annotation} =
               Annotations.create_annotation(document, %{
                 actor_id: actor.id,
                 block_id: block_id,
                 block_text: "Full block body",
                 selected_text: "selected slice",
                 content: "Please tighten this"
               })

      assert annotation.document_id == document.id
      assert annotation.actor_id == actor.id
      assert annotation.block_id == block_id
      assert annotation.block_text == "Full block body"
      assert annotation.selected_text == "selected slice"
      assert annotation.content == "Please tighten this"
    end

    test "requires actor and content" do
      document = insert(:document)

      assert {:error, changeset} = Annotations.create_annotation(document, %{})
      assert "can't be blank" in errors_on(changeset).actor_id
      assert "can't be blank" in errors_on(changeset).content
    end

    test "lists annotations without replies and filters by block_id" do
      document = insert(:document)
      other = insert(:document)
      actor = insert(:actor)
      block_id = UUIDv7.generate()

      {:ok, matched} =
        Annotations.create_annotation(document, %{
          actor_id: actor.id,
          block_id: block_id,
          content: "Matched"
        })

      {:ok, unanchored} =
        Annotations.create_annotation(document, %{
          actor_id: actor.id,
          content: "Unanchored"
        })

      {:ok, _other_doc} =
        Annotations.create_annotation(other, %{
          actor_id: actor.id,
          content: "Other document"
        })

      assert annotation_ids(Annotations.list_annotations(document, %{})) ==
               MapSet.new([matched.id, unanchored.id])

      assert annotation_ids(Annotations.list_annotations(document, %{block_id: block_id})) ==
               MapSet.new([matched.id])

      assert annotation_ids(Annotations.list_annotations(document, %{block_id: nil})) ==
               MapSet.new([unanchored.id])

      listed = Annotations.list_annotations(document, %{})
      assert Enum.all?(listed, &(not Ecto.assoc_loaded?(&1.replies)))
    end

    test "updates content and deletes the annotation" do
      annotation = insert(:annotation, content: "Old")

      assert {:ok, updated} =
               Annotations.update_annotation(annotation, %{content: "New"})

      assert updated.content == "New"

      assert {:ok, deleted} = Annotations.delete_annotation(updated)
      assert deleted.id == annotation.id

      assert_raise Ecto.NoResultsError, fn ->
        Annotations.get_annotation!(annotation.document, annotation.id)
      end
    end
  end

  describe "replies" do
    test "appends monotonic positions and does not renumber after delete" do
      annotation = insert(:annotation)
      actor = insert(:actor)

      assert {:ok, first} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "First reply"
               })

      assert {:ok, second} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "Second reply"
               })

      assert first.position == 0
      assert second.position == 1

      assert {:ok, _} = Annotations.delete_reply(first)

      assert {:ok, third} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "Third reply"
               })

      assert third.position == 2

      loaded = Annotations.get_annotation!(annotation.document, annotation.id)

      assert Enum.map(loaded.replies, &{&1.position, &1.content}) == [
               {1, "Second reply"},
               {2, "Third reply"}
             ]
    end

    test "updates reply content without changing position" do
      annotation = insert(:annotation)
      actor = insert(:actor)

      {:ok, reply} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "Old"})

      assert {:ok, updated} = Annotations.update_reply(reply, %{content: "New"})
      assert updated.content == "New"
      assert updated.position == 0
    end

    test "scopes get_reply! to the annotation" do
      annotation = insert(:annotation)
      other = insert(:annotation)
      actor = insert(:actor)

      {:ok, reply} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "Mine"})

      assert Annotations.get_reply!(annotation, reply.id).id == reply.id

      assert_raise Ecto.NoResultsError, fn ->
        Annotations.get_reply!(other, reply.id)
      end
    end
  end

  defp annotation_ids(annotations) do
    annotations |> Enum.map(& &1.id) |> MapSet.new()
  end
end
