defmodule Sark.Pipeline.Runner do
  @moduledoc """
  Drives one pipeline to terminal state — schedules steps, captures
  their stdout, threads it as stdin to the next, writes
  `_pipeline_log` + `_pipeline_step_log` rows via `LogWriter`, cleans
  up the workdir.

  Intended to be invoked under `Sark.Pipeline.Watcher` (which spawns
  this as a `Task` and applies uniform kill semantics — pipeline
  timeout / cancel / step timeout all converge on
  `Task.shutdown(:brutal_kill)`). Runner has no knowledge of cancel
  or whole-pipeline timeout: those live in the watcher. Runner only
  knows per-step `timeout:` and translates it to a self-exit
  (`{:step_timeout, idx}`) via a sibling killer process.

  Order of operations:

    1. `when:` gate — if defined, run a SELECT on the read pool.
       Empty result set → `{:ok, :skipped}` with no log row.
    2. Emit a `start_run` cast to LogWriter (terminal `finish_run`
       comes from the watcher).
    3. Prepare workdir at `/tmp/sark/{plugin}/{pipeline}/{run_id}/`
       (or the pipeline's `workdir:` override).
    4. For each step, execute and capture output. Output of step N
       becomes stdin of step N+1; first step receives no stdin.
    5. On any step failure, abort — remaining steps are skipped, and
       a step log row records the failure.
    6. Cleanup workdir on success (kept on failure for debug).

  Pipe convention:
    * `shell:` → emits raw bytes; consumes raw bytes
    * `load:` / `tool:` / `llm:` → consume JSON on stdin; emit a
      string (JSON rows array / tool reply text / final assistant text)

  Steps that consume JSON on stdin (`load:` / `tool:` / `llm:`) parse
  it once; non-JSON input errors with a clear step-level message.

  Returns one of:

    * `{:ok, %{run_id: id}}`   — every step completed
    * `{:ok, :skipped}`        — `when:` gate empty (no log row)
    * `{:error, msg}`          — step failure, when-gate error, txn
                                 rollback. `_pipeline_log` row still
                                 needs `finish_run` from the watcher.
  """

  require Logger

  alias Sark.LLM.Response
  alias Sark.MCP.Internal
  alias Sark.Plugin.DB
  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Spec
  alias Sark.Pipeline.LogWriter
  alias Sark.Pipeline.Template

  @type triggered_by :: :schedule | :manual

  @type event ::
          {:run_start, %{run_id: String.t(), pipeline: atom}}
          | {:step_start, %{index: non_neg_integer, kind: atom}}
          | {:step_ok, %{index: non_neg_integer, kind: atom, bytes: non_neg_integer}}
          | {:step_fail, %{index: non_neg_integer, kind: atom, error: String.t()}}
          | {:assistant_text, String.t()}
          | {:tool_call, %{id: String.t(), name: String.t(), input: map}}
          | {:tool_result, %{id: String.t(), ok: boolean, text: String.t()}}
          | {:skipped, %{reason: :when_gate}}
          | {:run_ok, %{run_id: String.t()}}
          | {:run_fail, %{run_id: String.t(), error: String.t()}}

  @type opts :: [
          plugin: String.t(),
          pipeline: Pipeline.t(),
          spec: Spec.t(),
          run_id: String.t(),
          llm: module,
          triggered_by: triggered_by,
          on_event: (event -> any),
          max_tokens: pos_integer
        ]

  @default_max_tokens 4096

  @spec run(opts) ::
          {:ok, %{run_id: String.t()}}
          | {:ok, :skipped}
          | {:error, term}
  def run(opts) do
    plugin = Keyword.fetch!(opts, :plugin)
    %Pipeline{} = pipeline = Keyword.fetch!(opts, :pipeline)
    %Spec{} = spec = Keyword.fetch!(opts, :spec)
    run_id = Keyword.fetch!(opts, :run_id)
    llm = Keyword.get(opts, :llm, Sark.LLM.Anthropix)
    triggered_by = Keyword.get(opts, :triggered_by, :manual)
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    case evaluate_when(plugin, pipeline.when_sql) do
      :skip ->
        on_event.({:skipped, %{reason: :when_gate}})
        {:ok, :skipped}

      {:error, reason} ->
        # Emit a start_run cast so the watcher's finish_run UPDATE has
        # a row to target. Then return the failure.
        :ok = emit_start_run(plugin, pipeline, run_id, triggered_by)
        msg = "when_gate: #{inspect(reason)}"
        on_event.({:run_fail, %{run_id: run_id, error: msg}})
        {:error, msg}

      {:run, _} ->
        do_run(plugin, pipeline, spec, run_id, llm, triggered_by, on_event, max_tokens)
    end
  end

  defp do_run(plugin, pipeline, spec, run_id, llm, triggered_by, on_event, max_tokens) do
    on_event.({:run_start, %{run_id: run_id, pipeline: pipeline.name}})

    workdir = ensure_workdir!(plugin, pipeline, run_id)
    env = sourced_env(pipeline.env)

    base_state = %{
      plugin: plugin,
      pipeline: pipeline,
      spec: spec,
      run_id: run_id,
      triggered_by: triggered_by,
      llm: llm,
      max_tokens: max_tokens,
      on_event: on_event,
      workdir: workdir,
      env: env,
      conn: nil
    }

    :ok = emit_start_run(plugin, pipeline, run_id, triggered_by)
    execute_pipeline(base_state)
  end

  # ── transactional vs non-transactional dispatch ────────────────────────────

  defp execute_pipeline(%{pipeline: %Pipeline{transactional: false}} = state) do
    finalize(state, run_steps(state))
  end

  # Transactional path: open one writer txn on the plugin's data DB for
  # the run's data writes. Log writes target the plugin's sark DB on a
  # separate writer (owned by LogWriter), independent of the data txn.
  defp execute_pipeline(%{plugin: plugin} = state) do
    result =
      DB.txn(
        plugin,
        fn conn ->
          s = %{state | conn: conn}

          case run_steps(s) do
            :ok -> :ok
            {:error, _} = e -> DBConnection.rollback(conn, e)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, :ok} ->
        finalize(state, :ok)

      {:error, {:error, msg}} ->
        finalize(state, {:error, msg})

      {:error, other} ->
        finalize(state, {:error, "txn: #{inspect(other)}"})
    end
  end

  defp emit_start_run(plugin, %Pipeline{} = pipeline, run_id, triggered_by) do
    LogWriter.start_run(plugin, %{
      run_id: run_id,
      pipeline: pipeline.name,
      started_at: now_iso8601(),
      triggered_by: triggered_by
    })
  end

  defp finalize(%{on_event: on_event, run_id: run_id, workdir: workdir}, :ok) do
    cleanup_workdir(workdir)
    on_event.({:run_ok, %{run_id: run_id}})
    {:ok, %{run_id: run_id}}
  end

  defp finalize(%{on_event: on_event, run_id: run_id}, {:error, msg}) do
    on_event.({:run_fail, %{run_id: run_id, error: msg}})
    {:error, msg}
  end

  # ── when gate ──────────────────────────────────────────────────────────────

  defp evaluate_when(_plugin, nil), do: {:run, []}

  defp evaluate_when(plugin, sql) when is_binary(sql) do
    case DB.read(plugin, sql, []) do
      {:ok, _cols, []} -> :skip
      {:ok, _cols, rows} -> {:run, rows}
      {:error, _} = err -> err
    end
  end

  # ── step loop ──────────────────────────────────────────────────────────────

  defp run_steps(state) do
    state.pipeline.steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, ""}, fn {step, idx}, {:ok, stdin} ->
      run_one_step(step, idx, stdin, state)
    end)
    |> case do
      {:ok, _final_stdout} -> :ok
      {:error, _} = err -> err
    end
  end

  defp run_one_step(step, idx, stdin, state) do
    state.on_event.({:step_start, %{index: idx, kind: step.kind}})
    started_at = now_iso8601()

    case run_step(step, idx, stdin, state) do
      {:ok, stdout, extras} ->
        :ok =
          LogWriter.record_step(
            state.plugin,
            base_step_entry(state.run_id, idx, step.kind, started_at, :success, nil)
            |> Map.put(:stdout_bytes, byte_size(stdout))
            |> Map.merge(extras)
          )

        state.on_event.({:step_ok, %{index: idx, kind: step.kind, bytes: byte_size(stdout)}})
        {:cont, {:ok, stdout}}

      {:error, msg, extras} ->
        :ok =
          LogWriter.record_step(
            state.plugin,
            base_step_entry(state.run_id, idx, step.kind, started_at, :failed, msg)
            |> Map.merge(extras)
          )

        state.on_event.({:step_fail, %{index: idx, kind: step.kind, error: msg}})
        {:halt, {:error, "step #{idx} (#{step.kind}): #{msg}"}}
    end
  end

  defp base_step_entry(run_id, idx, kind, started_at, status, error) do
    %{
      run_id: run_id,
      step_index: idx,
      step_type: kind,
      started_at: started_at,
      finished_at: now_iso8601(),
      status: status,
      error: error
    }
  end

  # ── per-step dispatch ──────────────────────────────────────────────────────

  defp run_step(%{kind: :shell, cmd: cmd} = step, idx, stdin, state) do
    fun = fn -> shell_exec(cmd, stdin, state.workdir, state.env) end

    case with_step_timer(step, idx, fun) do
      {:ok, stdout, exit_code} ->
        {:ok, stdout, %{exit_code: exit_code}}

      {:error, msg, exit_code, stderr_tail} ->
        {:error, msg, %{exit_code: exit_code, stderr_tail: stderr_tail}}
    end
  end

  defp run_step(%{kind: :load} = step, idx, stdin, state) do
    with_step_timer(step, idx, fn -> load_body(step, stdin, state) end)
  end

  defp run_step(%{kind: :tool, tool: name} = step, idx, stdin, state) do
    with_step_timer(step, idx, fn -> tool_body(step, name, stdin, state) end)
  end

  defp run_step(%{kind: :llm} = step, idx, stdin, state) do
    with_step_timer(step, idx, fn -> llm_body(step, stdin, state) end)
  end

  # Per-step timeout: spawn a killer process that exits the runner
  # process with `{:step_timeout, idx}` when the deadline elapses.
  # On step success the runner sends `:cancel` to the killer so it
  # exits cleanly. If the killer fires first, the watcher above the
  # runner sees `Task.yield` return `{:exit, {:step_timeout, idx}}`.
  #
  # spawn_link: killer dies if runner dies (and vice versa for any
  # crash of killer — but killer is trivial; won't crash).
  defp with_step_timer(%{timeout_ms: nil}, _idx, fun), do: fun.()

  defp with_step_timer(%{timeout_ms: ms}, idx, fun) when is_integer(ms) and ms > 0 do
    parent = self()

    killer =
      spawn_link(fn ->
        receive do
          :cancel -> :ok
        after
          ms -> Process.exit(parent, {:step_timeout, idx})
        end
      end)

    try do
      fun.()
    after
      send(killer, :cancel)
    end
  end

  defp load_body(step, stdin, state) do
    with {:ok, params_map} <- decode_json_stdin(stdin, "load"),
         {:ok, binds} <- bind_load_params(step, params_map),
         {:ok, _cols, rows} <-
           DB.read(state.plugin, step.compiled_sql, binds, read_opts(state)) do
      {:ok, Jason.encode!(rows), %{row_count: length(rows)}}
    else
      {:error, %Exqlite.Error{message: msg}} ->
        {:error, "sql: #{msg}", %{}}

      {:error, msg} when is_binary(msg) ->
        {:error, msg, %{}}

      {:error, msg} ->
        {:error, inspect(msg), %{}}
    end
  end

  defp tool_body(_step, name, stdin, state) do
    case decode_json_stdin(stdin, "tool") do
      {:ok, params} ->
        case Internal.call_tool(
               state.plugin,
               name,
               ensure_string_keyed(params),
               call_opts(state)
             ) do
          {:ok, text} -> {:ok, text, %{tool_name: name}}
          {:error, msg} -> {:error, msg, %{tool_name: name}}
        end

      {:error, msg} ->
        {:error, msg, %{tool_name: name}}
    end
  end

  defp read_opts(%{conn: nil}), do: []
  defp read_opts(%{conn: conn}), do: [conn: conn]

  defp call_opts(%{conn: nil}), do: []
  defp call_opts(%{conn: conn}), do: [conn: conn]

  defp llm_body(step, stdin, state) do
    case decode_json_stdin(stdin, "llm") do
      {:ok, ctx} -> run_llm_loop(step, ctx, state)
      {:error, msg} -> {:error, msg, %{}}
    end
  end

  # ── shell execution ────────────────────────────────────────────────────────

  # Runs `/bin/sh -c <cmd>` with stdin piped via a temp file. Two modes:
  #
  #  * **setsid present** (Linux prod): wrap via `setsid` so the shell
  #    becomes a session leader (PGID == PID). A sidecar process
  #    monitors the runner; if the runner dies abnormally (timeout,
  #    cancel, crash), the sidecar sends SIGTERM then SIGKILL to the
  #    whole process group, taking down any backgrounded children.
  #  * **setsid absent** (macOS dev): direct `/bin/sh` invocation.
  #    BEAM closes the Port on Task death → SIGTERM to the direct
  #    shell child only. Grandchildren may orphan; document in the
  #    pipelines section of the README.
  #
  # Runs inline (no internal timeout). Per-step timeout is handled by
  # `with_step_timer/3` which exits the runner with `{:step_timeout, idx}`.
  defp shell_exec(cmd, stdin, workdir, env) do
    stdin_path = Path.join(workdir, ".sark_stdin")
    File.write!(stdin_path, stdin)
    shell_cmd = ~s|(#{cmd}) < #{escape_sh(stdin_path)}|

    case setsid_path() do
      nil -> shell_exec_simple(shell_cmd, workdir, env)
      setsid -> shell_exec_setsid(setsid, shell_cmd, workdir, env)
    end
  end

  defp shell_exec_simple(shell_cmd, workdir, env) do
    try do
      {stdout, code} =
        System.cmd("/bin/sh", ["-c", shell_cmd],
          cd: workdir,
          env: env_to_pairs(env),
          stderr_to_stdout: true
        )

      case code do
        0 -> {:ok, stdout, 0}
        _ -> {:error, "exit code #{code}", code, tail(stdout, 4_096)}
      end
    catch
      kind, reason ->
        {:error, "exec error: #{inspect({kind, reason})}", nil, ""}
    end
  end

  defp shell_exec_setsid(setsid, shell_cmd, workdir, env) do
    port_opts = [
      :binary,
      :exit_status,
      :hide,
      :stderr_to_stdout,
      {:cd, workdir},
      {:args, ["/bin/sh", "-c", shell_cmd]},
      {:env, env_to_charlist_pairs(env)}
    ]

    port = Port.open({:spawn_executable, String.to_charlist(setsid)}, port_opts)
    {:os_pid, pgid} = Port.info(port, :os_pid)

    cleaner = start_pgid_cleaner(self(), pgid)

    try do
      collect_port_output(port, "")
    after
      send(cleaner, :done)
    end
  end

  # Sidecar: monitors the runner. On abnormal :DOWN it SIGTERMs the
  # process group then SIGKILLs after a grace period. On :done message
  # (clean step completion) it exits without signalling.
  defp start_pgid_cleaner(runner_pid, pgid) do
    spawn(fn ->
      ref = Process.monitor(runner_pid)

      receive do
        :done ->
          Process.demonitor(ref, [:flush])
          :ok

        {:DOWN, ^ref, :process, _, _} ->
          :os.cmd(~c"kill -TERM -" ++ Integer.to_charlist(pgid))
          Process.sleep(100)
          :os.cmd(~c"kill -KILL -" ++ Integer.to_charlist(pgid))
      end
    end)
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, chunk}} ->
        collect_port_output(port, acc <> chunk)

      {^port, {:exit_status, 0}} ->
        {:ok, acc, 0}

      {^port, {:exit_status, code}} ->
        {:error, "exit code #{code}", code, tail(acc, 4_096)}
    end
  end

  @setsid_key {__MODULE__, :setsid_path}

  # Cached lookup of the `setsid` binary. Returns the path string on
  # systems that have it (Linux prod) or nil (macOS dev w/o
  # util-linux).
  defp setsid_path do
    case :persistent_term.get(@setsid_key, :unset) do
      :unset ->
        path = System.find_executable("setsid")
        :persistent_term.put(@setsid_key, path)
        path

      cached ->
        cached
    end
  end

  defp env_to_pairs(env_map) do
    Enum.map(env_map, fn {k, v} -> {k, v} end)
  end

  defp env_to_charlist_pairs(env_map) do
    Enum.map(env_map, fn {k, v} ->
      {String.to_charlist(k), String.to_charlist(v)}
    end)
  end

  defp escape_sh(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp tail(s, n) when byte_size(s) <= n, do: s
  defp tail(s, n), do: binary_part(s, byte_size(s) - n, n)

  # ── load + tool helpers ────────────────────────────────────────────────────

  defp decode_json_stdin("", _kind), do: {:ok, %{}}
  defp decode_json_stdin(nil, _kind), do: {:ok, %{}}

  defp decode_json_stdin(stdin, kind) when is_binary(stdin) do
    case Jason.decode(stdin) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = err} ->
        preview = stdin |> String.slice(0, 80) |> String.replace(~r/\s+/, " ")

        {:error,
         "expected JSON on stdin for #{kind} step (got '#{preview}'): #{Exception.message(err)}"}
    end
  end

  defp bind_load_params(_step, ctx) when not is_map(ctx) do
    {:error, "load step expects a JSON object on stdin, got #{inspect_short(ctx)}"}
  end

  defp bind_load_params(step, ctx) do
    binds =
      Enum.map(step.param_order, fn name ->
        case Map.fetch(ctx, Atom.to_string(name)) do
          {:ok, v} -> v
          :error -> nil
        end
      end)

    {:ok, binds}
  end

  defp ensure_string_keyed(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {k, v}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp ensure_string_keyed(other), do: other

  defp inspect_short(v), do: v |> inspect() |> String.slice(0, 60)

  # ── llm step ───────────────────────────────────────────────────────────────

  defp run_llm_loop(step, ctx, state) do
    rendered_prompt = Template.render(step.prompt, ctx)
    tools = Internal.tools_for(state.spec, step.tools)
    initial = [%{role: :user, content: rendered_prompt}]

    loop_state = %{
      plugin: state.plugin,
      run_id: state.run_id,
      conn: state.conn,
      step: step,
      llm: state.llm,
      tools: tools,
      max_tokens: state.max_tokens,
      on_event: state.on_event,
      usage: nil,
      last_text: ""
    }

    case llm_loop(loop_state, initial, 1) do
      {:stop, %{turns: turns, reason: reason, usage: usage, text: text}} ->
        {:ok, text, llm_extras(step.model, turns, reason, usage, text)}

      {:abort, %{turns: turns, reason: reason, usage: usage, text: text}} ->
        {:error, "llm: #{format_llm_reason(reason)}",
         llm_extras(step.model, turns, reason, usage, text)}
    end
  end

  defp llm_loop(%{step: %{max_turns: cap}} = state, _messages, turn) when turn > cap do
    {:abort,
     %{
       reason: :max_turns_exceeded,
       turns: cap,
       usage: state.usage,
       text: state.last_text
     }}
  end

  defp llm_loop(state, messages, turn) do
    chat_opts = %{
      model: state.step.model,
      system: state.step.system,
      messages: messages,
      tools: state.tools,
      max_tokens: state.max_tokens
    }

    case state.llm.chat(chat_opts) do
      {:ok, %Response{} = resp} ->
        new_usage = Sark.Pipeline.Log.accumulate_usage(state.usage, resp.usage)

        state = %{
          state
          | usage: new_usage,
            last_text: response_text_or_keep(resp, state.last_text)
        }

        text = Response.text(resp)
        if text != "", do: state.on_event.({:assistant_text, text})

        case Response.tool_uses(resp) do
          [] ->
            {:stop,
             %{
               reason: resp.stop_reason,
               turns: turn,
               usage: state.usage,
               text: state.last_text
             }}

          tool_uses ->
            assistant_msg = %{role: :assistant, content: resp.content}

            case dispatch_tool_calls(state.plugin, state.conn, tool_uses, state.on_event) do
              {:ok, result_blocks} ->
                user_msg = %{role: :user, content: result_blocks}
                next = messages ++ [assistant_msg, user_msg]
                llm_loop(state, next, turn + 1)

              {:error, reason} ->
                {:abort,
                 %{reason: reason, turns: turn, usage: state.usage, text: state.last_text}}
            end
        end

      {:error, reason} ->
        {:abort,
         %{
           reason: {:llm_error, reason},
           turns: turn,
           usage: state.usage,
           text: state.last_text
         }}
    end
  end

  defp response_text_or_keep(%Response{} = resp, prior) do
    case Response.text(resp) do
      "" -> prior
      t -> t
    end
  end

  defp dispatch_tool_calls(plugin, conn, tool_uses, on_event) do
    opts = if conn, do: [conn: conn], else: []

    Enum.reduce_while(tool_uses, {:ok, []}, fn tu, {:ok, acc} ->
      on_event.({:tool_call, %{id: tu.id, name: tu.name, input: tu.input}})

      case Internal.call_tool(plugin, tu.name, tu.input || %{}, opts) do
        {:ok, text} ->
          on_event.({:tool_result, %{id: tu.id, ok: true, text: text}})

          block = %{
            type: :tool_result,
            tool_use_id: tu.id,
            content: text,
            is_error: false
          }

          {:cont, {:ok, acc ++ [block]}}

        {:error, msg} ->
          on_event.({:tool_result, %{id: tu.id, ok: false, text: msg}})

          block = %{
            type: :tool_result,
            tool_use_id: tu.id,
            content: msg,
            is_error: true
          }

          {:cont, {:ok, acc ++ [block]}}
      end
    end)
  end

  defp llm_extras(model, turns, reason, usage, text) do
    %{
      model: model,
      turns: turns,
      stop_reason: stop_reason_to_text(reason),
      input_tokens: usage && usage[:input_tokens],
      output_tokens: usage && usage[:output_tokens],
      cache_read_tokens: usage && usage[:cache_read_tokens],
      cache_creation_tokens: usage && usage[:cache_creation_tokens],
      service_tier: usage && usage[:service_tier],
      final_output: nil_if_blank(text)
    }
  end

  defp stop_reason_to_text(:end_turn), do: "end_turn"
  defp stop_reason_to_text(:max_tokens), do: "max_tokens"
  defp stop_reason_to_text(:stop_sequence), do: "stop_sequence"
  defp stop_reason_to_text(:max_turns_exceeded), do: "max_turns_exceeded"
  defp stop_reason_to_text({:llm_error, _}), do: "error"
  defp stop_reason_to_text(other), do: inspect(other)

  defp format_llm_reason(:max_turns_exceeded), do: "max_turns_exceeded"
  defp format_llm_reason({:llm_error, r}), do: "provider error: #{inspect(r)}"
  defp format_llm_reason(other), do: inspect(other)

  # ── workdir helpers ────────────────────────────────────────────────────────

  defp ensure_workdir!(plugin, pipeline, run_id) do
    base = pipeline.workdir || Path.join(["/tmp", "sark", plugin, Atom.to_string(pipeline.name)])
    full = Path.join(base, run_id)
    File.mkdir_p!(full)
    full
  end

  defp cleanup_workdir(path) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, reason, file} ->
        Logger.warning("pipeline: failed to clean workdir #{file}: #{inspect(reason)}")
        :ok
    end
  end

  # ── env sourcing ───────────────────────────────────────────────────────────

  defp sourced_env(names) do
    Enum.into(names, %{}, fn name ->
      {name, System.get_env(name) || ""}
    end)
  end

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
