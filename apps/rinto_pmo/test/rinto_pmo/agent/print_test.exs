defmodule RintoPMO.Agent.PrintTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Agent.Print

  describe "system_prompt/2" do
    # The order is the design: the role says what to pay attention to, the
    # built-in contract keeps the last word on what an answer looks like.
    test "puts the standing instruction in front of the contract" do
      assert Print.system_prompt("Reply with JSON.", "Prefer the ticket number.") ==
               "Prefer the ticket number.\n\nReply with JSON."
    end

    test "hands back the contract untouched when nothing was written" do
      assert Print.system_prompt("Reply with JSON.", nil) == "Reply with JSON."
      assert Print.system_prompt("Reply with JSON.", "") == "Reply with JSON."
    end

    # A textarea somebody typed a newline into and left is nothing written, not
    # a blank heading to paste above the contract.
    test "treats whitespace as nothing written" do
      assert Print.system_prompt("Reply with JSON.", "  \n\t ") == "Reply with JSON."
    end

    test "trims what it does keep, so the join is exactly one blank line" do
      assert Print.system_prompt("Reply with JSON.", "\n  Be brief.  \n\n") ==
               "Be brief.\n\nReply with JSON."
    end
  end
end
