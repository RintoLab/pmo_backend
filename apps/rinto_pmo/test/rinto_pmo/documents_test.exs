defmodule RintoPMO.DocumentsTest do
  use RintoPMO.DataCase, async: true
  use Oban.Testing, repo: RintoPMO.Repo

  alias RintoPMO.Agent.WbsGeneratorMock
  alias RintoPMO.Conversations
  alias RintoPMO.ConversationsMock
  alias RintoPMO.Documents
  alias RintoPMO.Documents.DecompositionWorker
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Documents.Notifier
  alias RintoPMO.Projects
  alias RintoPMO.ProjectsMock
  alias RintoPMO.Settings

  setup do
    # Creating a document inside a topic reads that topic to learn who wrote it.
    stub_with(ConversationsMock, Conversations)
    # A document created without a project is filed in the default one, which
    # therefore has to exist.
    stub_with(ProjectsMock, Projects)
    insert(:default_project)
    :ok
  end

  # Most notes are not written with a project in mind, and asking for one
  # before anything can be written down is a question at the wrong moment. But
  # a document filed nowhere is one nothing lists, which is how a note is lost.
  describe "which project a new document belongs to" do
    test "files one with no project of its own in the default project" do
      default = Projects.get_default_project()

      assert {:ok, document} = Documents.create_document(%{title: "A note"})
      assert document.project_id == default.id
    end

    test "a project the caller names still wins" do
      chosen = insert(:project)

      assert {:ok, document} =
               Documents.create_document(%{title: "A note", project_id: chosen.id})

      assert document.project_id == chosen.id
    end

    test "reads a string key as readily as an atom one" do
      chosen = insert(:project)

      assert {:ok, document} =
               Documents.create_document(%{"title" => "A note", "project_id" => chosen.id})

      assert document.project_id == chosen.id
    end

    # The reserved slug has been renamed, or the setup task was never run.
    # Both are things to fix rather than to work around one document at a time,
    # so this is reported rather than quietly filed nowhere.
    test "refuses when the default project is not there" do
      Repo.delete!(Projects.get_default_project())

      assert {:error, :default_project_missing, %{slug: "personal"}} =
               Documents.create_document(%{title: "A note"})
    end
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

    test "allows a document without a body" do
      assert {:ok, document} = Documents.create_document(%{title: "Empty draft"})
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
      # Built rather than created: nothing produces one of these any more, but
      # rows written before documents had a default project still exist, and
      # the scope that finds them has to keep working.
      unassigned = insert(:document, project: nil)
      insert(:document_revision, document: unassigned)
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

  # Writing something down is not vouching for it, so a document is `:draft`
  # until a person says otherwise. That makes draft the common case, which is
  # the whole reason such documents have to stay visible: filtering them out by
  # default would hide nearly the entire corpus.
  describe "document status" do
    test "every document is created draft" do
      assert {:ok, document} = Documents.create_document(%{title: "Written down"})
      assert document.status == :draft
      assert Documents.get_document!(document.id).status == :draft
    end

    # The same rule as block attribution: a caller that could declare its own
    # work adopted would be declaring that the review never needed to happen.
    test "ignores a caller trying to create a document already adopted" do
      assert {:ok, document} =
               Documents.create_document(%{title: "Claims to count", status: :formal})

      assert document.status == :draft
      assert Documents.get_document!(document.id).status == :draft
    end

    test "lists both kinds together, or either one alone" do
      project = insert(:project)

      {:ok, scratch} = create_document(project, %{title: "Scratch"})
      {:ok, adopted} = create_document(project, %{title: "Adopted"})
      {:ok, adopted} = Documents.formalize_document(adopted)

      assert document_ids(Documents.list_documents(%{project: project.id})) ==
               MapSet.new([scratch.id, adopted.id])

      assert document_ids(Documents.list_documents(%{status: :draft})) ==
               MapSet.new([scratch.id])

      assert document_ids(Documents.list_documents(%{status: :formal})) ==
               MapSet.new([adopted.id])

      assert document_ids(Documents.list_documents(%{project: project.id, status: :formal})) ==
               MapSet.new([adopted.id])
    end

    test "formalizes a draft document idempotently, touching nothing else" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Scratch"})

      assert {:ok, formal} = Documents.formalize_document(document)
      assert formal.status == :formal
      assert formal.id == document.id

      assert {:ok, formal_again} = Documents.formalize_document(formal)
      assert formal_again.status == :formal

      revisions = Documents.list_revisions(document)
      assert length(revisions) == 1
      assert Documents.get_document!(document.id).latest_revision.title == "Scratch"
    end

    # Idempotent is not the same as permissive. An applied document has already
    # been consumed downstream, and reporting success would tell the caller it
    # is available to be consumed again.
    test "refuses to walk an applied document back to formal" do
      project = insert(:project)
      {:ok, document} = create_document(project, %{title: "Consumed"})
      {:ok, document} = Documents.formalize_document(document)

      applied = %{document | status: :applied}

      assert {:error, changeset} = Documents.formalize_document(applied)
      assert "an applied document cannot go back to formal" in errors_on(changeset).status
    end

    # Adoption is about standing, so it survives everything the content does.
    # Nothing in the write path can put a document back to `:draft`.
    test "a new revision does not return an adopted document to draft" do
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

      assert Documents.get_document!(document.id).status == :formal
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

  # Breaking a plan down produces a second document, and an ordinary one: it
  # starts `:draft` like everything else and has to be adopted in its own right
  # before anything downstream may act on it. The gate sits on the *source* --
  # only a plan somebody vouched for is worth turning into work.
  describe "requesting and running a decomposition" do
    setup do
      actor = insert(:actor, kind: :ai, provider: "google", model: "flash", thinking_level: "off")
      {:ok, _settings} = Settings.put_actor("decomposition_actor", actor.id)
      {:ok, actor: actor}
    end

    test "answers with a pending attempt and leaves the work to a job" do
      source = formal_document()

      assert {:ok, decomposition} = Documents.request_decomposition(source)
      assert decomposition.status == :pending
      assert decomposition.source_document_id == source.id
      assert decomposition.result_document_id == nil

      assert_enqueued(worker: DecompositionWorker, args: %{decomposition_id: decomposition.id})
    end

    # The standing-breakdown check cannot see this one: a run that has not
    # finished has produced no document to find.
    test "refuses a second attempt while one is in flight" do
      source = formal_document()
      assert {:ok, _first} = Documents.request_decomposition(source)

      assert {:error, :decomposition_in_flight, %{document_id: document_id}} =
               Documents.request_decomposition(source)

      assert document_id == source.id
    end

    # Told no while they are still looking at the button, rather than thirty
    # seconds later in a job they have to go and read.
    test "makes the same refusals before queueing anything" do
      project = insert(:project)
      {:ok, draft} = create_document(project, %{title: "Half an idea"})

      assert {:error, :document_not_formal, %{status: :draft}} =
               Documents.request_decomposition(draft)

      refute_enqueued(worker: DecompositionWorker)
    end

    test "runs the attempt, streaming the output and recording the result", %{actor: actor} do
      project = insert(:project)

      {:ok, source} =
        create_document(project, %{
          title: "Rollout plan",
          actor_id: actor.id,
          markdown: "## Canary\n\nTen percent first.\n\n## Rollback\n\nOne switch."
        })

      {:ok, source} = Documents.formalize_document(source)
      {:ok, decomposition} = Documents.request_decomposition(source)
      :ok = Notifier.subscribe(source.id)

      expect(WbsGeneratorMock, :generate, fn input, opts ->
        # The whole document, which is the entire input to deciding what the
        # work is -- and the reason this call is not shaped like naming's.
        assert input.title == "Rollout plan"
        assert input.blocks == ["## Canary\n\nTen percent first.", "## Rollback\n\nOne switch."]
        assert opts[:provider] == "google"
        assert opts[:model] == "flash"
        assert opts[:thinking] == "off"

        # What a person watching sees, as the model produces it.
        opts[:on_chunk].("## Canary\n")
        opts[:on_chunk].("- Wire the split")
        {:ok, "## Canary\n\n- Wire the split"}
      end)

      assert :ok = Documents.run_decomposition(decomposition)

      assert_received {:decomposition_updated, %{status: :running}}
      assert_received {:decomposition_output, id, "## Canary\n"}
      assert id == decomposition.id
      assert_received {:decomposition_output, ^id, "- Wire the split"}
      assert_received {:decomposition_updated, %{status: :succeeded} = finished}

      breakdown = Documents.breakdown_of(source)
      assert finished.result_document_id == breakdown.id
      assert finished.error == nil

      # An ordinary document: nobody has vouched for it yet, it is filed with
      # its source, and its title is built rather than asked for.
      assert breakdown.status == :draft
      assert breakdown.project_id == project.id

      breakdown = Documents.get_document!(breakdown.id)
      assert breakdown.latest_revision.title == "Rollout plan · 任务分解"

      [block] = breakdown.latest_revision.blocks
      assert block.content == "## Canary\n\n- Wire the split"
      assert block.actor_id == actor.id
    end

    # One breakdown at a time, the way a topic holds one live proposal per
    # block. Two would be two answers with nothing to choose between them.
    test "refuses while a breakdown already stands" do
      source = formal_document()
      run_decomposition(source, "- Something")

      assert {:error, :decomposition_exists, %{document_id: standing}} =
               Documents.request_decomposition(source)

      assert standing == Documents.breakdown_of(source).id
    end

    # Which is how a bad breakdown is redone: throw it away, ask again.
    test "frees the slot when the standing breakdown is archived" do
      source = formal_document()
      first = run_decomposition(source, "- Something")
      assert {:ok, _archived} = Documents.archive_document(first)

      assert Documents.breakdown_of(source) == nil
      assert {:ok, _second} = Documents.request_decomposition(source)
    end

    # Naming falls back to the topic's own assistant. This belongs to no topic,
    # so there is nothing to fall back to and nothing to pick instead.
    test "refuses when nobody holds the role" do
      {:ok, _settings} = Settings.put_actor("decomposition_actor", nil)
      source = formal_document()

      assert {:error, :no_decomposition_actor, %{}} = Documents.request_decomposition(source)
      refute_enqueued(worker: DecompositionWorker)
    end

    # A recorded failure is not also a queue failure: there is nothing to retry
    # that would not ask the same question again.
    test "writes a failure down and tells everyone watching" do
      source = formal_document()
      {:ok, decomposition} = Documents.request_decomposition(source)
      :ok = Notifier.subscribe(source.id)

      expect(WbsGeneratorMock, :generate, fn _input, _opts -> {:error, :timeout} end)

      assert :ok = Documents.run_decomposition(decomposition)

      assert_received {:decomposition_updated, %{status: :running}}
      assert_received {:decomposition_updated, %{status: :failed} = failed}
      assert failed.error == "the model call ran out of time"
      assert failed.result_document_id == nil
      assert Documents.breakdown_of(source) == nil
    end

    # The whole reason the field exists. What shipped first stored
    # `{:pi_exit, 1}` -- an exit code of a process the reader has never heard
    # of -- while the sentence that explained it went only to the log.
    test "records the provider's own words when the model call fails" do
      source = formal_document()
      {:ok, decomposition} = Documents.request_decomposition(source)

      expect(WbsGeneratorMock, :generate, fn _input, _opts ->
        {:error, {:pi_exit, 1, "google: API key not valid. Please pass a valid API key."}}
      end)

      assert :ok = Documents.run_decomposition(decomposition)

      assert Documents.latest_decomposition(source).error ==
               "google: API key not valid. Please pass a valid API key."
    end

    test "says so plainly when the model call fails without explaining itself" do
      source = formal_document()
      {:ok, decomposition} = Documents.request_decomposition(source)

      expect(WbsGeneratorMock, :generate, fn _input, _opts -> {:error, {:pi_exit, 1, ""}} end)

      assert :ok = Documents.run_decomposition(decomposition)
      assert Documents.latest_decomposition(source).error =~ "exited 1"
    end

    # An attempt that failed a minute ago is exactly what somebody opening the
    # page needs to see, so this is not "in flight".
    test "latest_decomposition/1 answers the most recent attempt, finished or not" do
      source = formal_document()
      assert Documents.latest_decomposition(source) == nil

      {:ok, first} = Documents.request_decomposition(source)
      expect(WbsGeneratorMock, :generate, fn _input, _opts -> {:error, :timeout} end)
      :ok = Documents.run_decomposition(first)

      assert Documents.latest_decomposition(source).id == first.id
      assert Documents.latest_decomposition(source).status == :failed

      # A failed attempt holds nothing, so asking again is allowed.
      assert {:ok, second} = Documents.request_decomposition(source)
      assert Documents.latest_decomposition(source).id == second.id
    end
  end

  # Request and run in one go, for the tests that care about what a finished
  # decomposition leaves behind rather than about the running of it.
  defp run_decomposition(source, markdown) do
    {:ok, attempt} = Documents.request_decomposition(source)
    expect(WbsGeneratorMock, :generate, fn _input, _opts -> {:ok, markdown} end)
    :ok = Documents.run_decomposition(attempt)
    Documents.breakdown_of(source)
  end

  defp formal_document do
    {:ok, document} =
      Documents.create_document(%{
        title: "Rollout plan",
        actor_id: insert(:actor).id,
        markdown: "## Canary\n\nText"
      })

    {:ok, formal} = Documents.formalize_document(document)
    formal
  end

  defp create_document(project, attrs) do
    Documents.create_document(Map.put(attrs, :project_id, project.id))
  end

  defp document_ids(documents) do
    documents |> Enum.map(& &1.id) |> MapSet.new()
  end
end
