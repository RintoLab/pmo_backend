defmodule RintoPMO.Tasks.BreakdownTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.Markdown
  alias RintoPMO.Tasks.Breakdown

  describe "parse/1" do
    test "reads a chunk and the tasks under it" do
      assert {:ok, [chunk]} =
               parse("""
               ## 灰度发布

               分两步走。

               ### 接入十分之一流量

               先切 10%，观察一个完整工作日。

               - 错误率不高于基线

               ### 加监控看板

               错误率曲线、延迟分位数各一块。
               """)

      assert chunk.title == "灰度发布"
      assert chunk.description == "分两步走。"

      assert [first, second] = chunk.tasks
      assert first.title == "接入十分之一流量"
      assert first.description == "先切 10%，观察一个完整工作日。\n\n- 错误率不高于基线"
      assert second.title == "加监控看板"
      assert second.description == "错误率曲线、延迟分位数各一块。"
    end

    # Said that way rather than left for the parser to infer from a summary and
    # a task that happen to share a title.
    test "a chunk with no tasks is one piece of work" do
      assert {:ok, [chunk]} =
               parse("""
               ## 把回滚做成一个开关

               现在要手动改配置再重启。
               """)

      assert chunk.title == "把回滚做成一个开关"
      assert chunk.description == "现在要手动改配置再重启。"
      assert chunk.tasks == []
    end

    test "keeps chunks and their tasks in the order they were written" do
      assert {:ok, [first, second]} =
               parse("""
               ## 一

               ### 一之一

               ### 一之二

               ## 二

               ### 二之一
               """)

      assert first.title == "一"
      assert Enum.map(first.tasks, & &1.title) == ["一之一", "一之二"]
      assert second.title == "二"
      assert Enum.map(second.tasks, & &1.title) == ["二之一"]
    end

    # The reason titles come from the AST: block bodies are Markdown rendered
    # back from a parse, so this heading is stored `建 annotation\\_replies 表`.
    test "takes the title without the escaping the stored Markdown carries" do
      assert {:ok, [chunk]} = parse("## 组\n\n### 建 annotation_replies 表\n")

      assert [task] = chunk.tasks
      assert task.title == "建 annotation_replies 表"
    end

    test "reads the words out of a title that carries inline code" do
      assert {:ok, [chunk]} = parse("## 组\n\n### 给 `document_id` 加索引\n")

      assert [task] = chunk.tasks
      assert task.title == "给 document_id 加索引"
    end

    test "a heading with nothing under it has no description" do
      assert {:ok, [chunk]} = parse("## 组\n\n### 一件活\n")

      assert chunk.description == nil
      assert [%{description: nil}] = chunk.tasks
    end

    # `####` and deeper are not cut by the splitter, so they stay where they
    # were written and read as part of the description.
    test "keeps a deeper heading inside the description it was written in" do
      assert {:ok, [chunk]} =
               parse("""
               ## 组

               ### 一件活

               #### 注意

               有个坑。
               """)

      assert [task] = chunk.tasks
      assert task.title == "一件活"
      assert task.description =~ "#### 注意"
      assert task.description =~ "有个坑。"
    end

    # Somebody is free to say what the breakdown is at the top of it.
    test "ignores a preamble above the first chunk" do
      assert {:ok, [chunk]} =
               parse("""
               这是下面这份方案拆出来的活。

               ## 组

               ### 一件活
               """)

      assert chunk.title == "组"
      assert [%{title: "一件活"}] = chunk.tasks
    end
  end

  describe "what it refuses" do
    # Guessing a chunk would file work under a heading nobody wrote.
    test "a task standing above the first chunk" do
      assert {:error, :task_before_chunk, %{}} = parse("### 无家可归\n\n## 组\n")
    end

    test "a document with no headings at all" do
      assert {:error, :no_chunks, %{}} = parse("就是一段话，没有任何标题。\n")
    end

    test "an empty document" do
      assert {:error, :no_chunks, %{}} = Breakdown.parse([])
    end
  end

  # Through the real splitter, so the blocks are shaped exactly as they are
  # stored -- normalisation, escaping and all.
  defp parse(markdown) do
    {:ok, contents} = Markdown.split(markdown)

    contents
    |> Enum.map(&%DocumentBlock{content: &1})
    |> Breakdown.parse()
  end
end
