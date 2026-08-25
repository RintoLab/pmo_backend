defmodule RintoPMO.CalendarTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Calendar
  alias RintoPMO.Calendar.Day

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

    test "leave takes a day out the same way a holiday does" do
      {:ok, _} = Calendar.put_leave(@wednesday, "away")

      calendar = Calendar.load(@monday, @monday)

      refute Calendar.workday?(calendar, @wednesday)
      assert Calendar.week_capacity(calendar, @monday) == 4 * Calendar.daily_capacity()
    end

    test "a week that is entirely off holds nothing, which is an answer not an error" do
      days = Enum.map(0..4, &{Date.add(@monday, &1), :holiday, "国庆"})
      {:ok, _} = Calendar.import_year(2026, "test", days)

      calendar = Calendar.load(@monday, @monday)

      assert Calendar.workdays_in(calendar, @monday) == []
      assert Calendar.week_capacity(calendar, @monday) == 0
    end
  end

  describe "import_year/3" do
    test "rewrites its own kinds and never touches leave" do
      {:ok, _} = Calendar.put_leave(@wednesday, "away")
      {:ok, _} = Calendar.import_year(2026, "first", [{@monday, :holiday, "gone next time"}])

      {:ok, _} = Calendar.import_year(2026, "second", [{@friday, :holiday, "the real one"}])

      kinds = Map.new(Calendar.list_days(@monday, @sunday), &{&1.day, &1.kind})

      assert kinds == %{@wednesday => :leave, @friday => :holiday}
    end

    test "records the year, and the source it last came from" do
      {:ok, _} = Calendar.import_year(2026, "first", [])
      {:ok, _} = Calendar.import_year(2026, "second", [])

      assert [%{year: 2026, source: "second"}] = Calendar.list_imports()
    end

    test "leaves other years alone" do
      {:ok, _} = Calendar.import_year(2025, "test", [{~D[2025-09-08], :holiday, "last year"}])
      {:ok, _} = Calendar.import_year(2026, "test", [])

      assert [%Day{day: ~D[2025-09-08]}] = Calendar.list_days(~D[2025-01-01], ~D[2025-12-31])
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
    test "removes a day off but refuses to touch a holiday" do
      {:ok, _} = Calendar.put_leave(@wednesday, "away")
      {:ok, _} = Calendar.import_year(2026, "test", [{@friday, :holiday, "秋分"}])

      :ok = Calendar.delete_leave(@wednesday)
      :ok = Calendar.delete_leave(@friday)

      assert [%Day{day: @friday, kind: :holiday}] = Calendar.list_days(@monday, @sunday)
    end
  end
end
