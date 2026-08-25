defmodule RintoPMO.ReferencesTest do
  use ExUnit.Case, async: true

  alias RintoPMO.References
  alias RintoPMO.References.Reference

  doctest References

  @id "01936f2a-1c4e-7c3a-9f1b-2d4e6a8b0c1d"

  describe "parse/1 and to_uri/1" do
    test "round-trips every addressable type" do
      uris = [
        "rinto://project/infra",
        "rinto://document/#{@id}",
        "rinto://block/#{@id}",
        "rinto://annotation/#{@id}",
        "rinto://proposal/#{@id}",
        "rinto://task/#{@id}",
        "rinto://conversation/#{@id}",
        "rinto://attachment/#{@id}"
      ]

      for uri <- uris do
        assert {:ok, reference} = References.parse(uri)
        assert References.to_uri(reference) == uri
      end
    end

    test "project is keyed by slug and everything else by id" do
      assert {:ok, project} = References.parse("rinto://project/infra")
      assert References.slug(project) == "infra"
      assert References.id(project) == nil

      assert {:ok, task} = References.parse("rinto://task/#{@id}")
      assert References.id(task) == @id
      assert References.slug(task) == nil
    end

    test "rejects anything that is not a rinto URI" do
      for uri <- ["https://example.com", "rinto:task/#{@id}", "task/#{@id}", ""] do
        assert References.parse(uri) == :error
      end
    end

    # `rinto://block:abc` parses as host "block" and port 193 under RFC 3986:
    # the identifier is truncated at the first non-digit and nothing complains.
    # Refusing it here is what keeps that from ever reaching the index.
    test "rejects a colon between the type and the key" do
      assert References.parse("rinto://block:#{@id}") == :error
      assert References.parse("rinto://block:0193abc") == :error
    end

    test "rejects a missing or extra segment" do
      for uri <- [
            "rinto://task",
            "rinto://task/",
            "rinto:///#{@id}",
            "rinto://document/#{@id}/block/#{@id}"
          ] do
        assert References.parse(uri) == :error
      end
    end

    test "rejects a known type whose key is not shaped like its identifier" do
      assert References.parse("rinto://task/not-a-uuid") == :error
      assert References.parse("rinto://project/not a slug") == :error
    end
  end

  describe "parse/1 with an unknown type" do
    test "succeeds, because an unknown type is a future rather than a mistake" do
      assert {:ok, %Reference{type: "intel", key: "anything"}} =
               References.parse("rinto://intel/anything")
    end

    test "round-trips, so text written today survives a build that learns the type" do
      uri = "rinto://intel/anything"
      assert {:ok, reference} = References.parse(uri)
      assert References.to_uri(reference) == uri
    end

    test "is not linkable, so it never reaches the index" do
      assert {:ok, reference} = References.parse("rinto://intel/anything")
      refute References.linkable?(reference)
      refute References.expandable?(reference)
      refute References.searchable?(reference)
      assert References.id(reference) == nil
      assert References.slug(reference) == nil
    end

    test "still refuses a malformed type" do
      assert References.parse("rinto://Intel/x") == :error
      assert References.parse("rinto://in-tel/x") == :error
      assert References.parse("rinto://9intel/x") == :error
    end
  end

  describe "types/0" do
    test "every linkable type is searchable, apart from the two stated exceptions" do
      unsearchable = ["proposal", "attachment"]

      for {type, capabilities} <- References.types(),
          capabilities.linkable,
          type not in unsearchable do
        assert capabilities.searchable, "#{type} can be linked to but never found"
      end

      for type <- unsearchable do
        refute References.types()[type].searchable
      end
    end

    test "a conversation may be linked to but not expanded" do
      conversation = References.types()["conversation"]
      assert conversation.linkable
      refute conversation.expandable
    end
  end

  describe "extract/1" do
    test "finds references in document order and numbers them from zero" do
      markdown = """
      见 [甲](rinto://task/#{@id}) 与 [乙](rinto://project/infra)。
      """

      assert {:ok, [first, second]} = References.extract(markdown)
      assert %{label: "甲", position: 0, reference: %Reference{type: "task"}} = first
      assert %{label: "乙", position: 1, reference: %Reference{type: "project"}} = second
    end

    test "does not find one inside a fenced code block" do
      markdown = """
      ## H

      ```
      [甲](rinto://task/#{@id})
      ```
      """

      assert {:ok, []} = References.extract(markdown)
    end

    test "does not find one inside an indented code block" do
      assert {:ok, []} = References.extract("## H\n\n    [甲](rinto://task/#{@id})\n")
    end

    test "finds ones nested in block quotes and list items" do
      markdown = """
      > [甲](rinto://task/#{@id})

      - [乙](rinto://project/infra)
      """

      assert {:ok, [%{label: "甲"}, %{label: "乙"}]} = References.extract(markdown)
    end

    # Deduplicating would renumber the positions and leave the two mentions
    # indistinguishable, which is the reason `MessageRef` does not dedupe either.
    test "reports one target twice when it is cited twice" do
      markdown = "[甲](rinto://task/#{@id}) 和 [又是甲](rinto://task/#{@id})"

      assert {:ok, [first, second]} = References.extract(markdown)
      assert first.reference == second.reference
      assert first.position == 0 and second.position == 1
      assert first.label == "甲" and second.label == "又是甲"
    end

    test "numbers references rather than links, so a foreign link does not leave a gap" do
      markdown = "[外链](https://example.test) 然后 [甲](rinto://task/#{@id})"

      assert {:ok, [%{label: "甲", position: 0}]} = References.extract(markdown)
    end

    test "keeps an unknown type, so the caller decides what to ignore" do
      assert {:ok, [%{reference: %Reference{type: "intel"}}]} =
               References.extract("[甲](rinto://intel/whatever)")
    end

    test "skips a malformed rinto URI entirely" do
      assert {:ok, []} = References.extract("[甲](rinto://task/not-a-uuid)")
    end

    test "reads the whole label, including its inline markup" do
      assert {:ok, [%{label: "很重要的甲"}]} =
               References.extract("[很**重要**的甲](rinto://task/#{@id})")
    end

    # autolink is on, so a bare URI becomes a link whose text is the URI. The
    # reference is real; its label is just the address rather than a phrase.
    test "finds a bare URI written in prose, labelled with itself" do
      uri = "rinto://task/#{@id}"

      assert {:ok, [%{label: ^uri, reference: %Reference{type: "task"}}]} =
               References.extract("裸写 #{uri} 结束")
    end

    test "finds nothing in a body without references" do
      assert {:ok, []} = References.extract("## H\n\n就是一段普通的话。")
    end
  end
end
