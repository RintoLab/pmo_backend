defmodule RintoPMO.Agent.CodexAuth.ParserTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Agent.CodexAuth.Parser

  test "parses a device code without admitting credential fields" do
    line =
      JSON.encode!(%{
        type: "device_code",
        provider: "openai-codex",
        verificationUrl: "https://auth.openai.com/codex/device",
        userCode: "ABCD-1234",
        expiresInSeconds: 900
      })

    assert {:ok,
            {:device_code,
             %{
               verification_url: "https://auth.openai.com/codex/device",
               user_code: "ABCD-1234",
               expires_in_seconds: 900
             }}} = Parser.parse(line)
  end

  test "parses completed and error events" do
    assert {:ok, :completed} =
             Parser.parse(~s({"type":"completed","provider":"openai-codex","success":true}))

    assert {:ok, {:error, "auth_failed", "Authorization failed."}} =
             Parser.parse(
               ~s({"type":"error","provider":"openai-codex","code":"auth_failed","message":"Authorization failed."})
             )
  end

  test "rejects malformed JSONL, unknown providers, invalid URLs, and extra event shapes" do
    assert {:error, :malformed_jsonl} = Parser.parse("not json")

    assert {:error, :malformed_jsonl} =
             Parser.parse(~s({"type":"completed","provider":"another-provider","success":true}))

    assert {:error, :malformed_jsonl} =
             Parser.parse(
               ~s({"type":"device_code","provider":"openai-codex","verificationUrl":"javascript:bad","userCode":"A","expiresInSeconds":1})
             )

    assert {:error, :malformed_jsonl} =
             Parser.parse(~s({"type":"token","provider":"openai-codex","access":"secret"}))

    assert {:error, :malformed_jsonl} =
             Parser.parse(
               ~s({"type":"completed","provider":"openai-codex","success":true,"access":"must-not-cross-protocol"})
             )
  end
end
