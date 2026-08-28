defmodule RintoPMOWeb.V1.AnnotationController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Jobs
  alias RintoPMO.Utils

  def index(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)

    with {:ok, filter} <- annotation_filter(params) do
      annotations = annotations_context().list_annotations(document, filter)
      render(conn, :index, annotations: annotations)
    end
  end

  def show(conn, %{"document_id" => document_id, "id" => id}) do
    document = get_document!(document_id)
    annotation = annotations_context().get_annotation!(document, id)
    render(conn, :show, annotation: annotation)
  end

  def create(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)
    attrs = Map.delete(params, "document_id")

    with {:ok, annotation} <- annotations_context().create_annotation(document, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, annotation: %{annotation | replies: []})
    end
  end

  def update(conn, %{"document_id" => document_id, "id" => id} = params) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)
    attrs = Map.drop(params, ["document_id", "id"])

    with {:ok, annotation} <- context.update_annotation(annotation, attrs) do
      render(conn, :show, annotation: annotation)
    end
  end

  def delete(conn, %{"document_id" => document_id, "id" => id}) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)

    with {:ok, _annotation} <- context.delete_annotation(annotation) do
      send_resp(conn, :no_content, "")
    end
  end

  def confirm(conn, %{"document_id" => document_id, "id" => id} = params) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)
    attrs = Map.take(params, ["confirmed_by_revision_id"])

    with {:ok, annotation} <- context.confirm_annotation(annotation, attrs) do
      render(conn, :show, annotation: annotation)
    end
  end

  def unconfirm(conn, %{"document_id" => document_id, "id" => id}) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)

    with {:ok, annotation} <- context.unconfirm_annotation(annotation) do
      render(conn, :show, annotation: annotation)
    end
  end

  @doc """
  Asks the AI for one reply to this annotation.

  Answers with the *job*, the way estimation does: the model call takes as long
  as it takes, and what a client does next is watch `document:{id}`.
  """
  def reply(conn, %{"document_id" => document_id, "id" => id}) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)

    with {:ok, job} <- context.request_reply(annotation) do
      # Answered the same whether this call queued the job or was handed one
      # already in flight, for the reason `TaskController` gives: a
      # double-click is one reply, and the same id back twice needs no branch.
      conn
      |> put_status(:accepted)
      |> put_view(json: RintoPMOWeb.V1.JobJSON)
      |> render(:show, job: Jobs.describe(job))
    end
  end

  @doc """
  Lists the topics that ever discussed this annotation.

  Derived from message refs rather than a join table, which is why an
  annotation can be under discussion in several topics at once without
  anything having to record that fact.
  """
  def conversations(conn, %{"document_id" => document_id, "id" => id}) do
    document = get_document!(document_id)
    annotation = annotations_context().get_annotation!(document, id)

    conversations =
      Utils.module(:conversations).list_conversations_for_ref("annotation", annotation.id)

    conn
    |> put_view(json: RintoPMOWeb.V1.ConversationJSON)
    |> render(:index, conversations: conversations)
  end

  defp annotation_filter(params) do
    with {:ok, filter} <- block_id_filter(params) do
      confirmed_filter(params, filter)
    end
  end

  defp confirmed_filter(params, filter) do
    case Map.get(params, "confirmed") do
      nil -> {:ok, filter}
      "true" -> {:ok, Map.put(filter, :confirmed, true)}
      "false" -> {:ok, Map.put(filter, :confirmed, false)}
      _invalid -> {:error, :bad_request, %{"confirmed" => ["is invalid"]}}
    end
  end

  defp block_id_filter(params) do
    case Map.get(params, "block_id") do
      nil ->
        {:ok, %{}}

      "none" ->
        {:ok, %{block_id: nil}}

      value ->
        case UUIDv7.cast(value) do
          {:ok, block_id} -> {:ok, %{block_id: block_id}}
          :error -> {:error, :bad_request, %{"block_id" => ["is invalid"]}}
        end
    end
  end

  defp get_document!(document_id), do: Utils.module(:documents).get_document!(document_id)

  defp annotations_context, do: Utils.module(:annotations)
end
