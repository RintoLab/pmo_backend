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

      timestamps(type: :utc_datetime_usec)
    end

    # One row per resource: re-projecting replaces rather than accumulates.
    create unique_index(:searchables, [:resource_type, :resource_id])
    create index(:searchables, [:project_id])
    create index(:searchables, [:document_id])
    create index(:searchables, [:resource_type])
  end
end
