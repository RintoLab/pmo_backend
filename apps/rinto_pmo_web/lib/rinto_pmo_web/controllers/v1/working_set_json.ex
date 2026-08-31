defmodule RintoPMOWeb.V1.WorkingSetJSON do
  @moduledoc """
  What one topic has standing, as the screen that reviews it needs it.

  Grouped by document rather than flat, for the reason `BacklinkJSON` gives:
  the screen reads as sections -- one panel per document, each with its own
  commit -- and a client that wanted a flat list can concatenate, while one
  that wanted sections out of a flat list has to group it back itself.

  `document_count` and `proposal_count` are here because the first thing said
  about a cross-document change is how big it is, and counting an array to say
  "3 documents, 7 changes" is the kind of arithmetic that ends up written
  twice, differently, in two clients.
  """

  alias RintoPMOWeb.V1.BlockProposalJSON
  alias RintoPMOWeb.V1.DocumentJSON

  def index(%{entries: entries}) do
    %{
      data: %{
        document_count: length(entries),
        proposal_count: Enum.sum_by(entries, &length(&1.proposals)),
        documents: Enum.map(entries, &entry/1)
      }
    }
  end

  defp entry(%{document: document, proposals: proposals}) do
    # The same shape `GET /documents` answers with, rather than a leaner one
    # made up here: a client that renders a document row already has code for
    # that shape, and a second one would be a second thing to keep in step.
    %{document: DocumentJSON.summary(document), proposals: Enum.map(proposals, &standing/1)}
  end

  # `contended` is the one thing here that is not a field of the proposal: it
  # says somebody else's live proposal is standing in the same slot, which is
  # what stops this one being committable until a person decides between them.
  # The other proposal's text is deliberately absent -- reconciling versions is
  # `GET /documents/{id}/contentions`, and a review screen showing two bodies
  # side by side is a different screen.
  defp standing(%{proposal: proposal, contended: contended}) do
    proposal
    |> BlockProposalJSON.data()
    |> Map.put(:contended, contended)
  end
end
