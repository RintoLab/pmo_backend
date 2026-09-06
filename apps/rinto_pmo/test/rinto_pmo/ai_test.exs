defmodule RintoPMO.AITest do
  use ExUnit.Case, async: true

  alias RintoPMO.AI

  setup {Req.Test, :verify_on_exit!}

  defp request(conn) do
    assert conn.request_path == "/v1/rerank"
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  defp scores(conn, documents, score) do
    results =
      documents
      |> Enum.with_index()
      |> Enum.map(fn {text, index} -> %{index: index, relevance_score: score.(text)} end)

    Req.Test.json(conn, %{results: results})
  end

  test "short documents keep their text and original indices after sorting" do
    Req.Test.expect(AI, fn conn ->
      {body, conn} = request(conn)
      assert body["query"] == "编译器"
      assert body["documents"] == ["first", "second"]
      scores(conn, body["documents"], fn text -> if text == "second", do: 0.9, else: 0.2 end)
    end)

    assert {:ok, [%{index: 1, score: 0.9}, %{index: 0, score: 0.2}]} =
             AI.rerank("编译器", ["first", "second"])
  end

  test "a long Chinese block is scored through its tail and returns one original index" do
    query = "编译器纯函数 context 编辑器构造 Runner 解释器分层"
    document = String.duplicate("编译器🙂é", 1500) <> "尾部匹配"
    budget = Application.fetch_env!(:rinto_pmo, :ai)[:rerank_max_input_bytes]

    Req.Test.expect(AI, fn conn ->
      {body, conn} = request(conn)
      assert body["query"] == query
      assert hd(body["documents"]) == "first"
      assert List.last(body["documents"]) == "last"
      passages = body["documents"] |> Enum.drop(1) |> Enum.drop(-1)
      assert length(passages) > 1
      assert Enum.join(passages) == document

      for passage <- passages do
        assert String.valid?(passage)
        assert byte_size(passage) + byte_size(query) <= budget
      end

      scores(conn, body["documents"], fn text ->
        cond do
          String.ends_with?(text, "尾部匹配") -> 0.95
          text == "last" -> 0.5
          true -> 0.1
        end
      end)
    end)

    assert {:ok, [%{index: 1, score: 0.95}, %{index: 2, score: 0.5}, %{index: 0, score: 0.1}]} =
             AI.rerank(query, ["first", document, "last"])
  end

  test "indices and global ordering survive several HTTP batches" do
    documents = Enum.map(0..204, &Integer.to_string/1)

    Req.Test.expect(AI, 3, fn conn ->
      {body, conn} = request(conn)
      assert length(body["documents"]) <= 100
      scores(conn, body["documents"], &(String.to_integer(&1) / 1000))
    end)

    assert {:ok, ranked} = AI.rerank("query", documents)
    assert Enum.map(ranked, & &1.index) == Enum.to_list(204..0//-1)
  end

  test "a failure in a later batch fails the whole rerank" do
    Req.Test.expect(AI, fn conn ->
      {body, conn} = request(conn)
      scores(conn, body["documents"], fn _text -> 0.5 end)
    end)

    error = %{"error" => %{"message" => "input too long"}}

    Req.Test.expect(AI, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(error)
    end)

    assert {:error, {:http, 400, ^error}} = AI.rerank("query", List.duplicate("text", 101))
  end

  test "passages of the same document merge across HTTP batches" do
    document = String.duplicate("a", 8000) <> "tail"

    Req.Test.expect(AI, 2, fn conn ->
      {body, conn} = request(conn)

      scores(conn, body["documents"], fn text ->
        if String.ends_with?(text, "tail"), do: 0.9, else: 0.2
      end)
    end)

    assert {:ok, [%{index: 99, score: 0.9} | rest]} =
             AI.rerank("query", List.duplicate("other", 99) ++ [document])

    assert Enum.map(rest, & &1.index) == Enum.to_list(0..98)
  end

  test "an oversized query is preserved for the service to validate" do
    query = String.duplicate("query", 2000)
    error = %{"error" => %{"message" => "query too long"}}

    Req.Test.expect(AI, fn conn ->
      {body, conn} = request(conn)
      assert body["query"] == query
      assert body["documents"] == ["text"]
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(error)
    end)

    assert {:error, {:http, 400, ^error}} = AI.rerank(query, ["text"])
  end

  test "no candidates need no HTTP call" do
    assert AI.rerank("query", []) == {:ok, []}
  end
end
