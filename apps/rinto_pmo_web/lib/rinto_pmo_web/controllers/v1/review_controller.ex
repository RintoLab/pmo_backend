defmodule RintoPMOWeb.V1.ReviewController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Annotations
  alias RintoPMO.Jobs
  alias RintoPMO.Utils

  @doc """
  Asks the AI to read a set of documents end to end and leave what it finds.

  Answers with the *job*, the way asking for one reply does: the model call
  takes as long as it takes, and what a client does next is watch
  `document:{id}` for each document it is showing.

  A missing document is a `404` before anything is queued -- a review of a set
  that was not all there is not the review somebody asked for.
  """
  def create(conn, params) do
    with {:ok, document_ids} <- document_ids(params),
         {:ok, job} <- Utils.module(:annotations).request_review(documents(document_ids)) do
      # Answered the same whether this call queued the job or was handed one
      # already in flight, for the reason `AnnotationController.reply/2` gives:
      # a double-click is one review, and the same id back twice needs no
      # branch.
      conn
      |> put_status(:accepted)
      |> put_view(json: RintoPMOWeb.V1.JobJSON)
      |> render(:show, job: Jobs.describe(job))
    end
  end

  # The size is checked before the documents are loaded, not only in the
  # context: a list of five hundred ids would otherwise be five hundred queries
  # on its way to being refused. `RintoPMO.Annotations` holds the limit and
  # checks it again -- this is the cheap door, not the authority.
  defp document_ids(%{"document_ids" => ids}) when is_list(ids) do
    cond do
      not Enum.all?(ids, &is_binary/1) ->
        {:error, :bad_request, %{"document_ids" => ["must be a list of ids"]}}

      ids == [] ->
        {:error, :no_documents, %{}}

      length(Enum.uniq(ids)) > Annotations.max_documents() ->
        {:error, :too_many_documents, %{limit: Annotations.max_documents()}}

      true ->
        {:ok, Enum.uniq(ids)}
    end
  end

  defp document_ids(_params) do
    {:error, :bad_request, %{"document_ids" => ["is required"]}}
  end

  defp documents(document_ids) do
    context = Utils.module(:documents)

    Enum.map(document_ids, &context.get_document!/1)
  end
end
