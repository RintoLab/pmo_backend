defmodule RintoPMO.AI do
  @moduledoc """
  The local inference service: turning text into vectors, and ranking text
  against a question.

  ## Why this is not `RintoPMO.Agent`

  Everything under `RintoPMO.Agent` talks to pi, and which model pi calls is a
  runtime choice somebody makes by reading what came back -- a topic's own
  configuration, or a `RintoPMO.AIRoles` row. Neither of these calls is like
  that: an embedding model cannot be swapped without re-embedding everything
  stored under the old one, so it is a deployment fact rather than a
  preference. So this is configured as a service, under
  `config :rinto_pmo, :ai`, and takes no role.

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

  alias RintoPMO.AI.Passages

  @rerank_batch_size 100

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

  Long documents are scored in passages with the query repeated for each.
  A document keeps its best passage's score and its original index. Every
  passage participates, including the end of a long document.
  """
  @impl true
  @spec rerank(String.t(), [String.t()]) :: {:ok, [ranking()]} | error()
  def rerank(_query, []), do: {:ok, []}

  def rerank(query, documents) when is_binary(query) and is_list(documents) do
    passages = Passages.for_rerank(documents, query, config(:rerank_max_input_bytes))

    passages
    |> Enum.chunk_every(@rerank_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, ranked} ->
      case rank_passages(query, batch) do
        {:ok, rankings} -> {:cont, {:ok, rankings ++ ranked}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rankings} ->
        {:ok, rankings |> Enum.sort_by(&{-&1.score, &1.index}) |> Enum.uniq_by(& &1.index)}

      error ->
        error
    end
  end

  defp rank_passages(query, passages) do
    payload = %{
      model: model(:rerank_model),
      query: query,
      documents: Enum.map(passages, & &1.text)
    }

    with {:ok, body} <- post(:rerank_uri, payload) do
      {:ok,
       Enum.map(Map.get(body, "results", []), fn ranking ->
         passage = Enum.at(passages, ranking["index"])
         %{index: passage.index, score: ranking["relevance_score"]}
       end)}
    end
  end

  # The instruction is on the query alone, and its wording is a tuning knob
  # rather than a contract, so it lives in configuration.
  #
  # The frame around the wording is the opposite: it is copied from
  # Qwen3-Embedding's own `get_detailed_instruct`, down to there being **no
  # space after `Query:`**. That is not a typo to tidy up. The model was trained
  # on these exact characters, and a space is one more token of drift away from
  # what it was trained on -- silently, since a stray token does not fail, it
  # only makes the vector slightly worse.
  #
  # Changing any of this moves query vectors only. Stored document vectors are
  # embedded without an instruction and are unaffected, so there is nothing to
  # rebuild.
  defp instructed(query) do
    "Instruct: #{config(:query_instruction)}\nQuery:#{query}"
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
        |> Req.post(request_options(payload, token))
        |> case do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
          {:error, reason} -> {:error, {:transport, reason}}
        end
    end
  end

  defp request_options(payload, token) do
    [json: payload, auth: {:bearer, token}, receive_timeout: config(:timeout), retry: :transient]
    |> Keyword.merge(Application.get_env(:rinto_pmo, :ai_req_options, []))
  end

  defp model(key), do: config(key)

  defp config(key) do
    :rinto_pmo
    |> Application.fetch_env!(:ai)
    |> Keyword.fetch!(key)
  end
end
