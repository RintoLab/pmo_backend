defmodule RintoPMO.Documents.MarkdownTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Documents.Markdown

  doctest Markdown

  describe "split/1" do
    test "cuts at H1, H2 and H3" do
      assert {:ok, blocks} =
               Markdown.split("""
               # One

               first

               ## Two

               second

               ### Three

               third
               """)

      assert blocks == ["# One\n\nfirst", "## Two\n\nsecond", "### Three\n\nthird"]
    end

    test "keeps H4 and deeper with their section" do
      assert {:ok, ["### Three\n\n#### Four\n\ntext"]} =
               Markdown.split("### Three\n\n#### Four\n\ntext")
    end

    test "content before the first heading becomes its own block" do
      assert {:ok, ["preamble", "## One\n\nfirst"]} =
               Markdown.split("preamble\n\n## One\n\nfirst")
    end

    # The title is a separate field and is never read out of the body, so a
    # body may carry several H1s and each starts a block like any other heading.
    test "a body may carry several H1s" do
      assert {:ok, ["# A\n\na", "## Sub\n\ns", "# B\n\nb"]} =
               Markdown.split("# A\n\na\n\n## Sub\n\ns\n\n# B\n\nb")
    end

    test "a heading inside a fenced code block is content" do
      assert {:ok, [block]} =
               Markdown.split("""
               ## One

               ```elixir
               ## not a heading
               ```
               """)

      assert block == "## One\n\n```elixir\n## not a heading\n```"
    end

    test "a heading inside an indented code block is content" do
      assert {:ok, [block]} = Markdown.split("## One\n\n    ## not a heading\n")
      assert block =~ "## not a heading"
    end

    # Cutting there would leave both halves invalid: the list item would lose
    # its content and the heading would lose the list it belongs to.
    test "a heading nested inside a list item does not cut" do
      assert {:ok, [block]} = Markdown.split("- item\n\n  ## nested\n")
      assert block =~ "## nested"
    end

    # It stays one block, and the leading hash comes back escaped -- the
    # rendered document is unchanged, the bytes are not. That is the deal
    # round-tripping through the AST makes.
    test "a hash run with no space is not a heading" do
      assert {:ok, ["\\#notaheading"]} = Markdown.split("#notaheading")
    end

    test "blank input produces no blocks" do
      assert {:ok, []} = Markdown.split("")
      assert {:ok, []} = Markdown.split("\n\n   \n")
    end

    test "blank sections between headings cost nothing" do
      assert {:ok, ["## One", "## Two"]} = Markdown.split("## One\n\n\n\n## Two\n\n\n")
    end

    # Round-tripping through the AST normalises the body. It is worth pinning
    # the GFM constructs, because an extension left off on either side quietly
    # turns them back into escaped prose.
    test "keeps GFM tables, task lists and strikethrough intact" do
      assert {:ok, [block]} =
               Markdown.split("""
               ## Status

               | Item | Done |
               | --- | --- |
               | One | yes |

               - [x] shipped
               - [ ] ~~dropped~~
               """)

      assert block =~ "| Item | Done |"
      assert block =~ "- [x] shipped"
      assert block =~ "~~dropped~~"
    end

    test "keeps a code block fenced even without a language" do
      assert {:ok, ["## One\n\n```\ncode\n```"]} =
               Markdown.split("## One\n\n```\ncode\n```")
    end

    # The renderer needs the separator: without it the two lists merge when the
    # block is read back. Pinned so it is a known artifact rather than a
    # surprise in a block someone opens to edit.
    test "a list followed by another list keeps the separator the renderer needs" do
      assert {:ok, [block]} = Markdown.split("## One\n\n- a\n\n1. b")
      assert block == "## One\n\n- a\n\n<!-- end list -->\n\n1. b"
    end

    test "does not rewrap a long paragraph" do
      long = String.duplicate("word ", 60) |> String.trim()

      assert {:ok, [block]} = Markdown.split("## One\n\n#{long}")
      assert block == "## One\n\n#{long}"
    end
  end
end
