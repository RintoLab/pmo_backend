defmodule RintoPMOWeb.V1.CodexAuthController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Agent.CodexAuth

  def status(conn, _params), do: json(conn, render_status(CodexAuth.status()))

  def start(conn, _params) do
    case CodexAuth.start_auth() do
      {:ok, status} -> json(conn, render_status(status))
      {:error, :auth_unavailable} -> {:error, :codex_auth_unavailable}
    end
  end

  def cancel(conn, _params) do
    case CodexAuth.cancel() do
      {:ok, status} -> json(conn, render_status(status))
      {:error, :not_pending} -> {:error, :codex_auth_not_pending}
    end
  end

  def logout(conn, _params) do
    case CodexAuth.logout() do
      {:ok, status} -> json(conn, render_status(status))
      {:error, :auth_unavailable} -> {:error, :codex_auth_unavailable}
    end
  end

  # These three names intentionally follow the Pi helper/device-flow vocabulary
  # requested by the client contract. The rest of the application uses atom
  # keys and lets JSON encode them as snake_case.
  defp render_status(status) do
    %{
      "provider" => status.provider,
      "authenticated" => status.authenticated,
      "status" => status.status
    }
    |> put_if("verificationUrl", status[:verification_url])
    |> put_if("userCode", status[:user_code])
    |> put_if("expiresInSeconds", status[:expires_in_seconds])
    |> put_if("error", status[:error])
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
