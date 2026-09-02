defmodule RintoPMO.Agent.CodexAuth.Parser do
  @moduledoc """
  Strict decoder for the JSONL emitted by the Pi OAuth helper.

  Credentials and intermediate authorization codes are deliberately not part
  of this protocol, so a successfully decoded value is always safe to retain
  in the authorization state machine.
  """

  @provider "openai-codex"

  @type event ::
          {:device_code,
           %{
             verification_url: String.t(),
             user_code: String.t(),
             expires_in_seconds: pos_integer()
           }}
          | :completed
          | {:error, String.t(), String.t()}

  @spec parse(binary()) :: {:ok, event()} | {:error, :malformed_jsonl}
  def parse(line) when is_binary(line) do
    with {:ok, value} <- JSON.decode(line),
         {:ok, event} <- validate(value) do
      {:ok, event}
    else
      _invalid -> {:error, :malformed_jsonl}
    end
  end

  defp validate(%{"type" => "device_code"} = event), do: validate_device_code(event)

  defp validate(%{"type" => "completed"} = event) do
    if event == %{"type" => "completed", "provider" => @provider, "success" => true},
      do: {:ok, :completed},
      else: {:error, :invalid_event}
  end

  defp validate(%{"type" => "error"} = event), do: validate_error(event)
  defp validate(_other), do: {:error, :invalid_event}

  defp validate_device_code(event) do
    with 5 <- map_size(event),
         @provider <- event["provider"],
         verification_url when is_binary(verification_url) and verification_url != "" <-
           event["verificationUrl"],
         user_code when is_binary(user_code) and user_code != "" <- event["userCode"],
         expires_in_seconds
         when is_integer(expires_in_seconds) and expires_in_seconds in 1..86_400 <-
           event["expiresInSeconds"] do
      validate_device_url(verification_url, user_code, expires_in_seconds)
    else
      _invalid -> {:error, :invalid_device_code}
    end
  end

  defp validate_device_url(verification_url, user_code, expires_in_seconds) do
    case URI.new(verification_url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok,
         {:device_code,
          %{
            verification_url: verification_url,
            user_code: user_code,
            expires_in_seconds: expires_in_seconds
          }}}

      _invalid_url ->
        {:error, :invalid_device_code}
    end
  end

  defp validate_error(event) do
    with 4 <- map_size(event),
         @provider <- event["provider"],
         code when is_binary(code) and code != "" <- event["code"],
         message when is_binary(message) and message != "" <- event["message"] do
      {:ok, {:error, code, message}}
    else
      _invalid -> {:error, :invalid_event}
    end
  end
end
