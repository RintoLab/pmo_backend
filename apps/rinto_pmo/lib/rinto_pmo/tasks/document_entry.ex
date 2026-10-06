defmodule RintoPMO.Tasks.DocumentEntry do
  @moduledoc "Stable correspondence between a task document item and its system task."
  use RintoPMO, :schema

  schema "task_document_entries" do
    belongs_to :document, RintoPMO.Documents.Document
    belongs_to :task, RintoPMO.Tasks.Task
    belongs_to :revision, RintoPMO.Documents.DocumentRevision
    field :key, :string
    field :baseline, :map
    timestamps()
  end
end
