defmodule RintoPMO.DocumentsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Conversations
  alias RintoPMO.ConversationsMock
  alias RintoPMO.Documents
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision

  setup do
    # Creating a document inside a topic reads that topic to learn who wrote it.
    stub_with(ConversationsMock, Conversations)
    :ok
  end

  # A write made inside a topic is by that topic's assistant; one made outside
  # any topic is by whoever says so. The CLI is configured with the server's
  # human actor, so without this the pi running inside a topic would have
  # credited its documents to a person.
  describe "who a new document is by" do
    test "credits the topic's assistant, ignoring an actor the caller supplies" do
      conversation = insert(:conversation)
      impostor = insert(:actor)

      assert {:ok, document} =
               Documents.create_document(%{
                 title: "Written by a model",
                 conversation_id: conversation.id,
                 actor_id: impostor.id,
                 markdown: "## One\n\nText"
               })

      blocks = Documents.get_document!(document.id).latest_revision.blocks
      assert Enum.map(blocks, & &1.actor_id) == [conversation.assistant_actor_id]
      refute impostor.id in Enum.map(blocks, & &1.actor_id)
    end

    test "credits the named actor when there is no topic" do
      actor = insert(:actor)

      assert {:ok, document} =
               Documents.create_document(%{
                 title: "Written by a person",
                 actor_id: actor.id,
                 markdown: "## One\n\nText"
               })

      blocks = Documents.get_document!(document.id).latest_revision.blocks
      assert Enum.map(blocks, & &1.actor_id) == [actor.id]
    end

    # The same question every later revision can answer, and no reason for the
    # first one to be the exception.
    test "records which topic produced it" do
      conversation = insert(:conversation)

      assert {:ok, document} =
               Documents.create_document(%{
                 title: "From a discussion",
                 conversation_id: conversation.id,
                 markdown: "## One\n\nText"
               })

      assert document.latest_revision.source_conversation_id == conversation.id
    end

    test "refuses a topic with no assistant, having nobody to credit" do
      conversation = insert(:conversation, assistant_actor: nil)

      assert {:error, :assistant_actor_required, details} =
               Documents.create_document(%{
                 title: "Nobody wrote this",
                 conversation_id: conversation.id,
                 markdown: "## One\n\nText"
               })

      assert details.conversation_id == conversation.id
    end
  end

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

      assert document_ids(Documents.list_documents(%{})) ==
               MapSet.new([assigned.id, other.id, unassigned.id])

      assert document_ids(Documents.list_documents(%{project: project.id})) ==
               MapSet.new([assigned.id])

      assert document_ids(Documents.list_documents(%{project: :unassigned})) ==
               MapSet.new([unassigned.id])
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
      assert Documents.list_documents(%{project: project.id}) == []
    end
  end

  # Writing something down is not vouching for it, so a document is fleeting
  # until a person says otherwise. That makes fleeting the common case, which is
  # the whole reason such documents have to stay visible: filtering them out by
  # default would hide nearly the entire corpus.
  describe "fleeting documents" do
    test "every document is created fleeting" do
      assert {:ok, document} = Documents.create_document(%{title: "Written down"})
      assert document.fleeting
      assert Documents.get_document!(document.id).fleeting
    end

    # The same rule as block attribution: a caller that could declare its own
    # work adopted would be declaring that the review never needed to happen.
    test "ignores a caller trying to create a document already adopted" do
      assert {:ok, document} =
               Documents.create_document(%{title: "Claims to count", fleeting: false})

      assert document.fleeting
      assert Documents.get_document!(document.id).fleeting
    end

    test "lists both kinds together, or either one alone" do
      project = insert(:project)

      {:ok, scratch} = create_document(project, %{title: "Scratch"})
      {:ok, adopted} = create_document(project, %{title: "Adopted"})
      {:ok, adopted} = Documents.formalize_document(adopted)

      assert document_ids(Documents.list_documents(%{project: project.id})) ==
               MapSet.new([scratch.id, adopted.id])

      assert document_ids(Documents.list_documents(%{fleeting: true})) ==
               MapSet.new([scratch.id])

      assert document_ids(Documents.list_documents(%{fleeting: false})) ==
               MapSet.new([adopted.id])

      assert document_ids(Documents.list_documents(%{project: project.id, fleeting: false})) ==
               MapSet.new([adopted.id])
    end

    test "formalizes a fleeting document idempotently, touching nothing else" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Scratch"})

      assert {:ok, formal} = Documents.formalize_document(document)
      refute formal.fleeting
      assert formal.id == document.id

      assert {:ok, formal_again} = Documents.formalize_document(formal)
      refute formal_again.fleeting

      revisions = Documents.list_revisions(document)
      assert length(revisions) == 1
      assert Documents.get_document!(document.id).latest_revision.title == "Scratch"
    end

    # Adoption is about standing, so it survives everything the content does.
    # Nothing in the write path can put a document back to fleeting.
    test "a new revision does not return an adopted document to fleeting" do
      project = insert(:project)
      actor = insert(:actor)

      {:ok, document} =
        create_document(project, %{
          title: "Adopted",
          actor_id: actor.id,
          markdown: "## One\n\nText"
        })

      {:ok, document} = Documents.formalize_document(document)

      document = Documents.get_document!(document.id)
      [block] = document.latest_revision.blocks

      assert {:ok, _revision} =
               Documents.create_revision(document, %{
                 base_revision_id: document.latest_revision.id,
                 block_ops: [
                   %{
                     op: :update,
                     block_id: block.block_id,
                     actor_id: actor.id,
                     content: "Rewritten"
                   }
                 ]
               })

      refute Documents.get_document!(document.id).fleeting
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
