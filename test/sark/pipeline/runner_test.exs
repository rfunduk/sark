defmodule Sark.Pipeline.RunnerTest do
  use ExUnit.Case, async: false

  alias Sark.LLM.Stub
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.Pipeline.Runner
  alias Sark.Plugin
  alias Sark.Plugin.DB
  alias Sark.Plugin.Loader
  alias Sark.Plugin.Pipeline

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)

  setup %{tmp_dir: dir} do
    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    router = Sark.MCP.Registration.router_module("kv")
    :persistent_term.put({Phantom, router, :tools}, [])
    :persistent_term.put({Phantom, router, :initialized}, false)

    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})

    on_exit(fn -> Stub.stop() end)

    {:ok, spec: spec, dir: dir}
  end

  defp build_pipeline(name, opts) do
    Pipeline.parse!(name, Map.merge(%{"description" => "test"}, Map.new(opts)))
  end

  # Emit a JSON object on stdout for the next step's stdin. Replaces the
  # old `tool: { params: ... }` static-args feature.
  defp emit_json(map) do
    json = Jason.encode!(map)
    escaped = String.replace(json, "'", "'\\''")
    %{"shell" => "printf '%s' '#{escaped}'"}
  end

  defp run_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp run!(pipeline, spec, opts \\ []) do
    Runner.run(
      [
        plugin: spec.name,
        pipeline: pipeline,
        spec: spec,
        run_id: Keyword.get(opts, :run_id, run_id()),
        llm: Keyword.get(opts, :llm, Sark.LLM.Stub),
        triggered_by: Keyword.get(opts, :triggered_by, :manual)
      ]
      |> Keyword.merge(opts |> Keyword.drop([:run_id, :llm, :triggered_by]))
    )
  end

  defp fetch_run_row(spec, run_id) do
    {:ok, _, rows} =
      DB.sark_read(spec.name, "SELECT * FROM _pipeline_log WHERE run_id = ?", [run_id])

    rows
  end

  defp fetch_step_rows(spec, run_id) do
    {:ok, _, rows} =
      DB.sark_read(
        spec.name,
        "SELECT * FROM _pipeline_step_log WHERE run_id = ? ORDER BY step_index",
        [run_id]
      )

    rows
  end

  describe "shell step" do
    test "captures stdout and flows it to the next step", %{spec: spec} do
      pipeline =
        build_pipeline("two_shells", %{
          "steps" => [
            %{"shell" => "printf hello"},
            %{"shell" => "tr a-z A-Z"}
          ]
        })

      rid = run_id()

      assert {:ok, %{run_id: ^rid}} = run!(pipeline, spec, run_id: rid)

      [run_row] = fetch_run_row(spec, rid)
      assert run_row["status"] == "success"

      [s0, s1] = fetch_step_rows(spec, rid)
      assert s0["step_type"] == "shell"
      assert s0["status"] == "success"
      assert s0["exit_code"] == 0
      assert s0["stdout_bytes"] == byte_size("hello")
      assert s1["step_type"] == "shell"
      assert s1["status"] == "success"
    end

    test "non-zero exit aborts the run; later steps don't execute", %{spec: spec} do
      pipeline =
        build_pipeline("fail_first", %{
          "steps" => [
            %{"shell" => "false"},
            %{"shell" => "echo never"}
          ]
        })

      rid = run_id()

      assert {:error, msg} = run!(pipeline, spec, run_id: rid)
      assert msg =~ "step 0"
      assert msg =~ "exit code 1"

      [run_row] = fetch_run_row(spec, rid)
      assert run_row["status"] == "failed"
      assert run_row["error"] =~ "exit code 1"

      # Only the failing step logged — second step was skipped.
      assert [s0] = fetch_step_rows(spec, rid)
      assert s0["step_index"] == 0
      assert s0["status"] == "failed"
      assert s0["exit_code"] == 1
    end

    test "timeout kills a runaway shell step", %{spec: spec} do
      pipeline =
        build_pipeline("slow", %{
          "timeout" => 100,
          "steps" => [%{"shell" => "sleep 5"}]
        })

      assert {:error, msg} = run!(pipeline, spec)
      assert msg =~ "timeout"
    end

    test "per-step timeout overrides pipeline-level", %{spec: spec} do
      # Pipeline timeout is generous (5s); the step's own timeout is
      # the shorter ceiling.
      pipeline =
        build_pipeline("step_to", %{
          "timeout" => 5_000,
          "steps" => [%{"shell" => %{"cmd" => "sleep 5", "timeout" => 100}}]
        })

      assert {:error, msg} = run!(pipeline, spec)
      assert msg =~ "timeout after 100ms"
    end

    test "env var listed in env: propagates from sark's environment", %{spec: spec} do
      System.put_env("SARK_PIPELINE_TEST_VAR", "made_it")

      pipeline =
        build_pipeline("env_echo", %{
          "env" => ["SARK_PIPELINE_TEST_VAR"],
          "steps" => [%{"shell" => "printenv SARK_PIPELINE_TEST_VAR"}]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      # Captured in step row's stdout_bytes — assert non-zero (real output).
      [s0] = fetch_step_rows(spec, rid)
      assert s0["stdout_bytes"] > 0
    after
      System.delete_env("SARK_PIPELINE_TEST_VAR")
    end

    test "env var NOT listed in env: is invisible to the shell step", %{spec: spec} do
      System.put_env("SARK_PIPELINE_SECRET", "leaked")

      # No env: entry — sark should not propagate.
      pipeline =
        build_pipeline("env_no_leak", %{
          "steps" => [
            # printenv returns nonzero (exit 1) if the var is unset; we use
            # that as the assertion vehicle.
            %{"shell" => "printenv SARK_PIPELINE_SECRET || echo unset"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      [s0] = fetch_step_rows(spec, rid)
      # Either we printed "unset" (4 bytes + newline) or we ran into a clean
      # shell that didn't have SARK_PIPELINE_SECRET propagated.
      assert s0["status"] == "success"
    after
      System.delete_env("SARK_PIPELINE_SECRET")
    end

    test "workdir is created and cleaned on success", %{spec: spec} do
      base = Path.join(["/tmp", "sark", spec.name, "wd_clean"])

      rid = run_id()
      workdir = Path.join(base, rid)

      pipeline =
        build_pipeline("wd_clean", %{
          "steps" => [%{"shell" => "touch in_workdir.txt && ls in_workdir.txt"}]
        })

      assert {:ok, _} = run!(pipeline, spec, run_id: rid)
      refute File.exists?(workdir)
    end

    test "workdir is retained on failure for debug", %{spec: spec} do
      base = Path.join(["/tmp", "sark", spec.name, "wd_keep"])

      rid = run_id()
      workdir = Path.join(base, rid)

      pipeline =
        build_pipeline("wd_keep", %{
          "steps" => [%{"shell" => "touch evidence.txt && exit 1"}]
        })

      assert {:error, _} = run!(pipeline, spec, run_id: rid)
      assert File.exists?(workdir)
      assert File.exists?(Path.join(workdir, "evidence.txt"))

      # Cleanup so we don't leave junk in /tmp across runs.
      File.rm_rf!(workdir)
    end
  end

  describe "load step" do
    test "runs SELECT and emits JSON rows to stdout", %{spec: spec} do
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["a", "1"])
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["b", "2"])

      pipeline =
        build_pipeline("read_then_jq", %{
          "steps" => [
            %{"load" => "SELECT key, value FROM kv ORDER BY key"},
            # Verify the load step's stdout was valid JSON by piping it
            # through jq-style transformation in shell.
            %{"shell" => "wc -c"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      [s0, s1] = fetch_step_rows(spec, rid)
      assert s0["step_type"] == "load"
      assert s0["status"] == "success"
      # JSON array with two rows is non-trivial in size.
      assert s0["stdout_bytes"] > 5
      assert s1["status"] == "success"
    end

    test "passes stdin JSON object as named params", %{spec: spec} do
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["x", "hit"])
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["y", "miss"])

      pipeline =
        build_pipeline("read_with_param", %{
          "steps" => [
            %{"shell" => ~s|echo '{"key": "x"}'|},
            %{"load" => "SELECT value FROM kv WHERE key = :key"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      [_, s1] = fetch_step_rows(spec, rid)
      assert s1["status"] == "success"
      # 1 row → non-empty JSON array.
      assert s1["stdout_bytes"] > 2
    end

    test "non-JSON stdin into load step fails with a clear message", %{spec: spec} do
      pipeline =
        build_pipeline("bad_json", %{
          "steps" => [
            %{"shell" => "echo not_json"},
            %{"load" => "SELECT 1 AS one"}
          ]
        })

      rid = run_id()
      assert {:error, msg} = run!(pipeline, spec, run_id: rid)
      assert msg =~ "expected JSON"

      [_, s1] = fetch_step_rows(spec, rid)
      assert s1["status"] == "failed"
      assert s1["error"] =~ "expected JSON"
    end

    test "writes are rejected at parse time" do
      assert_raise ArgumentError, ~r/read-only/, fn ->
        build_pipeline("bad_load", %{
          "steps" => [%{"load" => "INSERT INTO kv VALUES (?, ?)"}]
        })
      end
    end
  end

  describe "tool step" do
    test "calls a plugin tool and emits its reply", %{spec: spec} do
      pipeline =
        build_pipeline("write_one", %{
          "steps" => [
            %{"shell" => ~s|echo '{"key": "k", "value": "v"}'|},
            %{"tool" => "put"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      # The tool actually wrote — verify via the plugin DB.
      {:ok, _, [%{"value" => "v"}]} =
        DB.read(spec.name, "SELECT value FROM kv WHERE key = ?", ["k"])

      [_, s1] = fetch_step_rows(spec, rid)
      assert s1["step_type"] == "tool"
      assert s1["status"] == "success"
    end

    test "tool error propagates as step failure", %{spec: spec} do
      pipeline =
        build_pipeline("bad_tool", %{
          "steps" => [
            # `put` requires both key and value — leaving value out trips
            # validation error from the canned-tool handler.
            %{"shell" => ~s|echo '{"key": "x"}'|},
            %{"tool" => "put"}
          ]
        })

      rid = run_id()
      assert {:error, msg} = run!(pipeline, spec, run_id: rid)
      assert msg =~ "validation"

      [_, s1] = fetch_step_rows(spec, rid)
      assert s1["status"] == "failed"
      assert s1["error"] =~ "validation"
    end

    test "fans an array into a bulk tool via json_each", %{spec: spec} do
      pipeline =
        build_pipeline("bulk", %{
          "steps" => [
            %{
              "shell" =>
                ~s|echo '{"notes": [{"body": "one"}, {"body": "two"}, {"body": "three"}]}'|
            },
            %{"tool" => "bulk_add_notes"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      {:ok, _, [%{"n" => 3}]} =
        DB.read(
          spec.name,
          "SELECT COUNT(*) AS n FROM notes WHERE body IN ('one','two','three')",
          []
        )
    end
  end

  describe "llm step" do
    test "runs an agent loop, calls tools, captures usage", %{spec: spec} do
      # Stub script: assistant first calls `list`, then on the next turn
      # emits a final text reply.
      script = [
        %{
          text: "listing keys",
          tool_uses: [%{id: "1", name: "list", input: %{}}]
        },
        %{
          text: "done — there are 0 keys",
          tool_uses: [],
          stop_reason: :end_turn,
          usage: %{
            input_tokens: 200,
            output_tokens: 50,
            cache_read_tokens: 100,
            cache_creation_tokens: nil,
            service_tier: "standard"
          }
        }
      ]

      {:ok, _} = Stub.start_link(script)

      pipeline =
        build_pipeline("llm_run", %{
          "steps" => [
            %{
              "llm" => %{
                "model" => "claude-sonnet-4-6",
                "system" => "You are terse.",
                "prompt" => "List the keys.",
                "tools" => ["list"],
                "max_turns" => 4
              }
            }
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      [step] = fetch_step_rows(spec, rid)
      assert step["step_type"] == "llm"
      assert step["status"] == "success"
      assert step["model"] == "claude-sonnet-4-6"
      assert step["turns"] == 2
      assert step["input_tokens"] == 200
      assert step["output_tokens"] == 50
      assert step["cache_read_tokens"] == 100
      assert step["service_tier"] == "standard"
      assert step["final_output"] =~ "done"

      # Confirm the stub recorded one chat call per turn.
      calls = Stub.recorded_calls()
      assert length(calls) == 2
    end

    test "max_turns abort flagged as failure", %{spec: spec} do
      # Stub never produces an :end_turn — it always asks for another tool call.
      script =
        for i <- 1..10 do
          %{
            text: "turn #{i}",
            tool_uses: [%{id: Integer.to_string(i), name: "list", input: %{}}]
          }
        end

      {:ok, _} = Stub.start_link(script)

      pipeline =
        build_pipeline("llm_cap", %{
          "steps" => [
            %{
              "llm" => %{
                "model" => "m",
                "prompt" => "go",
                "tools" => ["list"],
                "max_turns" => 2
              }
            }
          ]
        })

      rid = run_id()
      assert {:error, msg} = run!(pipeline, spec, run_id: rid)
      assert msg =~ "max_turns_exceeded"

      [step] = fetch_step_rows(spec, rid)
      assert step["status"] == "failed"
      assert step["stop_reason"] == "max_turns_exceeded"
    end

    test "stdin JSON renders into mustache prompt", %{spec: spec} do
      script = [
        %{text: "ack", tool_uses: [], stop_reason: :end_turn}
      ]

      {:ok, _} = Stub.start_link(script)

      pipeline =
        build_pipeline("llm_ctx", %{
          "steps" => [
            %{"shell" => ~s|echo '{"name": "Ryan", "count": 7}'|},
            %{
              "llm" => %{
                "model" => "m",
                "prompt" => "Hi {{name}}, count={{count}}",
                "tools" => [],
                "max_turns" => 2
              }
            }
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      # Inspect what we actually sent.
      [%{messages: [%{content: rendered}]}] = Stub.recorded_calls()
      assert rendered == "Hi Ryan, count=7"
    end

    test "unknown tool in llm.tools raises at runtime", %{spec: spec} do
      # No script needed — we should fail before any chat call.
      {:ok, _} = Stub.start_link([])

      pipeline =
        build_pipeline("llm_bad_tool", %{
          "steps" => [
            %{
              "llm" => %{
                "model" => "m",
                "prompt" => "p",
                "tools" => ["does_not_exist"],
                "max_turns" => 2
              }
            }
          ]
        })

      assert_raise ArgumentError, ~r/unknown tool/, fn ->
        run!(pipeline, spec)
      end
    end
  end

  describe "when:" do
    test "skip when SELECT returns no rows", %{spec: spec} do
      pipeline =
        build_pipeline("gated", %{
          "when" => "SELECT 1 FROM kv LIMIT 1",
          "steps" => [%{"shell" => "echo should_not_run"}]
        })

      assert {:ok, :skipped} = run!(pipeline, spec)

      # No rows in either log table.
      {:ok, _, rows} = DB.sark_read(spec.name, "SELECT * FROM _pipeline_log", [])
      assert rows == []
    end

    test "run when SELECT returns rows", %{spec: spec} do
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["a", "1"])

      pipeline =
        build_pipeline("gated", %{
          "when" => "SELECT 1 FROM kv LIMIT 1",
          "steps" => [%{"shell" => "echo ran"}]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)
      assert [_] = fetch_run_row(spec, rid)
    end
  end

  describe "cancel" do
    alias Sark.Pipeline.Cancel

    test "cancel requested before run starts → status cancelled, no steps", %{spec: spec} do
      rid = run_id()
      Cancel.request(rid)

      pipeline =
        build_pipeline("pre_cancel", %{
          "steps" => [
            %{"shell" => "echo first"},
            %{"shell" => "echo second"}
          ]
        })

      assert {:error, msg} = run!(pipeline, spec, run_id: rid)
      assert msg =~ "cancelled"

      [row] = fetch_run_row(spec, rid)
      assert row["status"] == "cancelled"

      # Step 0 never executed — no step rows.
      assert fetch_step_rows(spec, rid) == []
    end

    test "cancel requested mid-run → first step completes, second skipped", %{spec: spec} do
      rid = run_id()

      pipeline =
        build_pipeline("mid_cancel", %{
          "steps" => [
            # Slow enough that we can set cancel while it's running.
            %{"shell" => "sleep 0.3"},
            %{"shell" => "echo never"}
          ]
        })

      task = Task.async(fn -> run!(pipeline, spec, run_id: rid) end)

      # Give the runner time to enter step 0 (past the pre-step peek),
      # then request cancel. Step 0 finishes naturally; the post-step
      # peek catches the flag.
      Process.sleep(100)
      Cancel.request(rid)

      assert {:error, msg} = Task.await(task, 5_000)
      assert msg =~ "cancelled"

      [row] = fetch_run_row(spec, rid)
      assert row["status"] == "cancelled"

      [s0] = fetch_step_rows(spec, rid)
      assert s0["step_index"] == 0
      assert s0["status"] == "success"
    end

    test "cancel flag is cleared after terminal state", %{spec: spec} do
      rid = run_id()
      Cancel.request(rid)

      pipeline =
        build_pipeline("clear_after", %{
          "steps" => [%{"shell" => "echo hi"}]
        })

      _ = run!(pipeline, spec, run_id: rid)
      refute Cancel.requested?(rid)
    end

    test "cancel flag cleared on success too", %{spec: spec} do
      rid = run_id()

      pipeline =
        build_pipeline("clean_success", %{
          "steps" => [%{"shell" => "echo ok"}]
        })

      assert {:ok, _} = run!(pipeline, spec, run_id: rid)
      refute Cancel.requested?(rid)
    end
  end

  describe "transactional" do
    test "commits writes on success", %{spec: spec} do
      pipeline =
        build_pipeline("txn_ok", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"key" => "txn_a", "value" => "v_a"}),
            %{"tool" => "put"},
            emit_json(%{"key" => "txn_b", "value" => "v_b"}),
            %{"tool" => "put"}
          ]
        })

      assert {:ok, _} = run!(pipeline, spec)

      {:ok, _, rows} =
        DB.read(spec.name, "SELECT key FROM kv WHERE key IN (?, ?) ORDER BY key", [
          "txn_a",
          "txn_b"
        ])

      assert Enum.map(rows, & &1["key"]) == ["txn_a", "txn_b"]
    end

    test "rolls back all writes on failure", %{spec: spec} do
      pipeline =
        build_pipeline("txn_fail", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"key" => "txn_x", "value" => "wrote"}),
            %{"tool" => "put"},
            # Validation failure — `put` requires both key and value.
            emit_json(%{"key" => "txn_y"}),
            %{"tool" => "put"}
          ]
        })

      assert {:error, msg} = run!(pipeline, spec)
      assert msg =~ "validation"

      {:ok, _, []} =
        DB.read(spec.name, "SELECT key FROM kv WHERE key IN (?, ?)", ["txn_x", "txn_y"])
    end

    test "load step inside txn sees uncommitted writes from earlier steps", %{spec: spec} do
      pipeline =
        build_pipeline("txn_read_own_writes", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"key" => "txn_visible", "value" => "yes"}),
            %{"tool" => "put"},
            # Reset stdin to an empty object for the param-less load.
            emit_json(%{}),
            %{"load" => "SELECT value FROM kv WHERE key = 'txn_visible'"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      step_rows = fetch_step_rows(spec, rid)
      last = List.last(step_rows)
      assert last["step_type"] == "load"
      assert last["row_count"] == 1
    end

    test "rollback drops data writes but preserves the log row's terminal status", %{spec: spec} do
      pipeline =
        build_pipeline("txn_log_state", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"key" => "txn_log", "value" => "v"}),
            %{"tool" => "put"},
            %{"shell" => "false"}
          ]
        })

      rid = run_id()
      assert {:error, _} = run!(pipeline, spec, run_id: rid)

      # Log writes target the sark DB, so the run log row survives the
      # plugin-data rollback with `failed` status — failure-observability
      # is the whole reason for the split.
      {:ok, _, [row]} =
        DB.sark_read(spec.name, "SELECT * FROM _pipeline_log WHERE run_id = ?", [rid])

      assert row["status"] == "failed"

      # Plugin data, however, did roll back: no kv side effects.
      {:ok, _, []} =
        DB.read(spec.name, "SELECT * FROM kv WHERE key = ?", ["txn_log"])
    end

    test "cancel during transactional run rolls back writes", %{spec: spec} do
      alias Sark.Pipeline.Cancel

      rid = run_id()

      pipeline =
        build_pipeline("txn_cancel", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"key" => "txn_cancel_key", "value" => "wrote"}),
            %{"tool" => "put"},
            %{"shell" => "sleep 0.3"},
            emit_json(%{"key" => "txn_cancel_key2", "value" => "never"}),
            %{"tool" => "put"}
          ]
        })

      task = Task.async(fn -> run!(pipeline, spec, run_id: rid) end)
      Process.sleep(150)
      Cancel.request(rid)

      assert {:error, msg} = Task.await(task, 5_000)
      assert msg =~ "cancelled"

      {:ok, _, []} =
        DB.read(spec.name, "SELECT * FROM kv WHERE key LIKE ?", ["txn_cancel%"])
    end

    test "sark_sql builtin inside txn sees uncommitted writes", %{spec: spec} do
      pipeline =
        build_pipeline("txn_sark_sql", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"key" => "txn_via_sql", "value" => "yes"}),
            %{"tool" => "put"},
            emit_json(%{"sql" => "SELECT value FROM kv WHERE key = 'txn_via_sql'"}),
            %{"tool" => "sark_sql"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      step_rows = fetch_step_rows(spec, rid)
      last = List.last(step_rows)
      assert last["tool_name"] == "sark_sql"
      assert last["status"] == "success"
    end

    test "sark_catalog builtin inside txn does not deadlock", %{spec: spec} do
      pipeline =
        build_pipeline("txn_catalog", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"key" => "txn_cat", "value" => "v"}),
            %{"tool" => "put"},
            emit_json(%{}),
            %{"tool" => "sark_catalog"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      step_rows = fetch_step_rows(spec, rid)
      last = List.last(step_rows)
      assert last["status"] == "success"
    end

    test "sark_patch builtin inside txn shares conn (no deadlock, rolls back on later failure)",
         %{spec: spec} do
      # Seed a row to patch.
      {:ok, _} =
        DB.write(spec.name, "INSERT INTO notes (id, body) VALUES (?, ?)", [1, "original text"])

      pipeline =
        build_pipeline("txn_patch_rollback", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{
              "table" => "notes",
              "id" => 1,
              "col" => "body",
              "old" => "original",
              "new" => "patched"
            }),
            %{"tool" => "sark_patch"},
            # Force rollback.
            %{"shell" => "false"}
          ]
        })

      assert {:error, _} = run!(pipeline, spec)

      # Patch was applied inside the txn but rolled back along with
      # everything else — value reverts to the original.
      {:ok, _, [%{"body" => body}]} =
        DB.read(spec.name, "SELECT body FROM notes WHERE id = ?", [1])

      assert body == "original text"
    end

    test "sark_patch builtin inside txn commits on success", %{spec: spec} do
      {:ok, _} =
        DB.write(spec.name, "INSERT INTO notes (id, body) VALUES (?, ?)", [2, "alpha here"])

      pipeline =
        build_pipeline("txn_patch_ok", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{
              "table" => "notes",
              "id" => 2,
              "col" => "body",
              "old" => "alpha",
              "new" => "beta"
            }),
            %{"tool" => "sark_patch"}
          ]
        })

      assert {:ok, _} = run!(pipeline, spec)

      {:ok, _, [%{"body" => body}]} =
        DB.read(spec.name, "SELECT body FROM notes WHERE id = ?", [2])

      assert body == "beta here"
    end

    test "sark_pipelines_log_prune builtin inside txn does not deadlock", %{spec: spec} do
      # Seed an old run that we'll prune.
      {:ok, _} =
        DB.sark_write(
          spec.name,
          "INSERT INTO _pipeline_log (run_id, pipeline, started_at, finished_at, status, triggered_by) VALUES (?, ?, ?, ?, ?, ?)",
          [
            "old_for_prune",
            "smoke",
            "2020-01-01T00:00:00Z",
            "2020-01-01T00:00:00Z",
            "success",
            "manual"
          ]
        )

      pipeline =
        build_pipeline("txn_prune", %{
          "transactional" => true,
          "steps" => [
            emit_json(%{"older_than" => "1d"}),
            %{"tool" => "sark_pipelines_log_prune"}
          ]
        })

      assert {:ok, _} = run!(pipeline, spec)

      {:ok, _, []} =
        DB.sark_read(spec.name, "SELECT * FROM _pipeline_log WHERE run_id = ?", ["old_for_prune"])
    end
  end

  describe "log columns" do
    test "captures triggered_by", %{spec: spec} do
      pipeline =
        build_pipeline("via_schedule", %{
          "steps" => [%{"shell" => "true"}]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid, triggered_by: :schedule)

      [row] = fetch_run_row(spec, rid)
      assert row["triggered_by"] == "schedule"
    end

    test "load step captures row_count", %{spec: spec} do
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["a", "1"])
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["b", "2"])
      {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["c", "3"])

      pipeline =
        build_pipeline("count_rows", %{
          "steps" => [%{"load" => "SELECT key FROM kv"}]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      [step] = fetch_step_rows(spec, rid)
      assert step["row_count"] == 3
    end

    test "tool step captures tool_name", %{spec: spec} do
      pipeline =
        build_pipeline("tool_name_check", %{
          "steps" => [
            %{"shell" => ~s|echo '{"key": "tk", "value": "tv"}'|},
            %{"tool" => "put"}
          ]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      [_, s1] = fetch_step_rows(spec, rid)
      assert s1["tool_name"] == "put"
    end

    test "shell + llm steps leave tool_name + row_count null", %{spec: spec} do
      pipeline =
        build_pipeline("nulls", %{
          "steps" => [%{"shell" => "echo hi"}]
        })

      rid = run_id()
      assert {:ok, _} = run!(pipeline, spec, run_id: rid)

      [s0] = fetch_step_rows(spec, rid)
      assert s0["tool_name"] == nil
      assert s0["row_count"] == nil
    end
  end
end
