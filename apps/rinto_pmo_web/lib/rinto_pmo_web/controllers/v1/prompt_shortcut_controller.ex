defmodule RintoPMOWeb.V1.PromptShortcutController do
  @moduledoc """
  The quick prompts offered beside the composer.

  `index` answers with all of them and takes no filter. Which ones to show
  follows from what the message being composed references, and that changes
  every time a mention is added or removed -- a server-side filter would be a
  request per keystroke against a dozen rows. The client holds the list and
  matches `resource_type` against the reference types in front of it.

  A management screen edits these, which is why the full set of verbs is here
  and not just `index`.
  """

  use RintoPMOWeb, :controller

  alias RintoPMO.PromptShortcuts

  def index(conn, _params) do
    render(conn, :index, shortcuts: PromptShortcuts.list_shortcuts())
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, shortcut: PromptShortcuts.get_shortcut!(id))
  end

  @doc """
  Creates a shortcut.

  `key` is not read from the request even if one is sent: it is generated, and
  a client that could choose one would be a client that could then recognise
  one. `default_prompt` is not read either -- a row created here is nobody's
  default.
  """
  def create(conn, params) do
    with {:ok, shortcut} <- PromptShortcuts.create_shortcut(params) do
      conn
      |> put_status(:created)
      |> render(:show, shortcut: shortcut)
    end
  end

  def update(conn, %{"id" => id} = params) do
    shortcut = PromptShortcuts.get_shortcut!(id)

    with {:ok, shortcut} <- PromptShortcuts.update_shortcut(shortcut, Map.delete(params, "id")) do
      render(conn, :show, shortcut: shortcut)
    end
  end

  def delete(conn, %{"id" => id}) do
    shortcut = PromptShortcuts.get_shortcut!(id)

    with {:ok, _shortcut} <- PromptShortcuts.delete_shortcut(shortcut) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  Puts a preset's prompt back to what the last deployment wrote.

  An action rather than `PATCH {"prompt": null}`, for the reason
  `AnnotationController.confirm/2` is one: it is a thing somebody does, not a
  field being given a value that happens to mean something else.

  `422 not_a_preset` for a shortcut somebody created themselves. Only the
  prompt moves -- a renamed button stays renamed.
  """
  def reset(conn, %{"id" => id}) do
    shortcut = PromptShortcuts.get_shortcut!(id)

    with {:ok, shortcut} <- PromptShortcuts.reset_shortcut(shortcut) do
      render(conn, :show, shortcut: shortcut)
    end
  end
end
