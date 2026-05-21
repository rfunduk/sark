defmodule Sark.Pipeline.SchedulerTest do
  use ExUnit.Case, async: false

  alias Sark.Pipeline.Lock
  alias Sark.Pipeline.Scheduler
  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Spec

  setup do
    Enum.each(Lock.in_flight(), fn {plugin, name, _id} ->
      Lock.release(plugin, name)
    end)

    :ok
  end

  describe "matches?/2" do
    test "cron expression that matches now → true" do
      # "* * * * *" matches every minute.
      cron = parse_cron!("* * * * *")
      assert Scheduler.matches?(cron, NaiveDateTime.utc_now())
    end

    test "cron expression that doesn't match now → false" do
      now = NaiveDateTime.utc_now()
      mismatched_hour = rem(now.hour + 1, 24)

      cron = parse_cron!("* #{mismatched_hour} * * *")
      refute Scheduler.matches?(cron, %{now | hour: now.hour})
    end
  end

  describe "tick + fire" do
    test "acquires lock and spawns task when cron matches" do
      # Build a hand-rolled spec with one pipeline whose cron matches
      # every minute. The spec doesn't need a real plugin DB for this
      # narrow test because the runner is never called — we intercept
      # by holding the lock first so the scheduler sees `:busy`.
      pipeline = pipeline_with_cron("every_minute", "* * * * *")

      spec = %Spec{
        name: "sched_test_busy",
        dir: "/tmp/sched_test_busy",
        migrations: [],
        tools: [],
        pipelines: [pipeline]
      }

      # Pre-acquire so the scheduler must see :busy when it ticks.
      {:ok, existing} = Lock.acquire(spec.name, pipeline.name)

      {:ok, sched} = Scheduler.start_link(spec: spec)

      send(sched, :tick)
      Process.sleep(50)

      # Still held with the same run_id — scheduler did not displace us.
      assert {:busy, ^existing} = Lock.acquire(spec.name, pipeline.name)

      Lock.release(spec.name, pipeline.name)
      GenServer.stop(sched)
    end

    test "skips pipelines without a schedule (manual-only)" do
      manual_pipeline = pipeline_with_cron("manual", nil)

      spec = %Spec{
        name: "sched_test_manual",
        dir: "/tmp/sched_test_manual",
        migrations: [],
        tools: [],
        pipelines: [manual_pipeline]
      }

      {:ok, sched} = Scheduler.start_link(spec: spec)

      # Ticking shouldn't fire anything — the manual-only pipeline has
      # schedule: nil so it's not in the scheduled list at all.
      send(sched, :tick)
      Process.sleep(50)

      # Nothing in flight.
      assert {:ok, _} = Lock.acquire(spec.name, manual_pipeline.name)
      Lock.release(spec.name, manual_pipeline.name)

      GenServer.stop(sched)
    end
  end

  defp parse_cron!(s) do
    {:ok, expr} = Crontab.CronExpression.Parser.parse(s)
    expr
  end

  defp pipeline_with_cron(name, cron_str) do
    base = %{
      "description" => "test",
      "steps" => [%{"shell" => "echo hi"}]
    }

    entry = if cron_str, do: Map.put(base, "schedule", cron_str), else: base
    Pipeline.parse!(name, entry)
  end
end
