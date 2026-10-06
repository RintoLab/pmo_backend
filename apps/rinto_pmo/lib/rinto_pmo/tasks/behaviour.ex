defmodule RintoPMO.Tasks.Behaviour do
  @moduledoc false

  alias RintoPMO.Projects.Project
  alias RintoPMO.Tasks.Task

  @typedoc """
  Which of the two questions a model is being asked about a task.
  """
  @type estimation_kind :: :difficulty | :time

  @type filter :: %{
          optional(:status) => Task.status(),
          optional(:assignee_id) => UUIDv7.t() | nil,
          optional(:document_id) => UUIDv7.t(),
          optional(:repo_id) => UUIDv7.t(),
          optional(:live) => boolean(),
          optional(:overdue) => boolean(),
          optional(:priority) => pos_integer(),
          optional(:scheduled) => boolean(),
          optional(:sort) => sort()
        }

  @typedoc """
  Which order a list comes back in.

  `:oldest` is a backlog read from the front. `:plan` is the order the packer
  fills a week in -- priority, then the day the task was selected for, then
  age -- so the first row is the one the plan would reach next.
  """
  @type sort :: :oldest | :plan

  @type estimate :: %{
          optimistic: non_neg_integer(),
          likely: non_neg_integer(),
          pessimistic: non_neg_integer(),
          expected: non_neg_integer()
        }

  @type stats :: %{
          total: non_neg_integer(),
          unassigned: non_neg_integer(),
          overdue: non_neg_integer(),
          by_status: %{Task.status() => non_neg_integer()},
          by_assignee: [
            %{actor_id: UUIDv7.t(), counts: %{Task.status() => non_neg_integer()}}
          ],
          estimate: %{
            total: estimate() | nil,
            remaining: estimate() | nil,
            unestimated_tasks: non_neg_integer(),
            unestimated_tasks_remaining: non_neg_integer()
          },
          actual: %{
            total: non_neg_integer() | nil,
            unmeasured_tasks: non_neg_integer()
          }
        }

  @typedoc """
  A refusal the API layer turns into an `error` code rather than a field-level
  validation message. The shape `RintoPMOWeb.FallbackController` understands.
  """
  @type refusal :: {:error, atom()} | {:error, atom(), map()}

  @callback list_tasks(Project.t(), filter()) :: [Task.t()]
  @callback list_tasks(filter()) :: [Task.t()]
  @callback get_task!(UUIDv7.t()) :: Task.t()
  @callback create_task(Project.t(), map()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()
  @callback update_task(Task.t(), map()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

  @callback assign_task(Task.t(), term()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()
  @callback claim_task(Task.t(), term()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()
  @callback release_task(Task.t(), term()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

  @callback transition_task(Task.t(), Task.event(), term()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()
  @callback transition_task(Task.t(), Task.event(), term(), map()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

  @callback request_estimation(Task.t(), estimation_kind()) ::
              {:ok, Oban.Job.t()} | refusal()
  @callback run_estimation(integer(), UUIDv7.t(), estimation_kind()) ::
              :ok | {:cancel, String.t()}

  @callback sync_document(RintoPMO.Documents.Document.t(), map()) ::
              {:ok, map()} | {:error, Ecto.Changeset.t()} | refusal()

  @callback file_breakdown(RintoPMO.Documents.Document.t()) ::
              {:ok, [Task.t()]} | {:error, Ecto.Changeset.t()} | refusal()

  @callback delete_task(Task.t()) ::
              {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

  @callback project_stats(Project.t()) :: stats()

  @callback add_dependency(Task.t(), UUIDv7.t()) ::
              {:ok, RintoPMO.Tasks.Dependency.t()} | {:error, Ecto.Changeset.t()} | refusal()
  @callback remove_dependency(Task.t(), UUIDv7.t()) :: :ok
  @callback list_dependencies(Task.t()) :: [Task.t()]
  @callback list_dependents(Task.t()) :: [Task.t()]
  @callback list_edges(UUIDv7.t() | nil) ::
              [%{task_id: UUIDv7.t(), depends_on_id: UUIDv7.t()}]
end
