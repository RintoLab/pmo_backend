defmodule RintoPMO.Repo.Migrations.AddEmbeddingsToResources do
  use Ecto.Migration

  # Everything findable except a block keeps its vector on its own row.
  #
  # The text each one stands for is a column on that same row, so the changeset
  # that rewrites the text is also the one that voids the vector -- no copy of
  # the content, no table to keep in step, and deletes and cascades that already
  # do the right thing.
  #
  # Blocks are the exception, and `block_embeddings` says why.
  #
  # ## Documents deliberately have none
  #
  # A document's findable content is its blocks, and every block hit carries the
  # document it belongs to. Embedding a title on top of that would add a weak
  # signal -- a title is a handful of characters -- to reach a document already
  # reachable. It would also have nowhere natural to live: `documents` has no
  # title column, the title being a field of each revision.
  #
  # ## Attachments deliberately have none, for the same reason
  #
  # An attachment's only text is its filename, which is shorter than a title
  # and was usually written by a camera rather than by a person describing
  # anything. The nearest neighbours of that vector are other filenames shaped
  # like it. An attachment is reached through the body that mentions it, and
  # `RintoPMO.Attachments.Attachment` says so.
  #
  # ## Replies are embedded on their own, not folded into their thread
  #
  # Concatenating a thread would re-embed the whole of it on every reply, over
  # text that keeps growing -- quadratic in a thread's length -- and would
  # dilute any single point in a long one. Embedded separately, a reply costs
  # one call and is found on its own terms; the thread is reassembled on the way
  # up, the same way a block hit ascends to its document.
  def change do
    for table <- [
          :annotations,
          :annotation_replies,
          :tasks,
          :projects,
          :conversations
        ] do
      alter table(table) do
        add :embedding, :vector, size: 1024
      end
    end
  end
end
