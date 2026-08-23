defmodule RintoPMO.AI do
  @moduledoc """
  The local inference service: turning text into vectors, and ranking text
  against a question.

  ## Why this is not `RintoPMO.Agent`

  Everything under `RintoPMO.Agent` talks to pi, and pi holds a conversation on
  behalf of an actor -- which is why those calls are routed by role
  (`title_actor`, `decomposition_actor`) rather than by address. Neither of
  these is a conversation and neither has anybody answering it: they are
  single-shot transformations. So this is configured as a service, under
  `config :rinto_pmo, :ai`, and takes no actor.

  ## Queries and documents are embedded differently

  Qwen3-Embedding is trained with an instruction on the query side and nothing
  on the document side. Embedding both the same way costs recall quality, and
  costs it **silently** -- nothing fails, results are merely worse. The
  asymmetry is therefore in the function names rather than in a flag: there is
  no way to call `embed_documents/1` on a query by accident.

  ## Failure is reported, not raised

  A vector that could not be computed leaves a row waiting rather than failing
  the write that produced it. The service being down means discovery lags; it
  does not mean a document cannot be saved. Callers are expected to leave the
  row alone and try again.
  """

  @typedoc """
  A vector, in the order its input was given.
  """
  @type embedding :: [float()]

  @typedoc """
  One reranked candidate: its position in the list handed in, and how well the
  reranker thought it answered the query.
  """
  @type ranking :: %{index: non_neg_integer(), score: float()}

  @type error :: {:error, {:http, pos_integer(), term()} | {:transport, term()} | :not_configured}

  defmodule Behaviour do
    @moduledoc false

    @callback embed_documents([String.t()]) ::
                {:ok, [RintoPMO.AI.embedding()]} | RintoPMO.AI.error()
    @callback embed_query(String.t()) :: {:ok, RintoPMO.AI.embedding()} | RintoPMO.AI.error()
    @callback rerank(String.t(), [String.t()]) ::
                {:ok, [RintoPMO.AI.ranking()]} | RintoPMO.AI.error()
  end

  @behaviour Behaviour

  @doc """
  Embeds text that is being stored, in the order given.

  Documents go in as they are: no instruction, no prefix. See the module
  documentation for why that is not symmetric with `embed_query/1`.
  """
  @impl true
  @spec embed_documents([String.t()]) :: {:ok, [embedding()]} | error()
  def embed_documents([]), do: {:ok, []}

  def embed_documents(texts) when is_list(texts) do
    with {:ok, body} <- post(:embedding_uri, %{model: model(:embedding_model), input: texts}) do
      {:ok, ordered_embeddings(body)}
    end
  end

  @doc """
  Embeds text that is being searched *with*, under the instruction the model
  expects.
  """
  @impl true
  @spec embed_query(String.t()) :: {:ok, embedding()} | error()
  def embed_query(query) when is_binary(query) do
    with {:ok, [embedding]} <- embed_documents([instructed(query)]) do
      {:ok, embedding}
    end
  end

  @doc """
  Scores `documents` against `query`, best first.

  Sorted here rather than trusted from the service: the endpoint is free to
  answer in input order, and a caller taking the first N of an unsorted list
  would be taking an arbitrary N.

  `index` refers to the position in the list handed in, which is how a caller
  gets back from a score to whatever it was scoring.
  """
  @impl true
  @spec rerank(String.t(), [String.t()]) :: {:ok, [ranking()]} | error()
  def rerank(_query, []), do: {:ok, []}

  def rerank(query, documents) when is_binary(query) and is_list(documents) do
    payload = %{model: model(:rerank_model), query: query, documents: documents}

    with {:ok, body} <- post(:rerank_uri, payload) do
      rankings =
        body
        |> Map.get("results", [])
        |> Enum.map(&%{index: &1["index"], score: &1["relevance_score"]})
        |> Enum.sort_by(& &1.score, :desc)

      {:ok, rankings}
    end
  end

  # The instruction is on the query alone, and its wording is a tuning knob
  # rather than a contract, so it lives in configuration.
  defp instructed(query) do
    "Instruct: #{config(:query_instruction)}\nQuery: #{query}"
  end

  # Answers arrive with an `index`, and nothing promises they arrive in it.
  defp ordered_embeddings(body) do
    body
    |> Map.get("data", [])
    |> Enum.sort_by(& &1["index"])
    |> Enum.map(& &1["embedding"])
  end

  defp post(uri_key, payload) do
    case config(:token) do
      nil ->
        {:error, :not_configured}

      token ->
        config(:base_url)
        |> Kernel.<>(config(uri_key))
        |> Req.post(
          json: payload,
          auth: {:bearer, token},
          receive_timeout: config(:timeout),
          retry: :transient
        )
        |> case do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
          {:error, reason} -> {:error, {:transport, reason}}
        end
    end
  end

  defp model(key), do: config(key)

  defp config(key) do
    :rinto_pmo
    |> Application.fetch_env!(:ai)
    |> Keyword.fetch!(key)
  end
end
