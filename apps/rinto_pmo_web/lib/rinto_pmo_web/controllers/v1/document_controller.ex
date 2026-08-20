defmodule RintoPMOWeb.V1.DocumentController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Documents.Document
  alias RintoPMO.Utils
  alias RintoPMOWeb.V1.DecompositionJSON

  @statuses Map.new(Document.statuses(), &{Atom.to_string(&1), &1})

  def index(conn, params) do
    with {:ok, filter} <- document_filter(params) do
      documents = Utils.module(:documents).list_documents(filter)
      render(conn, :index, documents: documents)
    end
  end

  def show(conn, %{"id" => id}) do
    document = Utils.module(:documents).get_document!(id)
    render(conn, :show, document: document)
  end

  def create(conn, params) do
    with {:ok, document} <- Utils.module(:documents).create_document(params) do
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
  Asks for a document to be broken down into a task document.

  Answers `202` with the attempt, not the breakdown: the model call runs in a
  job, and what a client does next is watch. Every refusal is made here rather
  than inside the job, so a person clicking a button hears no while they are
  still looking at it.

  Watching is `RintoPMOWeb.DocumentChannel` on `document:{id}`, which carries
  the model's output as it arrives and the attempt's row as it changes.
  `GET /documents/{id}/decomposition` answers the same row for a client that
  would rather ask.
  """
  def decompose(conn, %{"id" => id}) do
    context = Utils.module(:documents)
    document = context.get_document!(id)

    with {:ok, decomposition} <- context.request_decomposition(document) do
      conn
      |> put_status(:accepted)
      |> put_view(DecompositionJSON)
      |> render(:show, decomposition: decomposition)
    end
  end

  @doc """
  The most recent attempt to break this document down, or `null`.

  Most recent rather than in-flight: an attempt that failed a minute ago is
  exactly what somebody opening the page needs to see.
  """
  def decomposition(conn, %{"id" => id}) do
    context = Utils.module(:documents)
    document = context.get_document!(id)

    conn
    |> put_view(DecompositionJSON)
    |> render(:show, decomposition: context.latest_decomposition(document))
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
