defmodule Sark.Plugin.PipelineTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Pipeline

  describe "parse!/2" do
    test "minimal pipeline with one shell step" do
      p =
        Pipeline.parse!("ingest", %{
          "description" => "Pull hosts.",
          "steps" => [
            %{"shell" => "echo hi"}
          ]
        })

      assert p.name == :ingest
      assert p.description == "Pull hosts."
      assert p.steps == [%{kind: :shell, cmd: "echo hi", timeout_ms: nil}]
      assert p.schedule == nil
      assert p.when_sql == nil
      assert p.transactional == false
      assert p.env == []
      assert p.timeout_ms == nil
    end

    test "schedule parses cron when present" do
      p =
        Pipeline.parse!("ingest", %{
          "description" => "x",
          "schedule" => "0 3 * * *",
          "steps" => [%{"shell" => "echo hi"}]
        })

      assert %Crontab.CronExpression{} = p.schedule
    end

    test "schedule is optional → nil (unscheduled pipeline)" do
      p =
        Pipeline.parse!("manual", %{
          "description" => "x",
          "steps" => [%{"shell" => "echo hi"}]
        })

      assert p.schedule == nil
    end

    test "raises on bad cron" do
      assert_raise ArgumentError, ~r/invalid cron/, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "schedule" => "not a cron",
          "steps" => [%{"shell" => "echo hi"}]
        })
      end
    end

    test "missing description raises" do
      assert_raise ArgumentError, ~r/`description`/, fn ->
        Pipeline.parse!("p", %{"steps" => [%{"shell" => "echo hi"}]})
      end
    end

    test "missing steps raises" do
      assert_raise ArgumentError, ~r/`steps`/, fn ->
        Pipeline.parse!("p", %{"description" => "x"})
      end
    end

    test "empty steps raises" do
      assert_raise ArgumentError, ~r/at least one step/, fn ->
        Pipeline.parse!("p", %{"description" => "x", "steps" => []})
      end
    end

    test "rejects unknown step kind" do
      assert_raise ArgumentError, ~r/exactly one of shell.load.tool.llm/, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"python" => "import foo"}]
        })
      end
    end

    test "rejects step with multiple kinds" do
      assert_raise ArgumentError, ~r/exactly one of shell.load.tool.llm/, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"shell" => "echo", "tool" => "x"}]
        })
      end
    end

    test "transactional: true accepted" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "transactional" => true,
          "steps" => [%{"shell" => "echo hi"}]
        })

      assert p.transactional == true
    end

    test "env: parses list of valid env-var names" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "env" => ["HOME", "PATH", "ANTHROPIC_API_KEY"],
          "steps" => [%{"shell" => "echo hi"}]
        })

      assert p.env == ["HOME", "PATH", "ANTHROPIC_API_KEY"]
    end

    test "env: rejects non-uppercase names (catches `value` confusion)" do
      assert_raise ArgumentError, ~r/env var name/, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "env" => ["lowercase"],
          "steps" => [%{"shell" => "echo hi"}]
        })
      end
    end
  end

  describe "shell step" do
    test "shorthand cmd string" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"shell" => "ls /tmp"}]
        })

      assert [%{kind: :shell, cmd: "ls /tmp", timeout_ms: nil}] = p.steps
    end

    test "empty cmd rejected" do
      assert_raise ArgumentError, ~r/non-empty/, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"shell" => ""}]
        })
      end
    end
  end

  describe "load step" do
    test "compiles SELECT and tracks named params" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"load" => "SELECT * FROM kv WHERE key = :key"}]
        })

      assert [%{kind: :load, compiled_sql: sql, param_order: [:key]}] = p.steps
      assert sql == "SELECT * FROM kv WHERE key = ?"
    end

    test "rejects writes" do
      for bad <- ["INSERT INTO kv VALUES (1)", "UPDATE kv SET v=1", "DELETE FROM kv"] do
        assert_raise ArgumentError, ~r/read-only/, fn ->
          Pipeline.parse!("p", %{
            "description" => "x",
            "steps" => [%{"load" => bad}]
          })
        end
      end
    end

    test "WITH and PRAGMA allowed" do
      for ok <- ["WITH x AS (SELECT 1) SELECT * FROM x", "PRAGMA foreign_keys = ON"] do
        p =
          Pipeline.parse!("p", %{
            "description" => "x",
            "steps" => [%{"load" => ok}]
          })

        assert [%{kind: :load}] = p.steps
      end
    end
  end

  describe "tool step" do
    test "by name" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"tool" => "upsert_hosts"}]
        })

      assert [%{kind: :tool, tool: "upsert_hosts"}] = p.steps
    end
  end

  describe "llm step" do
    test "parses model/system/prompt/tools/max_turns" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [
            %{
              "llm" => %{
                "model" => "claude-haiku-4-5",
                "system" => "You are terse.",
                "prompt" => "Hi {{name}}",
                "tools" => ["list", "get"],
                "max_turns" => 5
              }
            }
          ]
        })

      assert [%{kind: :llm, model: "claude-haiku-4-5"} = step] = p.steps
      assert step.system == "You are terse."
      assert step.prompt == "Hi {{name}}"
      assert step.tools == ["list", "get"]
      assert step.max_turns == 5
    end

    test "mustache in system raises" do
      assert_raise ArgumentError, ~r/system.*mustache/i, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [
            %{
              "llm" => %{
                "model" => "m",
                "system" => "Today is {{today}}",
                "prompt" => "x",
                "tools" => []
              }
            }
          ]
        })
      end
    end

    test "max_turns defaults to a positive value" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [
            %{"llm" => %{"model" => "m", "prompt" => "p"}}
          ]
        })

      assert [%{kind: :llm, max_turns: n}] = p.steps
      assert n > 0
    end
  end

  describe "long-form step (per-step timeout)" do
    test "shell: { cmd: ..., timeout: ms }" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"shell" => %{"cmd" => "echo hi", "timeout" => 5000}}]
        })

      assert [%{kind: :shell, cmd: "echo hi", timeout_ms: 5000}] = p.steps
    end

    test "load: { sql: ..., timeout: ms }" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"load" => %{"sql" => "SELECT 1", "timeout" => 1000}}]
        })

      assert [%{kind: :load, timeout_ms: 1000}] = p.steps
    end

    test "tool: { name: ..., timeout: ms }" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"tool" => %{"name" => "put", "timeout" => 60_000}}]
        })

      assert [%{kind: :tool, tool: "put", timeout_ms: 60_000}] = p.steps
    end

    test "llm: timeout joins existing fields" do
      p =
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [
            %{
              "llm" => %{
                "model" => "m",
                "prompt" => "p",
                "tools" => [],
                "timeout" => 120_000
              }
            }
          ]
        })

      assert [%{kind: :llm, timeout_ms: 120_000}] = p.steps
    end

    test "unknown field in long-form step raises" do
      assert_raise ArgumentError, ~r/unknown step field/, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"shell" => %{"cmd" => "echo", "nope" => 1}}]
        })
      end
    end

    test "negative timeout raises" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Pipeline.parse!("p", %{
          "description" => "x",
          "steps" => [%{"shell" => %{"cmd" => "echo", "timeout" => -1}}]
        })
      end
    end
  end

  describe "pipeline-incompatible builtins" do
    test "rejects sark_pipelines_run_now in tool: step" do
      assert_raise ArgumentError,
                   ~r/sark_pipelines_run_now.*cannot be called from inside a pipeline/,
                   fn ->
                     Pipeline.parse!("p", %{
                       "description" => "x",
                       "steps" => [%{"tool" => "sark_pipelines_run_now"}]
                     })
                   end
    end

    test "rejects sark_pipelines_cancel in tool: step" do
      assert_raise ArgumentError,
                   ~r/sark_pipelines_cancel.*cannot be called from inside a pipeline/,
                   fn ->
                     Pipeline.parse!("p", %{
                       "description" => "x",
                       "steps" => [
                         %{
                           "tool" => %{
                             "name" => "sark_pipelines_cancel",
                             "params" => %{"pipeline" => "x"}
                           }
                         }
                       ]
                     })
                   end
    end

    test "rejects sark_pipelines_run_now in llm.tools allowlist" do
      assert_raise ArgumentError,
                   ~r/sark_pipelines_run_now.*cannot be called from inside a pipeline/,
                   fn ->
                     Pipeline.parse!("p", %{
                       "description" => "x",
                       "steps" => [
                         %{
                           "llm" => %{
                             "model" => "m",
                             "prompt" => "p",
                             "tools" => ["sark_pipelines_run_now"]
                           }
                         }
                       ]
                     })
                   end
    end

    test "rejects sark_pipelines_cancel in llm.tools allowlist" do
      assert_raise ArgumentError,
                   ~r/sark_pipelines_cancel.*cannot be called from inside a pipeline/,
                   fn ->
                     Pipeline.parse!("p", %{
                       "description" => "x",
                       "steps" => [
                         %{
                           "llm" => %{
                             "model" => "m",
                             "prompt" => "p",
                             "tools" => ["sark_pipelines_cancel"]
                           }
                         }
                       ]
                     })
                   end
    end

    test "other sark_* builtins still allowed (sark_sql, sark_patch, sark_pipelines_log_prune)" do
      for tool <-
            ~w(sark_sql sark_catalog sark_patch sark_pipelines_list sark_pipelines_log sark_pipelines_recent sark_pipelines_costs sark_pipelines_log_prune) do
        p =
          Pipeline.parse!("p", %{
            "description" => "x",
            "steps" => [%{"tool" => tool}]
          })

        assert [%{kind: :tool, tool: ^tool}] = p.steps
      end
    end
  end

  describe "multi-step pipelines" do
    test "preserves step order across kinds" do
      p =
        Pipeline.parse!("ingest", %{
          "description" => "x",
          "steps" => [
            %{"shell" => "git clone --depth=1 .."},
            %{"shell" => "python parse.py"},
            %{"tool" => "upsert_hosts"}
          ]
        })

      assert [
               %{kind: :shell, cmd: "git clone" <> _},
               %{kind: :shell, cmd: "python parse.py"},
               %{kind: :tool, tool: "upsert_hosts"}
             ] = p.steps
    end
  end
end
