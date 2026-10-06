defmodule RintoPMOWeb.V1.TaskSchemaJSON do
  @moduledoc """
  What a task write has to look like, served rather than written down.

  `task create`, `task update` and `task split` each read a JSON file, and the
  only description of that file used to live in `openapi.yaml` -- a document
  the agent holding the CLI has never seen. So it guessed, and the guesses
  were reliably the same few: the flat `estimate_likely` column that is not
  castable, a `status` in a PATCH that is dropped without a word, a story
  point of 4.

  ## Why this exists when `doc schema` was refused

  A document body is Markdown; its shape is one sentence, and a subcommand
  restating it would be a subcommand restating one sentence (see
  `docs/ai-document-cli.md`). A task is twenty-odd fields carrying enums, a
  ceiling, and rules that hold *between* fields -- all three estimate points
  or none, ordered, under a day. That is a shape worth serving.

  ## Why the server serves it

  The numbers come from `RintoPMO.Tasks.Task` as the request is answered, so a
  schema that says 480 minutes is saying what the packer will actually
  enforce. A client carrying its own copy would teach last release's rules to
  an agent with no way to notice, and the CLI self-updates on its own
  schedule.

  ## What it does not claim

  `additionalProperties: false` is an instruction to whoever writes the file,
  not a description of the server: unlisted keys are *ignored*, not refused,
  because the changeset casts a whitelist. That is the trap this schema exists
  to spell out, and the `update` shape says so in as many words -- a PATCH
  carrying `status` succeeds and changes nothing. The `sync` shape is stricter:
  it rejects unlisted fields so execution data cannot be silently discarded.
  """

  alias RintoPMO.Tasks.Task

  @dialect "https://json-schema.org/draft/2020-12/schema"

  @doc """
  The four shapes a task write can take, keyed by the command that reads them.

  All of them in one response rather than one endpoint each: the answer is a
  few hundred bytes of constant, and an agent that has to learn `create` today
  will need `split` in the same sitting.
  """
  def show(_assigns) do
    %{data: flow(%{create: create(), update: update(), split: split(), sync: sync()})}
  end

  # Every `description` is written as paragraphs above and flowed on the way
  # out. The client pretty-prints this JSON, so a hard newline inside a string
  # arrives as a literal `\\n` in the middle of a sentence; the blank line
  # between paragraphs is the one break worth keeping.
  #
  # Only the atom key is rewritten. An example's own `"description"` is a value
  # somebody would copy, not prose about the API.
  defp flow(%{} = map) do
    Map.new(map, fn
      {:description, prose} when is_binary(prose) -> {:description, reflow(prose)}
      {key, value} -> {key, flow(value)}
    end)
  end

  defp flow(list) when is_list(list), do: Enum.map(list, &flow/1)
  defp flow(value), do: value

  defp reflow(prose) do
    prose
    |> String.trim()
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map_join("\n\n", &(&1 |> String.split() |> Enum.join(" ")))
  end

  defp create do
    %{
      "$schema" => @dialect,
      title: "TaskCreateInput",
      description: """
      The body of `POST /projects/{slug}/tasks`, which is the file
      `rinto-pmo task create --input FILE` reads. `title`, `requirement_id` and `repo_id` are required. Priority is inherited from that leaf requirement.
      """,
      type: "object",
      required: ["title", "requirement_id", "repo_id"],
      additionalProperties: false,
      properties:
        Map.merge(common_properties(), %{
          requirement_id: %{
            type: "string",
            format: "uuid",
            description: "An open leaf requirement in this project. Immutable after creation."
          },
          kind: %{
            type: "string",
            enum: Enum.map(Task.kinds(), &Atom.to_string/1),
            default: "work",
            description: """
            A job (`work`) or the cover over a pile of them (`summary`). This
            is the only place it is settable; afterwards it moves through
            `task split` alone. A cover holds nothing that measures work --
            assignee, planned_start_on, estimate, difficulty and
            actual_minutes are all refused on one, because it takes those from
            its children.
            """
          }
        }),
      examples: [
        %{
          "title" => "Wire the estimator into the task board",
          "description" => "Reuse the job channel the decomposer already publishes on.",
          "requirement_id" => "01990000-0000-7000-8000-000000000011",
          "repo_id" => "01990000-0000-7000-8000-000000000021",
          "planned_start_on" => "2026-09-01",
          "estimate" => %{"optimistic" => 60, "likely" => 120, "pessimistic" => 240},
          "difficulty" => 5
        }
      ]
    }
  end

  defp sync do
    %{
      "$schema" => @dialect,
      title: "TaskSyncInput",
      description:
        "Read an adopted task document with doc show, then submit the structured work with task sync DOCUMENT_ID --input FILE. Same-document keys must stay stable across retries and revisions. Markdown layout is not parsed. Only title, description and Repo may change; manual edits and started work cause an atomic conflict. Omitted tasks and execution fields are preserved. A key cannot change its content within the same source revision. Deleting an imported task leaves a tombstone; use a new key for replacement work. This operation does not create or remove dependencies.",
      type: "object",
      required: ["base_revision_id", "tasks"],
      additionalProperties: false,
      properties: %{
        base_revision_id: %{
          type: "string",
          format: "uuid",
          description:
            "The exact latest revision read, never fetch a newer ID without re-reading its contents."
        },
        tasks: %{
          type: "array",
          minItems: 1,
          maxItems: 200,
          items: %{
            type: "object",
            required: ["key", "title", "repo_id"],
            additionalProperties: false,
            properties:
              Map.put(Map.take(common_properties(), [:title, :description, :repo_id]), :key, %{
                type: "string",
                pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
                description:
                  "Stable identifier within this task document, for example T001. Never renumber existing items."
              })
          }
        }
      },
      examples: [
        %{
          "base_revision_id" => "01990000-0000-7000-8000-000000000031",
          "tasks" => [
            %{
              "key" => "T001",
              "title" => "Implement the verification endpoint",
              "repo_id" => "01990000-0000-7000-8000-000000000021",
              "description" =>
                "Implement the behavior and acceptance criteria in the task document."
            }
          ]
        }
      ]
    }
  end

  defp update do
    %{
      "$schema" => @dialect,
      title: "TaskUpdateInput",
      description: """
      The body of `PATCH /tasks/{id}`, which is the file
      `rinto-pmo task update --input FILE` reads. Every field is optional;
      what is absent is left alone, and an explicit `null` clears.

      `status` and `kind` are not here. Status moves only through the events
      -- `task start`, `task complete`, `task cancel`, `task reopen` -- and
      `kind` only through `task split`; neither belongs in the same request as
      an edit of the wording.

      `priority` and `requirement_id` writes are refused. Other unlisted keys are ignored. A
      PATCH carrying `status: "done"` answers 200 and changes nothing, so read
      the task back rather than reading the status code as agreement.
      """,
      type: "object",
      additionalProperties: false,
      properties: common_properties(),
      examples: [%{"planned_start_on" => nil}]
    }
  end

  defp split do
    %{
      "$schema" => @dialect,
      title: "TaskSplitInput",
      description: """
      The body of `POST /tasks/{id}/split`, which is the file
      `rinto-pmo task split --input FILE` reads. Omit the file entirely to
      turn a job into an empty cover and file its children later.

      The split rewrites the task it is given: a cover holds no assignee, no
      clocks, no estimate, no difficulty, no actual minutes and no
      planned_start_on, so all of those are dropped, and its status becomes
      the rollup over whatever children it now has. Title, description,
      requirement and its place in the tree stay; priority is inherited.
      Children cannot override requirement_id or parent_id. Each child inherits repo_id unless it explicitly selects another repository in the same project.
      """,
      type: "object",
      additionalProperties: false,
      properties: %{
        children: %{
          type: "array",
          description: """
          The jobs to file under the new cover, in order. Each is created as
          `kind: "work"` with its parent already set to the cover, which is
          why a child carries neither field. A child that is itself a pile is
          split in turn.

          A refusal names the child it came from: `details.child` is its index
          in this array.
          """,
          items: %{
            type: "object",
            required: ["title"],
            additionalProperties: false,
            properties: Map.drop(common_properties(), [:parent_id])
          }
        }
      },
      examples: [
        %{
          "children" => [
            %{
              "title" => "Add the pgvector column and its index",
              "estimate" => %{"optimistic" => 30, "likely" => 60, "pessimistic" => 120}
            },
            %{"title" => "Backfill embeddings for existing tasks"}
          ]
        }
      ]
    }
  end

  # The fields every write shares. `create` adds `kind`; the children of a
  # split lose `parent_id`, which the split itself has already answered.
  defp common_properties do
    %{
      title: %{
        type: "string",
        minLength: 1,
        maxLength: 255,
        description: "One line saying what the work is."
      },
      description: %{
        type: ["string", "null"],
        description: """
        The detail, as Markdown. It may carry `rinto://` addresses, and one
        that resolves to nothing refuses the whole write with
        `unresolvable_references` -- so paste addresses from `search` or from
        the call that created the target rather than typing a UUID from
        memory.
        """
      },
      repo_id: %{
        type: "string",
        format: "uuid",
        description:
          "The single repository this task belongs to. Must belong to the same project. Cannot be cleared."
      },
      document_id: %{
        type: ["string", "null"],
        format: "uuid",
        description: """
        The document this work implements. A pointer at a spec, not ownership:
        deleting the document leaves the task standing.
        """
      },
      parent_id: %{
        type: ["string", "null"],
        format: "uuid",
        description: """
        The cover this sits under. It has to be a `summary` in the same
        project, and it may not sit underneath this task -- that is refused as
        `dependency_cycle`. Moving the last child out of a cover demotes that
        cover back to `work`, so re-read the tree after a structural move.
        """
      },
      assignee_id: %{
        type: ["string", "null"],
        format: "uuid",
        description: """
        Who owns the work. `task claim` and `task assign` are the usual ways
        in; this field is here so a breakdown can hand work out as it files
        it. Refused on a summary node.
        """
      },
      due_on: %{
        type: ["string", "null"],
        format: "date",
        description: """
        A deadline, and only that. It does not put the task in a week --
        `planned_start_on` is the field that does.
        """
      },
      planned_start_on: %{
        type: ["string", "null"],
        format: "date",
        description: """
        The earliest day this may be worked, and at the same time the whole of
        "put it in that iteration": the iteration is the week this day falls
        in. Null is the backlog, and there is no backlog status.

        It is not where the task lands -- the board fills each day's capacity
        in priority order and answers that. Refused on a summary node.
        Refused as `dependency_out_of_order` when the move would put the task
        ahead of live work it waits for, or push a prerequisite past something
        waiting on it.
        """
      },
      estimate: %{
        type: ["object", "null"],
        required: ["optimistic", "likely", "pessimistic"],
        additionalProperties: false,
        properties: estimate_properties(),
        description: """
        A three-point estimate in minutes, all three or null to clear: a
        half-given three-point estimate has no expected value, so it is not a
        smaller estimate but a broken one. Must satisfy
        `optimistic <= likely <= pessimistic`, and no point may exceed
        #{Task.estimate_ceiling()} minutes -- one working day. A job that
        wants more was not broken down far enough, and `task split` is the
        answer rather than a wider day.

        What is being estimated is what the task costs the person planning it,
        not how long it takes to happen: work handed to an agent still costs
        the waiting and the reviewing.

        The flat `estimate_optimistic` / `estimate_likely` /
        `estimate_pessimistic` columns are never writable. Sending them does
        nothing at all -- they are dropped before the changeset sees them, so
        no error comes back either.
        """
      },
      difficulty: %{
        type: ["integer", "null"],
        enum: Task.difficulties(),
        description: """
        A Fibonacci story point, or null to clear. It rates the work rather
        than timing it -- the estimate is the duration, and this is the knob
        later estimates are calibrated against. Anything off the ladder is
        refused as `invalid_difficulty`, and so is any value at all on a
        summary node.
        """
      },
      actual_minutes: %{
        type: ["integer", "null"],
        minimum: 0,
        description: """
        How long the work actually took, in minutes. When completion finds
        neither a supplied nor a stored value, it derives whole minutes from
        `started_at`, rounding a partial minute up. An explicit value takes
        precedence. Reopening clears the duration. Refused on a summary node,
        which sums its children instead.
        """
      }
    }
  end

  defp estimate_properties do
    %{
      optimistic: %{type: "integer", minimum: 0, maximum: Task.estimate_ceiling()},
      likely: %{type: "integer", minimum: 0, maximum: Task.estimate_ceiling()},
      pessimistic: %{type: "integer", minimum: 0, maximum: Task.estimate_ceiling()}
    }
  end
end
