defmodule Sark.CLITest do
  use ExUnit.Case, async: false

  alias Sark.CLI
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.Pipeline.Lock
  alias Sark.Plugin
  alias Sark.Plugin.DB
  alias Sark.Plugin.Loader

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../fixtures/plugins/kv", __DIR__)

  setup %{tmp_dir: dir} do
    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    router = Sark.MCP.Registration.router_module("kv")
    :persistent_term.put({Phantom, router, :tools}, [])
    :persistent_term.put({Phantom, router, :initialized}, false)

    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})

    # Clear any lock left over from another test.
    Enum.each(Lock.in_flight(), fn {p, n, _} -> Lock.release(p, n) end)

    {:ok, spec: spec}
  end

  describe "resolve_pipeline!/1" do
    test "returns spec + pipeline for a known target", %{spec: spec} do
      {found_spec, pipeline} = CLI.resolve_pipeline!("kv.inventory_ingest")
      assert found_spec.name == spec.name
      assert pipeline.name == :inventory_ingest
    end

    test "raises on missing plugin" do
      assert_raise ArgumentError, ~r/no plugin registered/, fn ->
        CLI.resolve_pipeline!("nope.something")
      end
    end

    test "raises on missing pipeline within plugin" do
      assert_raise ArgumentError, ~r/pipeline `ghost`/, fn ->
        CLI.resolve_pipeline!("kv.ghost")
      end
    end

    test "raises on malformed target" do
      assert_raise ArgumentError, ~r/expected `<plugin>.<pipeline>`/, fn ->
        CLI.resolve_pipeline!("no-dot")
      end
    end
  end

  describe "run_pipeline/1" do
    test "triggers a pipeline asynchronously and writes to _pipeline_log", %{spec: spec} do
      # `note_add` is an unscheduled tool: step pipeline in the kv fixture
      # that wraps add_note. Feed it stdin via a wrapper pipeline? No —
      # run_pipeline doesn't take stdin, so use a pipeline that needs no
      # input. We'll point at inventory_ingest which is `load:` only.
      result = CLI.run_pipeline("kv.inventory_ingest")
      assert {:triggered, "kv.inventory_ingest", run_id} = result
      assert is_binary(run_id)

      wait_for_completion!(spec, run_id)

      {:ok, _, [%{"status" => status}]} =
        DB.read(spec.name, "SELECT status FROM _pipeline_log WHERE run_id = ?", [run_id])

      assert status == "success"
    end

    test "returns :busy if the pipeline is already running" do
      # Acquire manually to simulate an in-flight run.
      {:ok, existing_run} = Lock.acquire("kv", :inventory_ingest)

      assert {:busy, "kv.inventory_ingest", ^existing_run} =
               CLI.run_pipeline("kv.inventory_ingest")

      Lock.release("kv", :inventory_ingest)
    end
  end

  defp wait_for_completion!(spec, run_id) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    poll_completion!(spec, run_id, deadline)
  end

  defp poll_completion!(spec, run_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("run #{run_id} did not complete within 2s")
    end

    case DB.read(spec.name, "SELECT status FROM _pipeline_log WHERE run_id = ?", [run_id]) do
      {:ok, _, [%{"status" => s}]} when s in ["success", "failed"] ->
        :ok

      _ ->
        Process.sleep(20)
        poll_completion!(spec, run_id, deadline)
    end
  end
end
