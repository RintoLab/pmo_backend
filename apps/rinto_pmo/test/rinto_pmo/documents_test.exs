defmodule RintoPMO.DocumentsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Documents
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision

  describe "documents" do
    test "creates a project document with an initial revision, cutting the body into blocks" do
      project = insert(:project)
      actor = insert(:actor, enabled: false)

      assert {:ok, %Document{} = document} =
               create_document(project, %{
                 title: "Project plan",
                 actor_id: actor.id,
                 markdown: "## Background\n\nContext\n\n## Goals\n\nGoals"
               })

      assert document.project_id == project.id

      assert %DocumentRevision{parent_id: nil, title: "Project plan"} =
               revision =
               document.latest_revision

      assert Enum.map(revision.blocks, & &1.content) == [
               "## Background\n\nContext",
               "## Goals\n\nGoals"
             ]

      assert Enum.map(revision.blocks, & &1.position) == [0, 1]
      assert Enum.map(revision.blocks, & &1.actor_id) == [actor.id, actor.id]
      assert Enum.uniq(Enum.map(revision.blocks, & &1.block_id)) |> length() == 2
    end

    test "allows an unassigned document without a body" do
      assert {:ok, document} = Documents.create_document(%{title: "Empty draft"})
      assert document.project_id == nil
      assert %{blocks: []} = document.latest_revision
    end

    test "a body with nothing but whitespace produces no blocks" do
      assert {:ok, document} =
               Documents.create_document(%{
                 title: "Empty draft",
                 actor_id: insert(:actor).id,
                 markdown: "\n\n   \n"
               })

      assert %{blocks: []} = document.latest_revision
    end

    test "requires an actor for a body that produces blocks" do
      assert {:error, changeset} =
               Documents.create_document(%{title: "Plan", markdown: "## One\n\ntext"})

      assert %{revisions: [%{blocks: [%{actor_id: ["can't be blank"]}]}]} = errors_on(changeset)
    end

    test "rejects a body that is not a string" do
      assert {:error, changeset} =
               Documents.create_document(%{title: "Plan", markdown: %{"nope" => true}})

      assert %{markdown: ["is invalid"]} = errors_on(changeset)
    end

    test "requires the revision title" do
      assert {:error, changeset} = Documents.create_document(%{})
      assert %{revisions: [%{title: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "rejects a blank revision title" do
      assert {:error, changeset} = Documents.create_document(%{title: ""})
      assert %{revisions: [%{title: title_errors}]} = errors_on(changeset)

      assert "can't be blank" in title_errors or
               Enum.any?(title_errors, &String.contains?(&1, "at least"))
    end

    test "lists all, project, and unassigned scopes while hiding archived documents" do
      project = insert(:project)
      other_project = insert(:project)

      {:ok, assigned} = create_document(project, %{title: "Assigned"})
      {:ok, archived} = create_document(project, %{title: "Archived"})
      {:ok, other} = create_document(other_project, %{title: "Other"})
      {:ok, unassigned} = Documents.create_document(%{title: "Unassigned"})
      {:ok, _archived} = Documents.archive_document(archived)

      assert document_ids(Documents.list_documents(:all)) ==
               MapSet.new([assigned.id, other.id, unassigned.id])

      assert document_ids(Documents.list_documents({:project, project.id})) ==
               MapSet.new([assigned.id])

      assert document_ids(Documents.list_documents(:unassigned)) == MapSet.new([unassigned.id])
    end

    test "fetches a top-level document by id" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Top-level resource"})

      assert Documents.get_document!(document.id).id == document.id
    end

    test "archives a document idempotently" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Draft"})

      assert {:ok, archived} = Documents.archive_document(document)
      assert %DateTime{} = archived.archived_at
      assert {:ok, archived_again} = Documents.archive_document(archived)
      assert archived_again.archived_at == archived.archived_at
      assert Documents.list_documents({:project, project.id}) == []
    end
  end

  describe "revisions" do
    test "applies block operations into a new immutable snapshot" do
      project = insert(:project)
      first_actor = insert(:actor)

      second_actor =
        insert(:actor,
          kind: :ai,
          provider: "openai",
          model: "gpt",
          thinking_level: "low"
        )

      {:ok, document} =
        create_document(project, %{
          title: "Plan",
          actor_id: first_actor.id,
          markdown: "## First\n\nOld\n\n## Second\n\nKeep"
        })

      parent = document.latest_revision
      [first, second] = parent.blocks

      assert {:ok, revision} =
               Documents.create_revision(document, %{
                 base_revision_id: parent.id,
                 change_summary: "Revise the first section",
                 block_ops: [
                   %{
                     op: :update,
                     block_id: first.block_id,
                     actor_id: second_actor.id,
                     content: "## First\n\nNew"
                   },
                   %{op: :move_after, block_id: second.block_id, after_block_id: nil}
                 ]
               })

      assert revision.parent_id == parent.id
      assert revision.title == parent.title
      assert revision.id > parent.id
      assert Enum.map(revision.blocks, & &1.block_id) == [second.block_id, first.block_id]

      [moved, updated] = revision.blocks
      assert moved.actor_id == first_actor.id
      assert updated.actor_id == second_actor.id
      assert updated.content == "## First\n\nNew"

      persisted_parent = Documents.get_revision!(document, parent.id)

      assert Enum.map(persisted_parent.blocks, & &1.content) == [
               "## First\n\nOld",
               "## Second\n\nKeep"
             ]
    end

    test "creates a revision even when the frontend submits no content change" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Draft"})
      parent = document.latest_revision

      assert {:ok, revision} =
               Documents.create_revision(document, %{base_revision_id: parent.id})

      assert revision.parent_id == parent.id
      assert revision.title == parent.title
      assert revision.blocks == []
    end

    test "rejects a stale base revision" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Draft"})
      first = document.latest_revision
      {:ok, second} = Documents.create_revision(document, %{base_revision_id: first.id})

      assert {:error, :stale_document, %{current_revision_id: current_id}} =
               Documents.create_revision(document, %{base_revision_id: first.id})

      assert current_id == second.id
    end

    test "returns invalid block operation details" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Draft"})
      parent = document.latest_revision
      missing_block_id = UUIDv7.generate()

      assert {:error, :invalid_block_op,
              %{operation_index: 0, reason: "block_id does not identify a current block"}} =
               Documents.create_revision(document, %{
                 base_revision_id: parent.id,
                 block_ops: [%{op: :delete, block_id: missing_block_id}]
               })
    end

    test "lists revisions by descending UUIDv7 id and fetches scoped snapshots" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Draft"})
      first = document.latest_revision
      {:ok, second} = Documents.create_revision(document, %{base_revision_id: first.id})

      assert Enum.map(Documents.list_revisions(document), & &1.id) == [second.id, first.id]
      assert Documents.get_revision!(document, first.id).id == first.id

      other_document = insert(:document, project: project)
      other_revision = insert(:document_revision, document: other_document)

      assert_raise Ecto.NoResultsError, fn ->
        Documents.get_revision!(document, other_revision.id)
      end
    end
  end

  defp create_document(project, attrs) do
    Documents.create_document(Map.put(attrs, :project_id, project.id))
  end

  defp document_ids(documents) do
    documents |> Enum.map(& &1.id) |> MapSet.new()
  end
end
