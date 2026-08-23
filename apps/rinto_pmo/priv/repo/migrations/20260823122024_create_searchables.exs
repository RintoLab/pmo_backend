defmodule RintoPMO.Repo.Migrations.CreateSearchables do
  use Ecto.Migration

  # One projection of everything that can be found, so that discovery is one
  # query over one shape rather than a union over eight tables that each
  # disagree about what a title is.
  #
  # Like `links`, this is an index rather than a truth: every row is derived
  # from a resource, and `mix rinto.index.rebuild` puts it back.
  #
  # ## No text-matching index here
  #
  # Retrieval over this table is semantic: an embedding of the query against an
  # embedding of each row. The one thing that would make a lexical index earn
  # its keep is somebody typing a fragment and expecting a prefix match, and
  # nobody in this system does that -- bodies are written by a model, which gets
  # a `rinto://` URI back from its search tool and pastes it. There is no
  # autocomplete for a person half-typing a title, because there is no person
  # writing the body.
  #
  # (Postgres could not have helped much anyway. Its tokenizers cannot segment
  # Chinese -- `to_tsvector('simple', '再部署到生产环境')` is a single token, and
  # searching for 部署 matches nothing -- and `zhparser` is not available here.
  # `pg_trgm` would have worked, but two GIN indexes maintained on every content
  # write, for a query nobody is making, is a cost without a consumer.)
  #
  # `ILIKE` still works unindexed if an exact-string lookup ever turns out to
  # matter, and an index can come back when there is a measurement asking for it.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    create table(:searchables, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # `block` is its own row rather than part of its document's. A block is an
      # independently addressable resource -- `rinto://block/{id}` -- so it is
      # independently findable, and a hit lands on the section that actually
      # says the thing rather than on a document that mentions it somewhere.
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false

      add :title, :text
      add :body, :text

      # Scope, which is the filter that matters first: finding the right thing
      # is usually a matter of looking in the right place.
      add :project_id, :binary_id, null: true

      # How a block hit reaches its document without a second lookup -- the same
      # second level `links` and the resolver already hand back.
      add :document_id, :binary_id, null: true

      # Carried rather than filtered out, so a caller decides whether archived
      # things belong in its list. Archiving is not deleting.
      add :archived, :boolean, null: false, default: false

      # 1024 because that is what Qwen3-Embedding-0.6B produces. Written as a
      # literal because it has to be: changing it rewrites the column, so it is
      # a decision to make once rather than a setting to leave open.
      #
      # Null means "needs embedding", and that is the whole of the state. A
      # separate `embedded_at` would be a column answering a question nobody
      # asks -- when a projection last changed is already `updated_at`, and what
      # the worker needs to know is only whether there is a vector or not.
      add :embedding, :vector, size: 1024

      timestamps(type: :utc_datetime_usec)
    end

    # One row per resource: re-projecting replaces rather than accumulates.
    create unique_index(:searchables, [:resource_type, :resource_id])
    create index(:searchables, [:project_id])
    create index(:searchables, [:document_id])
    create index(:searchables, [:resource_type])

    # No index on `embedding`, deliberately. pgvector's own guidance is to add
    # one when scans get slow, because HNSW and IVFFlat are approximate: they
    # trade recall for speed, and recall is the thing this layer exists to
    # provide. A few thousand rows at 1024 dimensions is a scan of a few
    # megabytes, which is faster and exact. `CREATE INDEX ... USING hnsw` is one
    # statement whenever a measurement asks for it.
  end
end
