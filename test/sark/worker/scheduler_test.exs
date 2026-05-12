defmodule Sark.Worker.SchedulerTest do
  use ExUnit.Case, async: true

  alias Sark.Worker.Scheduler

  describe "matches?/2" do
    test "every-minute cron matches any minute" do
      {:ok, cron} = Crontab.CronExpression.Parser.parse("* * * * *")
      assert Scheduler.matches?(cron, ~N[2026-05-06 12:34:00])
      assert Scheduler.matches?(cron, ~N[2026-05-06 00:00:00])
    end

    test "specific hour-minute cron matches only at that time" do
      {:ok, cron} = Crontab.CronExpression.Parser.parse("0 3 * * *")
      assert Scheduler.matches?(cron, ~N[2026-05-06 03:00:00])
      refute Scheduler.matches?(cron, ~N[2026-05-06 03:01:00])
      refute Scheduler.matches?(cron, ~N[2026-05-06 04:00:00])
    end

    test "weekday-restricted cron" do
      # 9am Mon-Fri (1-5)
      {:ok, cron} = Crontab.CronExpression.Parser.parse("0 9 * * 1-5")
      # 2026-05-06 = Wednesday
      assert Scheduler.matches?(cron, ~N[2026-05-06 09:00:00])
      # 2026-05-09 = Saturday
      refute Scheduler.matches?(cron, ~N[2026-05-09 09:00:00])
    end
  end
end
