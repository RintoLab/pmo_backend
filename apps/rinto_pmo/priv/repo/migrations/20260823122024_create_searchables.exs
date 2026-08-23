defmodule RintoPMO.Repo.Migrations.CreateSearchables do
  use Ecto.Migration

  # One projection of everything that can be found, so that discovery is one
  # query over one shape rather than a union over eight tables that each
  # disagree about what a title is.
  #
  # Like `links`, this is an index rather than a truth: every row is derived
  # from a resource, and `mix rinto.index.rebuild` puts it back.
  #
  # ## Why trigrams and not `tsvector`
  #
  # Most of this system's content is Chinese, and Postgres' own tokenizers
  # cannot segment it. Measured on this server:
  #
  #     to_tsvector('simple', '先确认 systemd unit 再部署到生产环境')
  #     -- 'systemd':2 'unit':3 '先确认':1 '再部署到生产环境':4
  #
  # The whole clause is one token, because there are no spaces to split on, and
  # searching for 部署 matches nothing. `zhparser` and `pg_jieba` would fix that
  # and neither is available here. `pg_trgm` is, it is a core contrib module,
  # and character trigrams need no notion of a word -- which is exactly why they
  # work on a language that has no spaces.
  #
  # The cost is that `similarity()` is not a usable ranking signal for short CJK
  # queries: 部署 scores 0.0 against a string it plainly occurs in, because two
  # characters share too few trigrams with a long one. Ranking is therefore by
  # where the hit landed and how recent the row is -- explainable, which is what
  # this layer needs more than it needs cleverness.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"

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

    # `ILIKE '%...%'` is only usable at all because of these.
    create index(:searchables, ["title gin_trgm_ops"], using: :gin)
    create index(:searchables, ["body gin_trgm_ops"], using: :gin)
  end
end
