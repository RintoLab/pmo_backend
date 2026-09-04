defmodule RintoPMO.AIRolesTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.AIRoles

  @configuration %{
    "provider" => "google",
    "model" => "gemini-flash",
    "thinking_level" => "off"
  }

  describe "list_roles/0" do
    test "answers with every job, unconfigured ones included" do
      assert AIRoles.list_roles() == %{"topic_naming" => nil, "task_estimation" => nil}
    end

    test "carries the whole configuration of each job that has one" do
      assert {:ok, _roles} = AIRoles.put_role("topic_naming", @configuration)

      assert %{"topic_naming" => role, "task_estimation" => nil} = AIRoles.list_roles()
      assert role.provider == "google"
      assert role.model == "gemini-flash"
      assert role.thinking_level == "off"
    end
  end

  describe "put_role/2" do
    test "configures a job and hands back the whole set" do
      assert {:ok, %{"topic_naming" => role}} = AIRoles.put_role("topic_naming", @configuration)
      assert role.model == "gemini-flash"
      assert AIRoles.get_role("topic_naming").model == "gemini-flash"
    end

    test "keeps a standing instruction when one is written" do
      attrs = Map.put(@configuration, "system_prompt", "Lead with the subsystem.")

      assert {:ok, %{"topic_naming" => role}} = AIRoles.put_role("topic_naming", attrs)
      assert role.system_prompt == "Lead with the subsystem."
    end

    test "replaces rather than accumulates" do
      assert {:ok, _roles} = AIRoles.put_role("topic_naming", @configuration)

      assert {:ok, _roles} =
               AIRoles.put_role("topic_naming", %{@configuration | "model" => "gemini-pro"})

      assert AIRoles.get_role("topic_naming").model == "gemini-pro"
      assert [_one] = Repo.all(AIRoles.AIRole)
    end

    # A `PUT` writes the row whole, so a field left out of the body is a field
    # somebody cleared. The alternative -- keeping what was there -- would make
    # "remove my standing instruction" impossible to express.
    test "an omitted standing instruction clears the one that was there" do
      attrs = Map.put(@configuration, "system_prompt", "Lead with the subsystem.")
      assert {:ok, _roles} = AIRoles.put_role("topic_naming", attrs)

      assert {:ok, %{"topic_naming" => role}} = AIRoles.put_role("topic_naming", @configuration)
      assert role.system_prompt == nil
    end

    test "configures the two jobs independently" do
      assert {:ok, _roles} = AIRoles.put_role("topic_naming", @configuration)

      assert {:ok, roles} =
               AIRoles.put_role("task_estimation", %{@configuration | "model" => "gemini-pro"})

      assert roles["topic_naming"].model == "gemini-flash"
      assert roles["task_estimation"].model == "gemini-pro"
    end

    # The three arrive together or the role is a call nobody can make, and the
    # request that wrote it is the last place anybody is looking.
    test "refuses a model configuration with a hole in it" do
      assert {:error, changeset} =
               AIRoles.put_role("topic_naming", %{"provider" => "google"})

      assert %{model: ["can't be blank"], thinking_level: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "refuses a job the system does not have" do
      assert AIRoles.put_role("chief_of_vibes", @configuration) == {:error, :not_found}
      assert AIRoles.list_roles() == %{"topic_naming" => nil, "task_estimation" => nil}
    end

    # The key comes from the URL; a body that also carries one cannot move the
    # row somewhere else.
    test "ignores a key in the body" do
      attrs = Map.put(@configuration, "key", "task_estimation")

      assert {:ok, roles} = AIRoles.put_role("topic_naming", attrs)
      assert roles["topic_naming"].model == "gemini-flash"
      assert roles["task_estimation"] == nil
    end
  end

  describe "delete_role/1" do
    test "empties a job and hands back the whole set" do
      assert {:ok, _roles} = AIRoles.put_role("topic_naming", @configuration)

      assert {:ok, %{"topic_naming" => nil}} = AIRoles.delete_role("topic_naming")
      assert AIRoles.get_role("topic_naming") == nil
    end

    # No row and a row of nulls are the same state, so emptying twice asks for
    # something that is already true.
    test "emptying a job nobody configured succeeds" do
      assert {:ok, %{"topic_naming" => nil}} = AIRoles.delete_role("topic_naming")
    end

    test "leaves the other job alone" do
      assert {:ok, _roles} = AIRoles.put_role("topic_naming", @configuration)
      assert {:ok, _roles} = AIRoles.put_role("task_estimation", @configuration)

      assert {:ok, roles} = AIRoles.delete_role("topic_naming")
      assert roles["topic_naming"] == nil
      assert roles["task_estimation"].model == "gemini-flash"
    end

    test "refuses a job the system does not have" do
      assert AIRoles.delete_role("chief_of_vibes") == {:error, :not_found}
    end
  end

  describe "get_role/1" do
    test "an unconfigured job is nothing" do
      assert AIRoles.get_role("topic_naming") == nil
    end
  end
end
