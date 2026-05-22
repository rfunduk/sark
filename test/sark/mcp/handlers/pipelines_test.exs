defmodule Sark.MCP.Handlers.PipelinesTest do
  use ExUnit.Case, async: false

  alias Sark.MCP.Internal
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.Pipeline.Lock
  alias Sark.Pipeline.Runner
  alias Sark.Plugin
  alias Sark.Plugin.DB
  alias Sark.Plugin.Loader
  alias Sark.Plugin.Pipeline

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../../fixtures/plugins/kv", __DIR__)

  setup %{tmp_dir: dir} do
    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    router = Sark.MCP.Registration.router_module("kv")
    :persistent_term.put({Phantom, router, :tools}, [])
    :persistent_term.put({Phantom, router, :initialized}, false)

    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})

    Enum.each(Lock.in_flight(), fn {p, n, _} -> Lock.release(p, n) end)

    {:ok, spec: spec}
  end

  defp run_one!(spec, name, opts) do
    pipeline = Pipeline.parse!(name, Map.merge(%{"description" => "t"}, Map.new(opts)))
    rid = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    {:ok, _} =
      Runner.run(
        plugin: spec.name,
        pipeline: pipeline,
        spec: spec,
        run_id: rid,
        llm: Sark.LLM.Stub,
        triggered_by: :manual
      )

    rid
  end

  defp decode_text({:ok, json}), do: Jason.decode!(json)

  describe "sark_pipelines_list" do
    test "returns declared pipelines + last-run summary", %{spec: spec} do
      _rid = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo hi"}]})

      decoded = decode_text(Internal.call_tool(spec.name, "sark_pipelines_list", %{}))

      names = Enum.map(decoded, & &1["name"]) |> Enum.sort()
      assert "inventory_ingest" in names
      assert "smoke" in names

      inventory = Enum.find(decoded, &(&1["name"] == "inventory_ingest"))
      assert inventory["last_run"]["status"] == "success"
      assert inventory["schedule"] != nil
    end

    test "pipelines without runs surface last_run = nil", %{spec: spec} do
      decoded = decode_text(Internal.call_tool(spec.name, "sark_pipelines_list", %{}))

      smoke = Enum.find(decoded, &(&1["name"] == "smoke"))
      assert smoke["last_run"] == nil
    end
  end

  describe "sark_pipelines_recent" do
    test "lists newest first across all pipelines", %{spec: spec} do
      rid_a = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo a"}]})
      Process.sleep(20)
      rid_b = run_one!(spec, "smoke", %{"steps" => [%{"shell" => "echo b"}]})

      decoded = decode_text(Internal.call_tool(spec.name, "sark_pipelines_recent", %{}))

      run_ids = Enum.map(decoded, & &1["run_id"])
      idx_a = Enum.find_index(run_ids, &(&1 == rid_a))
      idx_b = Enum.find_index(run_ids, &(&1 == rid_b))
      assert is_integer(idx_a) and is_integer(idx_b)
      assert idx_b < idx_a, "newer run #{rid_b} should be ahead of #{rid_a}"
    end

    test "filters to pipeline + honours limit", %{spec: spec} do
      _ = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo a"}]})
      _ = run_one!(spec, "smoke", %{"steps" => [%{"shell" => "echo b"}]})

      decoded =
        decode_text(
          Internal.call_tool(spec.name, "sark_pipelines_recent", %{
            "pipeline" => "inventory_ingest"
          })
        )

      pipelines = Enum.map(decoded, & &1["pipeline"]) |> Enum.uniq()
      assert pipelines == ["inventory_ingest"]
    end

    test "limit 1 returns at most one row", %{spec: spec} do
      _ = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo a"}]})
      _ = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo b"}]})

      decoded =
        decode_text(Internal.call_tool(spec.name, "sark_pipelines_recent", %{"limit" => 1}))

      assert length(decoded) == 1
    end
  end

  describe "sark_pipelines_log" do
    test "without run_id, returns the most recent run for the named pipeline", %{spec: spec} do
      _ = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo a"}]})
      Process.sleep(20)
      latest = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo b"}]})

      decoded =
        decode_text(
          Internal.call_tool(spec.name, "sark_pipelines_log", %{
            "pipeline" => "inventory_ingest"
          })
        )

      assert decoded["run"]["run_id"] == latest
      assert length(decoded["steps"]) == 1
    end

    test "with explicit run_id, returns that run", %{spec: spec} do
      rid = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo a"}]})
      _ = run_one!(spec, "inventory_ingest", %{"steps" => [%{"shell" => "echo b"}]})

      decoded =
        decode_text(
          Internal.call_tool(spec.name, "sark_pipelines_log", %{
            "pipeline" => "inventory_ingest",
            "run_id" => rid
          })
        )

      assert decoded["run"]["run_id"] == rid
    end

    test "errors when no run exists for the pipeline", %{spec: spec} do
      assert {:error, msg} =
               Internal.call_tool(spec.name, "sark_pipelines_log", %{
                 "pipeline" => "smoke"
               })

      assert msg =~ "no runs found"
    end

    test "errors when pipeline param is missing", %{spec: spec} do
      assert {:error, msg} = Internal.call_tool(spec.name, "sark_pipelines_log", %{})
      assert msg =~ "validation"
    end
  end

  describe "sark_pipelines_costs" do
    test "rolls up tokens grouped by pipeline + model", %{spec: spec} do
      # Drop in a fake LLM step row directly so we can assert on the rollup.
      :ok =
        Sark.Pipeline.Log.start_run(spec.name, %{
          run_id: "cost_run_1",
          pipeline: :smoke,
          started_at: "2025-01-01T00:00:00Z",
          triggered_by: :manual
        })

      :ok =
        Sark.Pipeline.Log.finish_run(
          spec.name,
          "cost_run_1",
          :success,
          "2025-01-01T00:00:00Z",
          nil
        )

      :ok =
        Sark.Pipeline.Log.record_step(spec.name, %{
          run_id: "cost_run_1",
          step_index: 0,
          step_type: :llm,
          started_at: "2025-01-01T00:00:00Z",
          finished_at: "2025-01-01T00:00:01Z",
          status: :success,
          error: nil,
          model: "claude-sonnet-4-6",
          turns: 1,
          stop_reason: "end_turn",
          input_tokens: 100,
          output_tokens: 50,
          cache_read_tokens: 10,
          cache_creation_tokens: 5,
          service_tier: "standard",
          final_output: "ok"
        })

      :ok =
        Sark.Pipeline.Log.record_step(spec.name, %{
          run_id: "cost_run_1",
          step_index: 1,
          step_type: :llm,
          started_at: "2025-01-01T00:00:01Z",
          finished_at: "2025-01-01T00:00:02Z",
          status: :success,
          error: nil,
          model: "claude-sonnet-4-6",
          turns: 1,
          stop_reason: "end_turn",
          input_tokens: 200,
          output_tokens: 75,
          cache_read_tokens: 20,
          cache_creation_tokens: 0,
          service_tier: "standard",
          final_output: "ok"
        })

      decoded = decode_text(Internal.call_tool(spec.name, "sark_pipelines_costs", %{}))

      assert [
               %{
                 "pipeline" => "smoke",
                 "model" => "claude-sonnet-4-6",
                 "input_tokens" => 300,
                 "output_tokens" => 125,
                 "cache_read_tokens" => 30,
                 "cache_creation_tokens" => 5
               }
             ] = decoded
    end
  end

  describe "sark_pipelines_run_now" do
    test "triggers a registered pipeline and returns run_id", %{spec: spec} do
      assert {:ok, json} =
               Internal.call_tool(spec.name, "sark_pipelines_run_now", %{
                 "pipeline" => "inventory_ingest"
               })

      decoded = Jason.decode!(json)
      assert decoded["ok"] == true
      assert is_binary(decoded["run_id"])

      # Wait for terminal state to land.
      wait_for_run!(spec, decoded["run_id"])

      {:ok, _, [%{"status" => status}]} =
        DB.sark_read(spec.name, "SELECT status FROM _pipeline_log WHERE run_id = ?", [
          decoded["run_id"]
        ])

      assert status == "success"
    end

    test "busy: response if a run is already in flight", %{spec: spec} do
      {:ok, existing} = Lock.acquire(spec.name, :inventory_ingest)

      assert {:error, msg} =
               Internal.call_tool(spec.name, "sark_pipelines_run_now", %{
                 "pipeline" => "inventory_ingest"
               })

      assert msg =~ "busy"
      assert msg =~ existing

      Lock.release(spec.name, :inventory_ingest)
    end

    test "validation: missing pipeline param", %{spec: spec} do
      assert {:error, msg} =
               Internal.call_tool(spec.name, "sark_pipelines_run_now", %{})

      assert msg =~ "validation"
    end

    test "validation: unknown pipeline name", %{spec: spec} do
      assert {:error, msg} =
               Internal.call_tool(spec.name, "sark_pipelines_run_now", %{
                 "pipeline" => "does_not_exist"
               })

      assert msg =~ "not found"
    end
  end

  describe "sark_pipelines_cancel" do
    alias Sark.Pipeline.Cancel

    test "sets cancel flag for an in-flight run", %{spec: spec} do
      {:ok, rid} = Sark.Pipeline.Lock.acquire(spec.name, :inventory_ingest)

      assert {:ok, json} =
               Internal.call_tool(spec.name, "sark_pipelines_cancel", %{
                 "pipeline" => "inventory_ingest"
               })

      assert %{"ok" => true, "run_id" => ^rid} = Jason.decode!(json)
      assert Cancel.requested?(rid)

      Cancel.clear(rid)
      Sark.Pipeline.Lock.release(spec.name, :inventory_ingest)
    end

    test "accepts explicit run_id without requiring it to be in-flight", %{spec: spec} do
      rid = "explicit-rid"

      assert {:ok, json} =
               Internal.call_tool(spec.name, "sark_pipelines_cancel", %{
                 "pipeline" => "inventory_ingest",
                 "run_id" => rid
               })

      assert %{"ok" => true, "run_id" => ^rid} = Jason.decode!(json)
      assert Cancel.requested?(rid)

      Cancel.clear(rid)
    end

    test "errors when no in-flight run + no explicit run_id", %{spec: spec} do
      assert {:error, msg} =
               Internal.call_tool(spec.name, "sark_pipelines_cancel", %{
                 "pipeline" => "inventory_ingest"
               })

      assert msg =~ "no in-flight"
    end

    test "validation: missing pipeline param", %{spec: spec} do
      assert {:error, msg} =
               Internal.call_tool(spec.name, "sark_pipelines_cancel", %{})

      assert msg =~ "validation"
    end
  end

  describe "sark_pipelines_log_prune" do
    defp insert_run!(spec, run_id, pipeline, finished_at, step_count) do
      {:ok, _} =
        DB.sark_write(
          spec.name,
          "INSERT INTO _pipeline_log (run_id, pipeline, started_at, finished_at, status, triggered_by) VALUES (?, ?, ?, ?, ?, ?)",
          [run_id, pipeline, finished_at, finished_at, "success", "manual"]
        )

      for i <- 0..(step_count - 1)//1 do
        {:ok, _} =
          DB.sark_write(
            spec.name,
            "INSERT INTO _pipeline_step_log (run_id, step_index, step_type, started_at, finished_at, status) VALUES (?, ?, ?, ?, ?, ?)",
            [run_id, i, "shell", finished_at, finished_at, "success"]
          )
      end
    end

    defp run_count(spec), do: count(spec, "_pipeline_log")
    defp step_count(spec), do: count(spec, "_pipeline_step_log")

    defp count(spec, table) do
      {:ok, _, [%{"n" => n}]} = DB.sark_read(spec.name, "SELECT COUNT(*) AS n FROM #{table}", [])
      n
    end

    defp iso_n_days_ago(n) do
      DateTime.utc_now() |> DateTime.add(-n, :day) |> DateTime.to_iso8601()
    end

    test "deletes rows older than the cutoff across all pipelines", %{spec: spec} do
      insert_run!(spec, "old1", "ingest", iso_n_days_ago(100), 2)
      insert_run!(spec, "old2", "smoke", iso_n_days_ago(40), 1)
      insert_run!(spec, "fresh", "ingest", iso_n_days_ago(5), 3)

      assert run_count(spec) == 3
      assert step_count(spec) == 6

      assert {:ok, json} =
               Internal.call_tool(spec.name, "sark_pipelines_log_prune", %{
                 "older_than" => "30d"
               })

      assert %{"deleted" => 2} = Jason.decode!(json)
      assert run_count(spec) == 1
      assert step_count(spec) == 3

      {:ok, _, [%{"run_id" => surviving}]} =
        DB.sark_read(spec.name, "SELECT run_id FROM _pipeline_log", [])

      assert surviving == "fresh"
    end

    test "filters by pipeline when provided", %{spec: spec} do
      insert_run!(spec, "old_ingest", "ingest", iso_n_days_ago(60), 1)
      insert_run!(spec, "old_smoke", "smoke", iso_n_days_ago(60), 1)

      assert {:ok, json} =
               Internal.call_tool(spec.name, "sark_pipelines_log_prune", %{
                 "older_than" => "30d",
                 "pipeline" => "ingest"
               })

      assert %{"deleted" => 1} = Jason.decode!(json)
      assert run_count(spec) == 1

      {:ok, _, [%{"pipeline" => survivor}]} =
        DB.sark_read(spec.name, "SELECT pipeline FROM _pipeline_log", [])

      assert survivor == "smoke"
    end

    test "deletes step rows for pruned runs (explicit cascade)", %{spec: spec} do
      insert_run!(spec, "old1", "ingest", iso_n_days_ago(60), 4)
      insert_run!(spec, "fresh1", "ingest", iso_n_days_ago(1), 2)

      assert step_count(spec) == 6

      assert {:ok, _} =
               Internal.call_tool(spec.name, "sark_pipelines_log_prune", %{
                 "older_than" => "30d"
               })

      assert step_count(spec) == 2

      {:ok, _, rows} = DB.sark_read(spec.name, "SELECT run_id FROM _pipeline_step_log", [])
      assert Enum.all?(rows, &(&1["run_id"] == "fresh1"))
    end

    test "supports h/m/s/d/w/y units", %{spec: spec} do
      insert_run!(spec, "two_h_ago", "ingest", iso_iso_hours_ago(2), 0)
      insert_run!(spec, "one_min_ago", "ingest", iso_minutes_ago(1), 0)

      assert {:ok, json} =
               Internal.call_tool(spec.name, "sark_pipelines_log_prune", %{"older_than" => "1h"})

      assert %{"deleted" => 1} = Jason.decode!(json)
    end

    test "returns 0 deleted when nothing matches", %{spec: spec} do
      insert_run!(spec, "fresh", "ingest", iso_n_days_ago(1), 0)

      assert {:ok, json} =
               Internal.call_tool(spec.name, "sark_pipelines_log_prune", %{"older_than" => "90d"})

      assert %{"deleted" => 0} = Jason.decode!(json)
      assert run_count(spec) == 1
    end

    test "validation: missing older_than", %{spec: spec} do
      assert {:error, msg} = Internal.call_tool(spec.name, "sark_pipelines_log_prune", %{})
      assert msg =~ "older_than"
      assert msg =~ "required"
    end

    test "validation: malformed duration", %{spec: spec} do
      assert {:error, msg} =
               Internal.call_tool(spec.name, "sark_pipelines_log_prune", %{"older_than" => "soon"})

      assert msg =~ "older_than"
    end

    defp iso_iso_hours_ago(h),
      do: DateTime.utc_now() |> DateTime.add(-h * 3600, :second) |> DateTime.to_iso8601()

    defp iso_minutes_ago(m),
      do: DateTime.utc_now() |> DateTime.add(-m * 60, :second) |> DateTime.to_iso8601()
  end

  describe "parse_duration/1" do
    test "parses common units" do
      assert Sark.MCP.Handlers.Pipelines.parse_duration("30s") == {:ok, 30}
      assert Sark.MCP.Handlers.Pipelines.parse_duration("90m") == {:ok, 5_400}
      assert Sark.MCP.Handlers.Pipelines.parse_duration("6h") == {:ok, 21_600}
      assert Sark.MCP.Handlers.Pipelines.parse_duration("30d") == {:ok, 2_592_000}
      assert Sark.MCP.Handlers.Pipelines.parse_duration("2w") == {:ok, 1_209_600}
      assert Sark.MCP.Handlers.Pipelines.parse_duration("1y") == {:ok, 31_536_000}
    end

    test "case-insensitive unit + tolerates whitespace" do
      assert {:ok, 86_400} = Sark.MCP.Handlers.Pipelines.parse_duration(" 1D ")
    end

    test "rejects garbage" do
      assert {:error, _} = Sark.MCP.Handlers.Pipelines.parse_duration("forever")
      assert {:error, _} = Sark.MCP.Handlers.Pipelines.parse_duration("10")
      assert {:error, _} = Sark.MCP.Handlers.Pipelines.parse_duration("d10")
    end
  end

  describe "reserved names" do
    test "raises when a tool name collides with a reserved sark_pipelines_* built-in" do
      spec = %Sark.Plugin.Spec{
        name: "collide",
        dir: "/tmp/collide",
        migrations: [],
        tools: [
          %Sark.Plugin.Tool{
            name: :sark_pipelines_list,
            description: "x",
            returns: :results,
            write: false,
            params: [],
            format: :list,
            statements: []
          }
        ]
      }

      assert_raise RuntimeError, ~r/reserved/, fn ->
        Sark.MCP.Registration.register_plugin!(spec)
      end
    end
  end

  defp wait_for_run!(spec, run_id) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    poll!(spec, run_id, deadline)
  end

  defp poll!(spec, run_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("run #{run_id} never completed")
    end

    case DB.sark_read(spec.name, "SELECT status FROM _pipeline_log WHERE run_id = ?", [run_id]) do
      {:ok, _, [%{"status" => s}]} when s in ["success", "failed"] ->
        :ok

      _ ->
        Process.sleep(20)
        poll!(spec, run_id, deadline)
    end
  end
end
