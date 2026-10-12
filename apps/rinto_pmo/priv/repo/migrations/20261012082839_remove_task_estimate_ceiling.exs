defmodule RintoPMO.Repo.Migrations.RemoveTaskEstimateCeiling do
  use Ecto.Migration

  def up do
    drop constraint(:tasks, :tasks_estimate_ceiling_check)
  end

  def down do
    # Refuse rollback if larger estimates exist rather than truncating user data.
    create constraint(:tasks, :tasks_estimate_ceiling_check,
             check: "estimate_pessimistic IS NULL OR estimate_pessimistic <= 480"
           )
  end
end
