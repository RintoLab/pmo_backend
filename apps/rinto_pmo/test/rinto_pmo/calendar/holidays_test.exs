defmodule RintoPMO.Calendar.HolidaysTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Calendar.Holidays

  # The shape `holiday-cn` actually publishes, trimmed to four entries taken
  # verbatim from 2026.json. 2026-01-04 is a Sunday that is *worked* to pay for
  # the New Year break, and 2026-02-14 is a Saturday worked for Spring Festival
  # -- one boolean carrying both kinds of exception, which is exactly why
  # `RintoPMO.Calendar.Day` keeps them in one table.
  @body %{
    "year" => 2026,
    "papers" => ["https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm"],
    "days" => [
      %{"name" => "元旦", "date" => "2026-01-01", "isOffDay" => true},
      %{"name" => "元旦", "date" => "2026-01-02", "isOffDay" => true},
      %{"name" => "元旦", "date" => "2026-01-04", "isOffDay" => false},
      %{"name" => "春节", "date" => "2026-02-14", "isOffDay" => false}
    ]
  }

  describe "url/1" do
    test "names the year's file in the repository the data comes from" do
      url = Holidays.url(2026)

      assert url =~ "holiday-cn"
      assert String.ends_with?(url, "/2026.json")
    end
  end

  describe "days_from/1" do
    test "isOffDay true is a holiday and false is a make-up workday" do
      assert {:ok, days} = Holidays.days_from(@body)

      assert days == [
               {~D[2026-01-01], :holiday, "元旦"},
               {~D[2026-01-02], :holiday, "元旦"},
               {~D[2026-01-04], :workday, "元旦"},
               {~D[2026-02-14], :workday, "春节"}
             ]
    end

    # The bug this test exists for: every fixture-based test passed while the
    # real fetch returned `:invalid_payload`, because raw.githubusercontent.com
    # serves .json as text/plain and no HTTP client decodes it on the way past.
    test "reads the raw string, which is what the server actually sends" do
      assert {:ok, days} = Holidays.days_from(JSON.encode!(@body))

      assert {~D[2026-01-04], :workday, "元旦"} in days
    end

    test "a year with no exceptions is an empty list, not a failure" do
      assert {:ok, []} = Holidays.days_from(%{"year" => 2026, "days" => []})
    end

    test "one unreadable entry fails the whole year" do
      body = put_in(@body["days"], @body["days"] ++ [%{"date" => "not-a-date"}])

      assert {:error, :invalid_payload} = Holidays.days_from(body)
    end

    test "an entry missing isOffDay fails rather than being guessed at" do
      body = put_in(@body["days"], [%{"name" => "元旦", "date" => "2026-01-01"}])

      assert {:error, :invalid_payload} = Holidays.days_from(body)
    end

    test "a body that is not the expected shape fails" do
      assert {:error, :invalid_payload} = Holidays.days_from(%{"error" => "404"})
      assert {:error, :invalid_payload} = Holidays.days_from("<!doctype html>")
    end
  end
end
