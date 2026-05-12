defmodule Sark.Worker.RunnerTest do
  use ExUnit.Case, async: false

  alias Sark.Plugin
  alias Sark.Plugin.Loader
  alias Sark.Plugin.Worker
  alias Sark.Worker.LLM.Stub
  alias Sark.Worker.Runner

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)

  setup %{tmp_dir: dir} do
    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})

    on_exit(fn -> Stub.stop() end)

    {:ok, spec: spec}
  end

  defp test_worker(overrides \\ %{}) do
    {:ok, cron} = Crontab.CronExpression.Parser.parse("0 0 1 1 0")

    %Worker{
      name: :smoke,
      description: "smoke",
      model: "claude-haiku-4-5",
      system: "be terse",
      prompt: "hi",
      tools: ["list", "get", "put"],
      max_turns: 4,
      schedule: cron
    }
    |> Map.merge(overrides)
  end

  defp collector do
    pid = self()
    fn event -> send(pid, {:event, event}) end
  end

  defp drain_events(acc \\ []) do
    receive do
      {:event, e} -> drain_events([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "stops on end_turn after one assistant turn with no tool_use", %{spec: spec} do
    {:ok, _} = Stub.start_link([%{text: "all done"}])

    assert {:ok, %{turns: 1, stop_reason: :end_turn}} =
             Runner.run(
               plugin: "kv",
               worker: test_worker(),
               spec: spec,
               llm: Stub,
               on_event: collector()
             )

    events = drain_events()
    assert {:turn_start, 1} in events
    assert {:assistant_text, "all done"} in events
    assert Enum.any?(events, &match?({:stop, _}, &1))
  end

  test "dispatches tool_use, feeds tool_result back, loops to end_turn", %{spec: spec} do
    {:ok, _} =
      Stub.start_link([
        %{
          text: "writing",
          tool_uses: [%{id: "u1", name: "put", input: %{"key" => "alpha", "value" => "1"}}]
        },
        %{text: "wrote it"}
      ])

    assert {:ok, %{turns: 2, stop_reason: :end_turn}} =
             Runner.run(
               plugin: "kv",
               worker: test_worker(),
               spec: spec,
               llm: Stub,
               on_event: collector()
             )

    events = drain_events()

    assert Enum.any?(events, &match?({:tool_call, %{name: "put"}}, &1))
    assert Enum.any?(events, &match?({:tool_result, %{ok: true}}, &1))

    [_first_call | rest] = Stub.recorded_calls()
    second = hd(rest)
    [user1, assistant1, user2] = second.messages

    assert user1.role == :user
    assert assistant1.role == :assistant
    assert user2.role == :user
    assert [%{type: :tool_result, tool_use_id: "u1", is_error: false}] = user2.content
  end

  test "tool error surfaces to LLM as tool_result with is_error: true", %{spec: spec} do
    {:ok, _} =
      Stub.start_link([
        %{
          text: "trying",
          tool_uses: [%{id: "u1", name: "put", input: %{"key" => "x"}}]
        },
        %{text: "got it"}
      ])

    assert {:ok, %{turns: 2}} =
             Runner.run(
               plugin: "kv",
               worker: test_worker(),
               spec: spec,
               llm: Stub,
               on_event: collector()
             )

    events = drain_events()
    assert Enum.any?(events, &match?({:tool_result, %{ok: false}}, &1))

    [_first | [second | _]] = Stub.recorded_calls()
    [_, _, user2] = second.messages
    [%{type: :tool_result, is_error: true, content: msg}] = user2.content
    assert msg =~ "validation"
  end

  test "aborts after max_turns is exceeded", %{spec: spec} do
    {:ok, _} =
      Stub.start_link(
        Enum.map(1..10, fn i ->
          %{
            text: "loop #{i}",
            tool_uses: [%{id: "u#{i}", name: "list", input: %{}}]
          }
        end)
      )

    assert {:error, :max_turns_exceeded} =
             Runner.run(
               plugin: "kv",
               worker: test_worker(%{max_turns: 2}),
               spec: spec,
               llm: Stub,
               on_event: collector()
             )

    events = drain_events()
    assert Enum.any?(events, &match?({:abort, %{reason: :max_turns_exceeded}}, &1))
  end

  test "aborts when LLM returns an error", %{spec: spec} do
    {:ok, _} = Stub.start_link([])

    assert {:error, {:llm_error, :stub_script_exhausted}} =
             Runner.run(
               plugin: "kv",
               worker: test_worker(),
               spec: spec,
               llm: Stub,
               on_event: collector()
             )
  end

  describe "when: gate" do
    test "skips run when when_sql returns no rows", %{spec: spec} do
      {:ok, _} = Stub.start_link([%{text: "should not be called"}])

      worker = test_worker(%{when_sql: "SELECT 1 FROM kv WHERE 1=0"})

      assert {:ok, :skipped} =
               Runner.run(
                 plugin: "kv",
                 worker: worker,
                 spec: spec,
                 llm: Stub,
                 on_event: collector()
               )

      events = drain_events()
      assert Enum.any?(events, &match?({:skipped, _}, &1))
      # LLM was never called
      assert Stub.recorded_calls() == []
      # Skipped runs do not write a log row
      assert log_rows() == []
    end

    test "runs when when_sql returns at least one row", %{spec: spec} do
      Sark.Plugin.DB.write!("kv", "INSERT INTO kv (key, value, updated_at) VALUES (?, ?, ?)", [
        "alpha",
        "1",
        "2026-04-30T00:00:00Z"
      ])

      {:ok, _} = Stub.start_link([%{text: "ok"}])

      worker = test_worker(%{when_sql: "SELECT 1 FROM kv LIMIT 1"})

      assert {:ok, %{stop_reason: :end_turn}} =
               Runner.run(
                 plugin: "kv",
                 worker: worker,
                 spec: spec,
                 llm: Stub,
                 on_event: collector()
               )
    end
  end

  describe "load: render" do
    test "renders prompt with single-row scalars + JSON aggregate", %{spec: spec} do
      Sark.Plugin.DB.write!("kv", "INSERT INTO kv (key, value, updated_at) VALUES (?, ?, ?)", [
        "k1",
        "v1",
        "2026-04-30T00:00:00Z"
      ])

      Sark.Plugin.DB.write!("kv", "INSERT INTO kv (key, value, updated_at) VALUES (?, ?, ?)", [
        "k2",
        "v2",
        "2026-04-30T00:00:00Z"
      ])

      {:ok, _} = Stub.start_link([%{text: "done"}])

      worker =
        test_worker(%{
          load_sql: """
          SELECT
            COUNT(*) AS total,
            json_group_array(json_object('key', key, 'value', value)) AS items
          FROM kv
          """,
          prompt: "total={{total}}\n{{#items}}{{key}}={{value}};{{/items}}"
        })

      assert {:ok, _} =
               Runner.run(
                 plugin: "kv",
                 worker: worker,
                 spec: spec,
                 llm: Stub,
                 on_event: collector()
               )

      events = drain_events()
      assert Enum.any?(events, &match?({:loaded, %{rows: 1}}, &1))

      [call | _] = Stub.recorded_calls()
      [%{role: :user, content: prompt}] = call.messages
      assert prompt =~ "total=2"
      assert prompt =~ "k1=v1;"
      assert prompt =~ "k2=v2;"
    end
  end

  describe "_worker_log" do
    test "writes a row on end_turn with stub usage", %{spec: spec} do
      {:ok, _} =
        Stub.start_link([
          %{
            text: "all done",
            usage: %{
              input_tokens: 100,
              output_tokens: 25,
              cache_read_tokens: 0,
              cache_creation_tokens: 50,
              service_tier: "standard"
            }
          }
        ])

      assert {:ok, _} =
               Runner.run(
                 plugin: "kv",
                 worker: test_worker(),
                 spec: spec,
                 llm: Stub,
                 on_event: collector()
               )

      [row] = log_rows()
      assert row["worker_name"] == "smoke"
      assert row["provider"] == "stub"
      assert row["stop_reason"] == "end_turn"
      assert row["turns"] == 1
      assert row["input_tokens"] == 100
      assert row["output_tokens"] == 25
      assert row["cache_creation_tokens"] == 50
      assert row["service_tier"] == "standard"
      assert row["error"] == nil
      assert row["final_output"] == "all done"
    end

    test "writes a row with NULL token cols when stub omits usage", %{spec: spec} do
      {:ok, _} = Stub.start_link([%{text: "ok"}])

      assert {:ok, _} =
               Runner.run(
                 plugin: "kv",
                 worker: test_worker(),
                 spec: spec,
                 llm: Stub,
                 on_event: collector()
               )

      [row] = log_rows()
      assert row["input_tokens"] == nil
      assert row["output_tokens"] == nil
      assert row["service_tier"] == nil
    end

    test "writes a row with stop_reason=max_turns_exceeded on cap hit", %{spec: spec} do
      {:ok, _} =
        Stub.start_link(
          Enum.map(1..5, fn i ->
            %{text: "loop #{i}", tool_uses: [%{id: "u#{i}", name: "list", input: %{}}]}
          end)
        )

      assert {:error, :max_turns_exceeded} =
               Runner.run(
                 plugin: "kv",
                 worker: test_worker(%{max_turns: 2}),
                 spec: spec,
                 llm: Stub,
                 on_event: collector()
               )

      [row] = log_rows()
      assert row["stop_reason"] == "max_turns_exceeded"
      assert row["error"] == nil
    end

    test "writes a row with stop_reason=error and error text on llm error", %{spec: spec} do
      {:ok, _} = Stub.start_link([])

      assert {:error, {:llm_error, _}} =
               Runner.run(
                 plugin: "kv",
                 worker: test_worker(),
                 spec: spec,
                 llm: Stub,
                 on_event: collector()
               )

      [row] = log_rows()
      assert row["stop_reason"] == "error"
      assert row["error"] =~ "stub_script_exhausted"
    end
  end

  defp log_rows do
    {:ok, _cols, rows} =
      Sark.Plugin.DB.read("kv", "SELECT * FROM _worker_log ORDER BY id", [])

    rows
  end
end
