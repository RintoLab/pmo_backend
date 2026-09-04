defmodule RintoPMOWeb.V1.PromptShortcutControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.PromptShortcuts
  alias RintoPMO.PromptShortcuts.Presets

  @create %{"resource_type" => "document", "label" => "通读文档", "prompt" => "读一遍。"}

  defp shortcut(overrides \\ %{}) do
    {:ok, shortcut} = PromptShortcuts.create_shortcut(Map.merge(@create, overrides))
    shortcut
  end

  test "GET answers with the whole set and no filter", %{conn: conn} do
    shortcut(%{"label" => "一"})
    shortcut(%{"resource_type" => "annotation", "label" => "二"})

    conn = get(conn, ~p"/api/v1/prompt_shortcuts")

    # Both, including the one whose type does not match anything the caller
    # said: matching is the client's, on the list it is handed.
    assert [%{"label" => "一"}, %{"label" => "二"}] = json_response(conn, 200)["data"]
  end

  test "POST creates one and generates its key", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/prompt_shortcuts", @create)

    assert %{"key" => key, "label" => "通读文档", "default_prompt" => nil} =
             json_response(conn, 201)["data"]

    assert String.length(key) == 16
  end

  test "POST ignores a key the client tried to choose", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/prompt_shortcuts", Map.put(@create, "key", "chosen"))

    refute json_response(conn, 201)["data"]["key"] == "chosen"
  end

  test "POST refuses a resource type the reference scheme does not have", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/prompt_shortcuts", Map.put(@create, "resource_type", "note"))

    assert json_response(conn, 422)["details"]["resource_type"] == ["is invalid"]
  end

  test "PATCH edits the wording", %{conn: conn} do
    shortcut = shortcut()

    conn = patch(conn, ~p"/api/v1/prompt_shortcuts/#{shortcut.id}", %{"prompt" => "换一段"})

    assert json_response(conn, 200)["data"]["prompt"] == "换一段"
  end

  test "DELETE removes a preset too; running the seed task is the way back", %{conn: conn} do
    [{:created, preset} | _rest] = Presets.seed()

    conn = delete(conn, ~p"/api/v1/prompt_shortcuts/#{preset.id}")

    assert response(conn, 204)
    assert Enum.empty?(Enum.filter(PromptShortcuts.list_shortcuts(), &(&1.key == preset.key)))
  end

  test "POST reset puts a preset's prompt back", %{conn: conn} do
    [{:created, preset} | _rest] = Presets.seed()
    {:ok, _edited} = PromptShortcuts.update_shortcut(preset, %{"prompt" => "我自己写的"})

    conn = post(conn, ~p"/api/v1/prompt_shortcuts/#{preset.id}/reset")

    assert json_response(conn, 200)["data"]["prompt"] == preset.default_prompt
  end

  test "POST reset refuses a shortcut nobody shipped", %{conn: conn} do
    shortcut = shortcut()

    conn = post(conn, ~p"/api/v1/prompt_shortcuts/#{shortcut.id}/reset")

    assert %{"error" => "not_a_preset"} = json_response(conn, 422)
  end

  test "a client can tell an edited preset from an untouched one", %{conn: conn} do
    [{:created, preset} | _rest] = Presets.seed()
    {:ok, _edited} = PromptShortcuts.update_shortcut(preset, %{"prompt" => "我自己写的"})

    conn = get(conn, ~p"/api/v1/prompt_shortcuts")
    [row] = Enum.filter(json_response(conn, 200)["data"], &(&1["key"] == preset.key))

    # Both values are on the wire, so "has this been edited?" is a comparison
    # rather than a flag the server has to keep true.
    refute row["prompt"] == row["default_prompt"]
  end
end
