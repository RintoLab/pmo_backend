defmodule RintoPMO.CalendarTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Calendar
  alias RintoPMO.Calendar.Day
  alias RintoPMO.Calendar.Leave

  # 2026-09-07 is a Monday.
  @monday ~D[2026-09-07]
  @wednesday ~D[2026-09-09]
  @friday ~D[2026-09-11]
  @saturday ~D[2026-09-12]
  @sunday ~D[2026-09-13]

  describe "pure date arithmetic" do
    test "every day of a week names the same week" do
      for offset <- 0..6 do
        assert Calendar.monday_of(Date.add(@monday, offset)) == @monday
      end
    end

    test "weeks/2 is inclusive of both ends" do
      assert Calendar.weeks(@monday, Date.add(@monday, 14)) == [
               @monday,
               Date.add(@monday, 7),
               Date.add(@monday, 14)
             ]
    end

    test "weeks/2 of a backwards range is empty rather than an endless walk" do
      assert Calendar.weeks(Date.add(@monday, 7), @monday) == []
    end
  end

  describe "the default, with nothing loaded" do
    test "Monday through Friday are worked and the weekend is not" do
      calendar = Calendar.none()

      assert Enum.all?(0..4, &Calendar.workday?(calendar, Date.add(@monday, &1)))
      refute Calendar.workday?(calendar, @saturday)
      refute Calendar.workday?(calendar, @sunday)
    end

    test "a week is five days of capacity" do
      assert Calendar.week_capacity(Calendar.none(), @monday) == 5 * Calendar.daily_capacity()
    end

    test "asked from any day, a week gives the same five" do
      assert Calendar.workdays_in(Calendar.none(), @sunday) ==
               Enum.map(0..4, &Date.add(@monday, &1))
    end
  end

  describe "exceptions" do
    test "a holiday takes a weekday out, and a make-up day puts a weekend day in" do
      {:ok, _} =
        Calendar.import_year(2026, "test", [
          {@wednesday, :holiday, "秋分"},
          {@saturday, :workday, "调休"}
        ])

      calendar = Calendar.load(@monday, @monday)

      refute Calendar.workday?(calendar, @wednesday)
      assert Calendar.workday?(calendar, @saturday)
    end

    test "a week that is entirely off holds nothing, which is an answer not an error" do
      days = Enum.map(0..4, &{Date.add(@monday, &1), :holiday, "国庆"})
      {:ok, _} = Calendar.import_year(2026, "test", days)

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.workdays_in(calendar, @monday) == []
      assert Calendar.week_capacity(calendar, @monday) == 0
    end
  end

  describe "leave" do
    test "takes minutes off a day rather than the whole of it" do
      {:ok, _} = Calendar.put_leave(@wednesday, 120, "看医生")

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.capacity_on(calendar, @wednesday) == Calendar.daily_capacity() - 120
      assert Calendar.week_capacity(calendar, @monday) == 5 * Calendar.daily_capacity() - 120
    end

    test "leaves the day a working day -- what changed is how much of it is left" do
      {:ok, _} = Calendar.put_leave(@wednesday, 1440, "年假")

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.workday?(calendar, @wednesday)
      assert @wednesday in Calendar.workdays_in(calendar, @monday)
      assert Calendar.base_capacity(calendar, @wednesday) == Calendar.daily_capacity()
    end

    test "a day with nothing left is not somewhere work can go" do
      {:ok, _} = Calendar.put_leave(@wednesday, 1440, "年假")

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.capacity_on(calendar, @wednesday) == 0
      refute @wednesday in Enum.map(Calendar.capacities_in(calendar, @monday), &elem(&1, 0))
      assert Calendar.week_capacity(calendar, @monday) == 4 * Calendar.daily_capacity()
    end

    test "exactly a day's worth empties it, and so does more" do
      {:ok, _} = Calendar.put_leave(@wednesday, Calendar.daily_capacity(), "整天")
      {:ok, _} = Calendar.put_leave(@friday, 5000, "很久")

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.capacity_on(calendar, @wednesday) == 0
      assert Calendar.capacity_on(calendar, @friday) == 0
    end

    test "a make-up workday can be partly taken off, and stays a workday" do
      {:ok, _} = Calendar.import_year(2026, "test", [{@saturday, :workday, "调休"}])
      {:ok, _} = Calendar.put_leave(@saturday, 60, "接孩子")

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.workday?(calendar, @saturday)
      assert Calendar.capacity_on(calendar, @saturday) == Calendar.daily_capacity() - 60
    end

    test "on a day that holds nothing it subtracts from nothing, and is kept" do
      {:ok, _} = Calendar.import_year(2026, "test", [{@wednesday, :holiday, "秋分"}])
      {:ok, _} = Calendar.put_leave(@wednesday, 120, "看医生")

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.capacity_on(calendar, @wednesday) == 0
      assert %{leave: %Leave{minutes: 120}} = Calendar.get_day(@wednesday)
    end

    test "asking twice replaces rather than accumulates" do
      {:ok, _} = Calendar.put_leave(@wednesday, 120, "看医生")
      {:ok, _} = Calendar.put_leave(@wednesday, 240, "看医生，久了点")

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.capacity_on(calendar, @wednesday) == Calendar.daily_capacity() - 240
    end

    test "has no duration to record when the number is not one" do
      assert {:error, changeset} = Calendar.put_leave(@wednesday, 0, "无")
      assert %{minutes: ["must be greater than 0"]} = errors_on(changeset)
    end
  end

  describe "import_year/3" do
    test "rewrites the year and never touches leave" do
      {:ok, _} = Calendar.put_leave(@wednesday, 120, "看医生")
      {:ok, _} = Calendar.import_year(2026, "first", [{@monday, :holiday, "gone next time"}])

      {:ok, _} = Calendar.import_year(2026, "second", [{@friday, :holiday, "the real one"}])

      assert [
               %{day: @wednesday, base: nil, leave: %Leave{minutes: 120}},
               %{day: @friday, base: %Day{kind: :holiday}, leave: nil}
             ] = Calendar.list_days(@monday, @sunday)
    end

    # The single-table version dropped this holiday silently: the leave row
    # already held the date, and the insert skipped conflicts. Deleting the
    # leave then left a statutory day off reading as an ordinary Wednesday.
    test "writes a holiday onto a day somebody is away for" do
      {:ok, _} = Calendar.put_leave(@wednesday, 1440, "年假")
      {:ok, _} = Calendar.import_year(2026, "test", [{@wednesday, :holiday, "秋分"}])

      assert %{base: %Day{kind: :holiday, name: "秋分"}, leave: %Leave{minutes: 1440}} =
               Calendar.get_day(@wednesday)

      :ok = Calendar.delete_leave(@wednesday)

      refute Calendar.workday?(Calendar.load(@monday, @monday), @wednesday)
    end

    test "records the year, and the source it last came from" do
      {:ok, _} = Calendar.import_year(2026, "first", [])
      {:ok, _} = Calendar.import_year(2026, "second", [])

      assert [%{year: 2026, source: "second"}] = Calendar.list_imports()
    end

    test "leaves other years alone" do
      {:ok, _} = Calendar.import_year(2025, "test", [{~D[2025-09-08], :holiday, "last year"}])
      {:ok, _} = Calendar.import_year(2026, "test", [])

      assert [%{day: ~D[2025-09-08], base: %Day{}}] =
               Calendar.list_days(~D[2025-01-01], ~D[2025-12-31])
    end
  end

  describe "a year nobody read" do
    test "is not known, even when it has no exceptions" do
      refute Calendar.week_known?(Calendar.load(@monday, @monday), @monday)
    end

    test "is known once it has been imported, exceptions or not" do
      {:ok, _} = Calendar.import_year(2026, "test", [])

      assert Calendar.week_known?(Calendar.load(@monday, @monday), @monday)
    end

    test "a week straddling New Year needs both years" do
      # 2026-12-28 is a Monday; that week runs into 2027-01-03.
      straddling = ~D[2026-12-28]
      {:ok, _} = Calendar.import_year(2026, "test", [])

      refute Calendar.week_known?(Calendar.load(straddling, straddling), straddling)

      {:ok, _} = Calendar.import_year(2027, "test", [])

      assert Calendar.week_known?(Calendar.load(straddling, straddling), straddling)
    end
  end

  describe "delete_leave/1" do
    test "removes a day off but cannot reach a holiday" do
      {:ok, _} = Calendar.put_leave(@wednesday, 120, "看医生")
      {:ok, _} = Calendar.import_year(2026, "test", [{@friday, :holiday, "秋分"}])

      :ok = Calendar.delete_leave(@wednesday)
      :ok = Calendar.delete_leave(@friday)

      assert [%{day: @friday, base: %Day{kind: :holiday}, leave: nil}] =
               Calendar.list_days(@monday, @sunday)
    end

    # What the single table could not do: `put_leave` overwrote the `workday`
    # row, and there was nothing left to say the Saturday had ever been one.
    test "gives a make-up Saturday back its minutes" do
      {:ok, _} = Calendar.import_year(2026, "test", [{@saturday, :workday, "调休"}])
      {:ok, _} = Calendar.put_leave(@saturday, 1440, "年假")

      :ok = Calendar.delete_leave(@saturday)

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.workday?(calendar, @saturday)
      assert Calendar.capacity_on(calendar, @saturday) == Calendar.daily_capacity()
    end
  end

  describe "list_days/2 and get_day/1" do
    test "a day carries what it starts with and what is left of it" do
      {:ok, _} = Calendar.put_leave(@wednesday, 120, "看医生")

      assert %{
               day: @wednesday,
               base_capacity_minutes: 480,
               capacity_minutes: 360,
               leave: %Leave{minutes: 120, name: "看医生"}
             } = Calendar.get_day(@wednesday)
    end

    test "an ordinary day nobody recorded anything about is still an answer" do
      assert %{day: @wednesday, base: nil, leave: nil, capacity_minutes: 480} =
               Calendar.get_day(@wednesday)

      assert %{day: @sunday, capacity_minutes: 0} = Calendar.get_day(@sunday)
    end

    test "an ordinary day is not in the list, because the list is departures" do
      {:ok, _} = Calendar.put_leave(@wednesday, 120, "看医生")

      assert [%{day: @wednesday}] = Calendar.list_days(@monday, @sunday)
    end
  end
end
