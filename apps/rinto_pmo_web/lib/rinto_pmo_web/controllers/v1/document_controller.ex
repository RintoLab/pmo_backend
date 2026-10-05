defmodule RintoPMOWeb.V1.DocumentController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.Scope
  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken
  alias RintoPMOWeb.V1.TaskJSON

  @statuses Map.new(Document.statuses(), &{Atom.to_string(&1), &1})

  def index(conn, params) do
    with {:ok, filter} <- document_filter(params),
         {:ok, scope} <- Scope.parse(params) do
      filter = Map.merge(filter, scope)
      documents = Utils.module(:documents).list_documents(filter)
      render(conn, :index, documents: documents)
    end
  end

  def update(conn, %{"id" => id} = params) do
    context = Utils.module(:documents)

    with {:ok, document} <- context.update_document_metadata(context.get_document!(id), params) do
      render(conn, :show, document: document)
    end
  end

  def show(conn, %{"id" => id}) do
    document = Utils.module(:documents).get_document!(id)
    render(conn, :show, document: document)
  end

  @doc """
  Writes a document, credited to whoever is calling.

  `actor_id` comes from the token rather than the body, the rule every write a
  person makes follows. A body naming somebody else would be a caller deciding
  authorship, which is the one thing about a document nobody outside the server
  gets to say -- and a document written inside a topic is not credited here at
  all: `conversation_id` is the whole of it, and `RintoPMO.Documents` derives
  the AI that wrote it.
  """
  def create(conn, params) do
    attrs = Map.put(params, "actor_id", ActorToken.current_actor!(conn).id)

    with {:ok, document} <- Utils.module(:documents).create_document(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, document: document)
    end
  end

  @doc """
  Reports how a Markdown body would be cut into blocks, creating nothing.

  The split is the server's decision, so this is the only way an author can see
  the grain before living with it.
  """
  def preview_blocks(conn, %{"markdown" => markdown}) when is_binary(markdown) do
    case Utils.module(:documents).preview_blocks(markdown) do
      {:ok, contents} -> render(conn, :preview_blocks, contents: contents)
      {:error, _reason} -> {:error, :invalid_markdown, %{markdown: ["is invalid"]}}
    end
  end

  def preview_blocks(_conn, _params) do
    {:error, :bad_request, %{markdown: ["can't be blank"]}}
  end

  @doc """
  Files a document under a different project.

  For a document that landed in the wrong project and is corrected right after
  -- typically one an AI wrote in a topic without naming a project, which put
  it in the default one. A person's action, so it is reachable here and not
  from the agent CLI: the author is not who corrects the author.

  Any document may be moved, including an `:applied` one, and that is not an
  invitation. Tasks filed from a breakdown keep the project they were filed
  into and do not follow -- see `RintoPMO.Documents.refile_document/2`.

  `project_id` is required and is never defaulted; a body without one is a
  bad request rather than a move to nowhere.
  """
  def refile(conn, %{"id" => id, "project_id" => project_id}) when is_binary(project_id) do
    context = Utils.module(:documents)
    document = context.get_document!(id)

    with {:ok, document} <- context.refile_document(document, project_id) do
      render(conn, :show, document: document)
    end
  end

  # Nothing is defaulted here. Creation reaches for the default project so that
  # a document is never filed nowhere; letting a body that names no project
  # move one out of every listing would undo that by omission.
  def refile(_conn, _params) do
    {:error, :bad_request, %{project_id: ["can't be blank"]}}
  end

  def delete(conn, %{"id" => id}) do
    context = Utils.module(:documents)
    document = context.get_document!(id)

    with {:ok, _document} <- context.archive_document(document) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  Adopts a `draft` document as a `formal` one.

  A person's action -- see `RintoPMO.Documents.formalize_document/1` -- so it is
  reachable only here and not from the agent CLI. An `applied` document is
  refused: there is no way back along this axis.
  """
  def formalize(conn, %{"id" => id}) do
    context = Utils.module(:documents)
    document = context.get_document!(id)

    with {:ok, document} <- context.formalize_document(document) do
      render(conn, :show, document: document)
    end
  end

  @doc """
  Pins a document so listings keep it at the front.

  A person's bookmark -- see `RintoPMO.Documents.pin_document/1` -- so it is
  reachable only here and not from the agent CLI. Idempotent: pinning an
  already pinned document changes nothing.
  """
  def pin(conn, %{"id" => id}) do
    context = Utils.module(:documents)
    document = context.get_document!(id)

    with {:ok, document} <- context.pin_document(document) do
      render(conn, :show, document: document)
    end
  end

  @doc """
  Clears a document's pin.

  The mirror of `pin/2`. Idempotent: unpinning a document that was not pinned
  changes nothing.
  """
  def unpin(conn, %{"id" => id}) do
    context = Utils.module(:documents)
    document = context.get_document!(id)

    with {:ok, document} <- context.unpin_document(document) do
      render(conn, :show, document: document)
    end
  end

  @doc """
  Files an adopted task document as the project's work breakdown.

  A task document arrives from a topic -- somebody sends the breakdown
  shortcut, the model writes it with `rinto-pmo doc create` -- and this turns
  the document they settled on into the work. Between them sits the only gate
  that matters: somebody adopted it, with `POST /documents/{id}/formalize`.

  Answers `201` with every task created, flat and in document order, with
  `parent_id` on each. Same shape as `GET /projects/{slug}/tasks`, so a client
  builds the tree the way it already does.

  The document comes out `applied` and cannot be filed twice. Editing it
  afterwards changes nothing about the tasks, deliberately: work that turned
  out wrong is cancelled, work that is missing comes from another document.
  """
  def file_breakdown(conn, %{"id" => id}) do
    breakdown = Utils.module(:documents).get_document!(id)

    with {:ok, tasks} <- Utils.module(:tasks).file_breakdown(breakdown) do
      conn
      |> put_status(:created)
      |> put_view(TaskJSON)
      |> render(:index, tasks: tasks)
    end
  end

  defp document_filter(params) do
    with {:ok, filter} <- project_filter(params) do
      status_filter(filter, params)
    end
  end

  defp project_filter(params) do
    case Map.get(params, "project_id") do
      nil -> {:ok, %{}}
      "none" -> {:ok, %{project: :unassigned}}
      project_id -> cast_project_id(project_id)
    end
  end

  defp cast_project_id(project_id) do
    case UUIDv7.cast(project_id) do
      {:ok, project_id} -> {:ok, %{project: project_id}}
      :error -> {:error, :bad_request, %{project_id: ["is invalid"]}}
    end
  end

  defp status_filter(filter, params) do
    case Map.get(params, "status") do
      nil ->
        {:ok, filter}

      value ->
        case Map.fetch(@statuses, value) do
          {:ok, status} -> {:ok, Map.put(filter, :status, status)}
          :error -> {:error, :bad_request, %{status: ["is invalid"]}}
        end
    end
  end
end
