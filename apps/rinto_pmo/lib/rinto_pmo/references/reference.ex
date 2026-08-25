defmodule RintoPMO.References.Reference do
  @moduledoc """
  One thing a body of text points at, parsed out of a `rinto://` URI.

  Two fields, because the URI has two segments: `rinto://{type}/{key}`. The
  struct mirrors the address rather than interpreting it, so a reference to a
  type this build has never heard of still round-trips through
  `RintoPMO.References.to_uri/1` unchanged.

  **Whether `key` is an id or a slug is the type's business, not this struct's.**
  The registry in `RintoPMO.References` answers that, and `id/1` and `slug/1`
  there read it. Carrying separate `id` and `slug` fields would mean deciding at
  parse time which one an unknown type uses, and there is no way to know.
  """

  @enforce_keys [:type, :key]
  defstruct [:type, :key]

  @type t :: %__MODULE__{type: String.t(), key: String.t()}
end
