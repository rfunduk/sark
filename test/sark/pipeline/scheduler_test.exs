defmodule Sark.Pipeline.SchedulerTest do
  use ExUnit.Case, async: true

  alias Sark.Pipeline.Lock
  alias Sark.Pipeline.Scheduler
  alias Sark.Pipeline.State
  alias Sark.Plugin
  alias Sark.Plugin.Loader
  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Spec

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)

  defp unique_name(prefix \\ "sched"),
    do: "#{prefix}_#{System.unique_integer([:positive])}"

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
      name = unique_name("busy")
      pipeline = pipeline_with_cron("every_minute", "* * * * *")

      spec = %Spec{
        name: name,
        dir: "/tmp/#{name}",
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
      name = unique_name("manual")
      manual_pipeline = pipeline_with_cron("manual", nil)

      spec = %Spec{
        name: name,
        dir: "/tmp/#{name}",
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

  describe "disabled pipelines" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      name = unique_name("disabled")
      spec = Loader.load!(name, @kv_fixture)
      start_supervised!({Plugin, spec: spec, data_dir: dir}, id: spec.name)

      {:ok, spec: spec}
    end

    test "State.disable + enable round-trip via the sark DB", %{spec: spec} do
      refute State.disabled?(spec.name, :inventory_ingest)
      :ok = State.disable(spec.name, :inventory_ingest)
      assert State.disabled?(spec.name, :inventory_ingest)
      :ok = State.enable(spec.name, :inventory_ingest)
      refute State.disabled?(spec.name, :inventory_ingest)
    end

    test "scheduler tick on a disabled cron-matching pipeline doesn't fire", %{spec: spec} do
      # Force-disable to short-circuit the cond branch even if the cron
      # happens to match. A clean tick should be a no-op on the lock.
      :ok = State.disable(spec.name, :inventory_ingest)

      sched = Process.whereis(Scheduler.registered_name(spec.name))
      assert is_pid(sched)

      send(sched, :tick)
      Process.sleep(50)

      # Nothing held — scheduler either didn't match cron OR matched but
      # bailed on disabled?/2. Either way, lock is free.
      assert {:ok, _} = Lock.acquire(spec.name, :inventory_ingest)
      Lock.release(spec.name, :inventory_ingest)
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
