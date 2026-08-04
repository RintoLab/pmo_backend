defmodule RintoPMOWeb.V1.AnnotationController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Utils

  @statuses Map.new(Annotation.statuses(), &{Atom.to_string(&1), &1})

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

  def resolve(conn, %{"document_id" => document_id, "id" => id} = params) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)
    attrs = Map.take(params, ["resolved_by_revision_id"])

    with {:ok, annotation} <- context.resolve_annotation(annotation, attrs) do
      render(conn, :show, annotation: annotation)
    end
  end

  def dismiss(conn, %{"document_id" => document_id, "id" => id}) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)

    with {:ok, annotation} <- context.dismiss_annotation(annotation) do
      render(conn, :show, annotation: annotation)
    end
  end

  def reopen(conn, %{"document_id" => document_id, "id" => id}) do
    context = annotations_context()
    document = get_document!(document_id)
    annotation = context.get_annotation!(document, id)

    with {:ok, annotation} <- context.reopen_annotation(annotation) do
      render(conn, :show, annotation: annotation)
    end
  end

  defp annotation_filter(params) do
    with {:ok, filter} <- block_id_filter(params) do
      status_filter(params, filter)
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

  defp status_filter(params, filter) do
    case Map.get(params, "status") do
      nil ->
        {:ok, filter}

      value ->
        case Map.fetch(@statuses, value) do
          {:ok, status} -> {:ok, Map.put(filter, :status, status)}
          :error -> {:error, :bad_request, %{"status" => ["is invalid"]}}
        end
    end
  end

  defp get_document!(document_id), do: Utils.module(:documents).get_document!(document_id)

  defp annotations_context, do: Utils.module(:annotations)
end
