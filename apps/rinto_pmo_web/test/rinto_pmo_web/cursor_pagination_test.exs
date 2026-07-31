defmodule RintoPMOWeb.CursorPaginationTest do
  use ExUnit.Case, async: true

  alias RintoPMOWeb.CursorPagination

  describe "parse/1" do
    test "uses defaults when pagination parameters are absent" do
      assert {:ok, %{cursor: nil, limit: 50}} = CursorPagination.parse(%{})
    end

    test "parses a valid limit and cursor" do
      cursor = CursorPagination.encode_cursor(%{"version" => 12})

      assert {:ok, %{cursor: %{"version" => 12}, limit: 25}} =
               CursorPagination.parse(%{"cursor" => cursor, "limit" => "25"})
    end

    test "rejects invalid limits" do
      for limit <- ["0", "101", "1.5", "many"] do
        assert {:error, :bad_request,
                %{parameter: "limit", reason: "must be an integer between 1 and 100"}} =
                 CursorPagination.parse(%{"limit" => limit})
      end
    end

    test "rejects malformed and non-object cursors" do
      non_object_cursor = Base.url_encode64(Jason.encode!([1, 2]), padding: false)

      for cursor <- ["not-base64!", non_object_cursor] do
        assert {:error, :bad_request,
                %{
                  parameter: "cursor",
                  reason: "must be an opaque cursor returned by the API"
                }} = CursorPagination.parse(%{"cursor" => cursor})
      end
    end
  end

  describe "encode_cursor/1 and decode_cursor/1" do
    test "round trip JSON-compatible ordering fields" do
      cursor = CursorPagination.encode_cursor(%{inserted_at: "2026-07-30T10:00:00Z", sequence: 7})

      assert {:ok,
              %{
                "inserted_at" => "2026-07-30T10:00:00Z",
                "sequence" => 7
              }} = CursorPagination.decode_cursor(cursor)
    end
  end

  describe "build_page/3" do
    test "returns a cursor from the last visible record when another page exists" do
      entries = [
        %{sequence: 1, body: "one"},
        %{sequence: 2, body: "two"},
        %{sequence: 3, body: "three"}
      ]

      assert %{data: [first, second], next_cursor: next_cursor} =
               CursorPagination.build_page(entries, 2, &%{sequence: &1.sequence})

      assert first.sequence == 1
      assert second.sequence == 2
      assert {:ok, %{"sequence" => 2}} = CursorPagination.decode_cursor(next_cursor)
    end

    test "returns a nil cursor on the final page" do
      entries = [%{sequence: 1}, %{sequence: 2}]

      assert %{data: ^entries, next_cursor: nil} =
               CursorPagination.build_page(entries, 2, &%{sequence: &1.sequence})
    end
  end
end
