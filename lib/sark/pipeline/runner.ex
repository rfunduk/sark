defmodule Sark.Pipeline.Runner do
  @moduledoc """
  Drives one pipeline to terminal state — schedules steps, captures
  their stdout, threads it as stdin to the next, writes `_pipeline_log`
  + `_pipeline_step_log` rows, cleans up the workdir.

  Order of operations:

    1. `when:` gate — if defined, run a SELECT on the read pool. Empty
       result set → return `{:ok, :skipped}` (no log row, mirrors the
       legacy worker behaviour).
    2. Prepare workdir at `/tmp/sark/{plugin}/{pipeline}/{run_id}/`
       (or the pipeline's `workdir:` override).
    3. For each step in order, execute and capture output. Output of
       step N becomes stdin of step N+1. First step receives no stdin.
    4. On any step failure, abort — remaining steps are skipped, the
       run is marked failed, and a step log row records the failure.
    5. Log terminal state, then clean up the workdir on success
       (kept on failure for debug).

  Pipe convention:
    * `shell:` → emits raw bytes; consumes raw bytes
    * `load:` / `tool:` / `llm:` → consume JSON on stdin; emit a
      string (JSON rows array / tool reply text / final assistant text)

  Steps that consume JSON on stdin (`load:` / `tool:` / `llm:`) parse
  it once; non-JSON input errors with a clear step-level message.

  The runner streams progress to `on_event` so the mix task can print
  transcripts in real time without coupling the runner to IO.
  """

  require Logger

  alias Sark.LLM.Response
  alias Sark.MCP.Internal
  alias Sark.Plugin.DB
  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Spec
  alias Sark.Pipeline.Log
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
        record_failed_run(plugin, run_id, pipeline, triggered_by, "when_gate: #{inspect(reason)}")
        {:error, {:when_failed, reason}}

      {:run, _} ->
        do_run(plugin, pipeline, spec, run_id, llm, triggered_by, on_event, max_tokens)
    end
  end

  defp do_run(plugin, pipeline, spec, run_id, llm, triggered_by, on_event, max_tokens) do
    started_at = now_iso8601()

    on_event.({:run_start, %{run_id: run_id, pipeline: pipeline.name}})

    :ok =
      Log.start_run(plugin, %{
        run_id: run_id,
        pipeline: pipeline.name,
        started_at: started_at,
        triggered_by: triggered_by
      })

    workdir = ensure_workdir!(plugin, pipeline, run_id)
    env = sourced_env(pipeline.env)

    state = %{
      plugin: plugin,
      pipeline: pipeline,
      spec: spec,
      run_id: run_id,
      llm: llm,
      max_tokens: max_tokens,
      on_event: on_event,
      workdir: workdir,
      env: env,
      started_at: started_at
    }

    case run_steps(state) do
      :ok ->
        :ok = Log.finish_run(plugin, run_id, :success, now_iso8601(), nil)
        cleanup_workdir(workdir)
        on_event.({:run_ok, %{run_id: run_id}})
        {:ok, %{run_id: run_id}}

      {:error, msg} ->
        :ok = Log.finish_run(plugin, run_id, :failed, now_iso8601(), msg)
        # workdir preserved on failure for debug
        on_event.({:run_fail, %{run_id: run_id, error: msg}})
        {:error, msg}
    end
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
      state.on_event.({:step_start, %{index: idx, kind: step.kind}})
      started_at = now_iso8601()

      case run_step(step, stdin, state) do
        {:ok, stdout, extras} ->
          :ok =
            Log.record_step(
              state.plugin,
              base_step_entry(state.run_id, idx, step.kind, started_at, :success, nil)
              |> Map.put(:stdout_bytes, byte_size(stdout))
              |> Map.merge(extras)
            )

          state.on_event.({:step_ok, %{index: idx, kind: step.kind, bytes: byte_size(stdout)}})
          {:cont, {:ok, stdout}}

        {:error, msg, extras} ->
          :ok =
            Log.record_step(
              state.plugin,
              base_step_entry(state.run_id, idx, step.kind, started_at, :failed, msg)
              |> Map.merge(extras)
            )

          state.on_event.({:step_fail, %{index: idx, kind: step.kind, error: msg}})
          {:halt, {:error, "step #{idx} (#{step.kind}): #{msg}"}}
      end
    end)
    |> case do
      {:ok, _final_stdout} -> :ok
      {:error, _} = err -> err
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

  # Per-step `timeout:` takes precedence over the pipeline-level
  # `timeout:`. nil = no ceiling.
  defp effective_timeout(step, state),
    do: step[:timeout_ms] || state.pipeline.timeout_ms

  defp run_step(%{kind: :shell, cmd: cmd} = step, stdin, state) do
    case shell_exec(cmd, stdin, state.workdir, state.env, effective_timeout(step, state)) do
      {:ok, stdout, exit_code} ->
        {:ok, stdout, %{exit_code: exit_code}}

      {:error, msg, exit_code, stderr_tail} ->
        {:error, msg, %{exit_code: exit_code, stderr_tail: stderr_tail}}
    end
  end

  defp run_step(%{kind: :load} = step, stdin, state) do
    with_step_timeout(effective_timeout(step, state), fn -> load_body(step, stdin, state) end)
  end

  defp run_step(%{kind: :tool, tool: name} = step, stdin, state) do
    with_step_timeout(
      effective_timeout(step, state),
      fn -> tool_body(name, stdin, state) end,
      %{tool_name: name}
    )
  end

  defp run_step(%{kind: :llm} = step, stdin, state) do
    with_step_timeout(effective_timeout(step, state), fn -> llm_body(step, stdin, state) end)
  end

  defp load_body(step, stdin, state) do
    with {:ok, params_map} <- decode_json_stdin(stdin, "load"),
         {:ok, binds} <- bind_load_params(step, params_map),
         {:ok, _cols, rows} <- DB.read(state.plugin, step.compiled_sql, binds) do
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

  defp tool_body(name, stdin, state) do
    case decode_json_stdin(stdin, "tool") do
      {:ok, params} ->
        case Internal.call_tool(state.plugin, name, ensure_string_keyed(params)) do
          {:ok, text} -> {:ok, text, %{tool_name: name}}
          {:error, msg} -> {:error, msg, %{tool_name: name}}
        end

      {:error, msg} ->
        {:error, msg, %{tool_name: name}}
    end
  end

  defp llm_body(step, stdin, state) do
    case decode_json_stdin(stdin, "llm") do
      {:ok, ctx} -> run_llm_loop(step, ctx, state)
      {:error, msg} -> {:error, msg, %{}}
    end
  end

  # Wrap a step body in a Task so we can apply a timeout. nil = no
  # ceiling (just run inline — avoids spawning a task for the common
  # case where authors don't set a timeout).
  defp with_step_timeout(ms, fun, extras_on_timeout \\ %{})
  defp with_step_timeout(nil, fun, _extras), do: fun.()

  defp with_step_timeout(ms, fun, extras_on_timeout) when is_integer(ms) and ms > 0 do
    task = Task.async(fun)

    case Task.yield(task, ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, "timeout after #{ms}ms", extras_on_timeout}
    end
  end

  # ── shell execution ────────────────────────────────────────────────────────

  # Uses System.cmd with stdin piped via a temp file inside the workdir.
  # Avoids the Erlang Port "can't half-close stdin" problem; the temp file
  # is wiped along with the workdir on success.
  defp shell_exec(cmd, stdin, workdir, env, timeout_ms) do
    stdin_path = Path.join(workdir, ".sark_stdin")
    File.write!(stdin_path, stdin)

    shell_cmd = ~s|(#{cmd}) < #{escape_sh(stdin_path)}|

    task =
      Task.async(fn ->
        try do
          System.cmd("/bin/sh", ["-c", shell_cmd],
            cd: workdir,
            env: env_to_pairs(env),
            stderr_to_stdout: true
          )
        catch
          kind, reason -> {:exec_error, kind, reason}
        end
      end)

    case yield_with_timeout(task, timeout_ms) do
      {:done, {stdout, 0}} ->
        {:ok, stdout, 0}

      {:done, {stdout, code}} when is_integer(code) ->
        {:error, "exit code #{code}", code, tail(stdout, 4_096)}

      {:done, {:exec_error, kind, reason}} ->
        {:error, "exec error: #{inspect({kind, reason})}", nil, ""}

      :timeout ->
        Task.shutdown(task, :brutal_kill)
        {:error, "timeout after #{timeout_ms}ms", nil, ""}
    end
  end

  defp yield_with_timeout(task, nil), do: {:done, Task.await(task, :infinity)}

  defp yield_with_timeout(task, ms) when is_integer(ms) and ms > 0 do
    case Task.yield(task, ms) do
      {:ok, result} -> {:done, result}
      nil -> :timeout
    end
  end

  defp env_to_pairs(env_map) do
    Enum.map(env_map, fn {k, v} -> {k, v} end)
  end

  defp escape_sh(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp tail(s, n) when byte_size(s) <= n, do: s
  defp tail(s, n), do: binary_part(s, byte_size(s) - n, n)

  # ── load + tool helpers ────────────────────────────────────────────────────

  # Empty stdin → empty context map. Otherwise decode JSON. Strings on
  # stdin that aren't a JSON object/array (e.g. shell output that wasn't
  # piped through jq) error with a clear message at this boundary.
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

            case dispatch_tool_calls(state.plugin, tool_uses, state.on_event) do
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

  defp dispatch_tool_calls(plugin, tool_uses, on_event) do
    Enum.reduce_while(tool_uses, {:ok, []}, fn tu, {:ok, acc} ->
      on_event.({:tool_call, %{id: tu.id, name: tu.name, input: tu.input}})

      case Internal.call_tool(plugin, tu.name, tu.input || %{}) do
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

  # ── misc ───────────────────────────────────────────────────────────────────

  defp record_failed_run(plugin, run_id, pipeline, triggered_by, msg) do
    now = now_iso8601()

    :ok =
      Log.start_run(plugin, %{
        run_id: run_id,
        pipeline: pipeline.name,
        started_at: now,
        triggered_by: triggered_by
      })

    Log.finish_run(plugin, run_id, :failed, now, msg)
  end

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
