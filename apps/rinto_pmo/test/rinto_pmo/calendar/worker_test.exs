defmodule RintoPMO.Calendar.WorkerTest do
  use RintoPMO.DataCase, async: true
  use Oban.Testing, repo: RintoPMO.Repo

  import ExUnit.CaptureLog

  alias RintoPMO.Calendar
  alias RintoPMO.Calendar.HolidaysMock
  alias RintoPMO.Calendar.Worker

  setup :verify_on_exit!

  defp this_year, do: Date.utc_today().year

  describe "perform/1" do
    test "imports this year and next" do
      year = this_year()

      expect(HolidaysMock, :fetch, 2, fn asked ->
        {:ok,
         %{
           source: "test/#{asked}",
           days: [{Date.new!(asked, 5, 1), :holiday, "劳动节"}]
         }}
      end)

      assert :ok = perform_job(Worker, %{})

      assert [%{year: ^year}, %{year: next}] = Calendar.list_imports()
      assert next == year + 1
    end

    test "a year that has not been announced yet is not a failure" do
      year = this_year()

      expect(HolidaysMock, :fetch, fn ^year ->
        {:ok, %{source: "test", days: [{Date.new!(year, 5, 1), :holiday, "劳动节"}]}}
      end)

      expect(HolidaysMock, :fetch, fn _next -> {:error, :not_found} end)

      assert :ok = perform_job(Worker, %{})

      # This year landed; next year simply is not there yet.
      assert [%{year: ^year}] = Calendar.list_imports()
    end

    test "an empty year is treated as unannounced, not as a year without holidays" do
      year = this_year()

      expect(HolidaysMock, :fetch, fn ^year ->
        {:ok, %{source: "test", days: [{Date.new!(year, 5, 1), :holiday, "劳动节"}]}}
      end)

      # The source publishes next year's file before the State Council
      # publishes next year's arrangement, so it is there and it is empty.
      expect(HolidaysMock, :fetch, fn _next -> {:ok, %{source: "test", days: []}} end)

      assert :ok = perform_job(Worker, %{})

      # Importing it would have marked the year known while knowing nothing.
      assert [%{year: ^year}] = Calendar.list_imports()

      next_week = Date.new!(year + 1, 3, 2)
      refute Calendar.week_known?(Calendar.load(next_week, next_week), next_week)
    end

    test "a failure on one year does not cost the other its refresh" do
      year = this_year()

      expect(HolidaysMock, :fetch, fn ^year -> {:error, {:transport, :timeout}} end)

      expect(HolidaysMock, :fetch, fn next ->
        {:ok, %{source: "test", days: [{Date.new!(next, 5, 1), :holiday, "劳动节"}]}}
      end)

      log = capture_log(fn -> assert :ok = perform_job(Worker, %{}) end)

      assert log =~ "could not read #{year}"
      assert [%{year: imported}] = Calendar.list_imports()
      assert imported == year + 1
    end

    test "a failed fetch leaves the last good calendar in place" do
      year = this_year()
      day = Date.new!(year, 5, 1)

      {:ok, _} = Calendar.import_year(year, "yesterday", [{day, :holiday, "劳动节"}])

      expect(HolidaysMock, :fetch, 2, fn _year -> {:error, {:http, 500}} end)

      capture_log(fn -> assert :ok = perform_job(Worker, %{}) end)

      calendar = Calendar.load(day, day)
      refute Calendar.workday?(calendar, day)
      assert [%{source: "yesterday"}] = Calendar.list_imports()
    end
  end
end
