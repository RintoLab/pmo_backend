# Postgrex only decodes the types it was built knowing about, and `vector` is
# not one of them -- it arrives with the pgvector extension rather than with
# Postgres. Defining the type module here and pointing the repo at it (see
# `config/config.exs`) is what lets an embedding come back as a list of floats
# instead of raising on the way out of the database.
Postgrex.Types.define(
  RintoPMO.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
