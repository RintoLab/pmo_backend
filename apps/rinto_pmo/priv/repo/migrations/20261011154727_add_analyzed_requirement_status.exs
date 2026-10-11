defmodule RintoPMO.Repo.Migrations.AddAnalyzedRequirementStatus do
  use Ecto.Migration

  def up do
    drop constraint(:requirements, :requirements_status_check)

    create constraint(:requirements, :requirements_status_check,
             check: "status IN ('draft', 'analyzed', 'active', 'completed', 'cancelled')"
           )
  end

  def down do
    # Preserve requirements as not started when removing the readiness marker.
    execute("UPDATE requirements SET status = 'draft' WHERE status = 'analyzed'")

    drop constraint(:requirements, :requirements_status_check)

    create constraint(:requirements, :requirements_status_check,
             check: "status IN ('draft', 'active', 'completed', 'cancelled')"
           )
  end
end
