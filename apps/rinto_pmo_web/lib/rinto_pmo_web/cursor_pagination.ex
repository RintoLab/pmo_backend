defmodule RintoPMOWeb.CursorPagination do
  @moduledoc """
  Shared parsing and response helpers for cursor-paginated API endpoints.

  Callers must query in a stable domain order and fetch `limit + 1` records.
  The cursor callback must use that domain order; IDs must not be introduced as
  an implicit ordering key.
  """

  @default_limit 50
  @max_limit 100

  @type cursor_data :: %{optional(String.t() | atom()) => term()}
  @type parsed_params :: %{cursor: map() | nil, limit: pos_integer()}
  @type error :: {:error, :bad_request, %{parameter: String.t(), reason: String.t()}}

  @doc """
  Parses `cursor` and `limit` query parameters.

  The default limit is #{@default_limit}; accepted limits are between 1 and
  #{@max_limit}. Invalid input is returned in the shape understood by
  `RintoPMOWeb.FallbackController`.
  """
  @spec parse(map()) :: {:ok, parsed_params()} | error()
  def parse(params) when is_map(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, cursor} <- parse_cursor(Map.get(params, "cursor")) do
      {:ok, %{cursor: cursor, limit: limit}}
    end
  end

  @doc "Encodes JSON-compatible cursor data as an opaque URL-safe value."
  @spec encode_cursor(cursor_data()) :: String.t()
  def encode_cursor(cursor_data) when is_map(cursor_data) do
    cursor_data
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc "Decodes a cursor previously returned by `encode_cursor/1`."
  @spec decode_cursor(String.t()) :: {:ok, map()} | {:error, :invalid_cursor}
  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, cursor_data} when is_map(cursor_data) <- Jason.decode(json) do
      {:ok, cursor_data}
    else
      _error -> {:error, :invalid_cursor}
    end
  end

  @doc """
  Builds a response page from at most `limit + 1` ordered records.

  `cursor_builder` receives the final returned record only when another page
  exists. The resulting map can be passed directly to a JSON response.
  """
  @spec build_page([item], pos_integer(), (item -> cursor_data())) :: %{
          data: [item],
          next_cursor: String.t() | nil
        }
        when item: term()
  def build_page(entries, limit, cursor_builder)
      when is_list(entries) and is_integer(limit) and limit > 0 and
             is_function(cursor_builder, 1) do
    {data, remaining} = Enum.split(entries, limit)

    next_cursor =
      case remaining do
        [] -> nil
        [_extra | _rest] -> data |> List.last() |> cursor_builder.() |> encode_cursor()
      end

    %{data: data, next_cursor: next_cursor}
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(limit) when is_integer(limit) do
    validate_limit(limit)
  end

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed_limit, ""} -> validate_limit(parsed_limit)
      _invalid -> invalid_limit()
    end
  end

  defp parse_limit(_limit), do: invalid_limit()

  defp validate_limit(limit) when limit in 1..@max_limit, do: {:ok, limit}
  defp validate_limit(_limit), do: invalid_limit()

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor) when is_binary(cursor) do
    case decode_cursor(cursor) do
      {:ok, cursor_data} -> {:ok, cursor_data}
      {:error, :invalid_cursor} -> invalid_cursor()
    end
  end

  defp parse_cursor(_cursor), do: invalid_cursor()

  defp invalid_limit do
    {:error, :bad_request,
     %{
       parameter: "limit",
       reason: "must be an integer between 1 and #{@max_limit}"
     }}
  end

  defp invalid_cursor do
    {:error, :bad_request,
     %{
       parameter: "cursor",
       reason: "must be an opaque cursor returned by the API"
     }}
  end
end
