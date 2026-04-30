defmodule Sark.Worker.Runner do
  @moduledoc """
  Drives one worker conversation to completion.

  Order of operations:

    1. **`when:` gate** — if defined, run as a SELECT against the read
       pool. Empty result set → return `{:ok, :skipped}` (no LLM call,
       no log row). One or more rows → continue.
    2. **`load:` context** — if defined, run as a SELECT against the
       read pool. Rows feed `Sark.Worker.Template.render/2` to produce
       the final user prompt; otherwise the raw prompt is used.
    3. **Loop** — send the message list + tool schemas to the LLM,
       dispatch tool_use blocks via `Sark.MCP.Internal`, append
       tool_result blocks, repeat. Stops on `:end_turn`, `:max_tokens`,
       max-turn cap, or any tool dispatch error.
    4. **Log** — every terminal state inserts a row into the plugin's
       `_worker_log` table. `when:`-skipped runs do not log.

  Streams progress to a callback (`on_event`) so the mix task can
  print transcripts in real time without coupling the runner to IO.
  """

  alias Sark.MCP.Internal
  alias Sark.Plugin.DB
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Worker
  alias Sark.Worker.LLM.Response
  alias Sark.Worker.Log
  alias Sark.Worker.Template

  @type event ::
          {:turn_start, pos_integer}
          | {:assistant_text, String.t()}
          | {:tool_call, %{id: String.t(), name: String.t(), input: map}}
          | {:tool_result, %{id: String.t(), ok: boolean, text: String.t()}}
          | {:stop, %{reason: term, turns: pos_integer}}
          | {:abort, %{reason: term, turns: pos_integer}}
          | {:skipped, %{reason: :when_gate}}
          | {:loaded, %{rows: non_neg_integer}}

  @type opts :: [
          plugin: String.t(),
          worker: Worker.t(),
          spec: Spec.t(),
          llm: module,
          on_event: (event -> any),
          max_tokens: pos_integer
        ]

  @default_max_tokens 4096

  @spec run(opts) ::
          {:ok, %{turns: pos_integer, stop_reason: term}}
          | {:ok, :skipped}
          | {:error, term}
  def run(opts) do
    plugin = Keyword.fetch!(opts, :plugin)
    %Worker{} = worker = Keyword.fetch!(opts, :worker)
    %Spec{} = spec = Keyword.fetch!(opts, :spec)
    llm = Keyword.fetch!(opts, :llm)
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    started_at = now_iso8601()

    case evaluate_when(plugin, worker.when_sql) do
      :skip ->
        on_event.({:skipped, %{reason: :when_gate}})
        {:ok, :skipped}

      {:run, _} ->
        case render_prompt(plugin, worker, on_event) do
          {:ok, rendered_prompt} ->
            tools = Internal.tools_for(spec, worker.tools)
            initial = [%{role: :user, content: rendered_prompt}]

            state = %{
              plugin: plugin,
              worker: worker,
              llm: llm,
              tools: tools,
              max_tokens: max_tokens,
              on_event: on_event,
              usage: nil,
              last_text: "",
              started_at: started_at
            }

            outcome = loop(state, initial, 1)
            log_run(state, outcome)
            unwrap(outcome)

          {:error, reason} = err ->
            log_run(
              %{
                plugin: plugin,
                worker: worker,
                llm: llm,
                started_at: started_at,
                usage: nil,
                last_text: ""
              },
              {:abort, %{reason: {:load_failed, reason}, turns: 0, usage: nil, text: ""}}
            )

            err
        end

      {:error, reason} = err ->
        log_run(
          %{
            plugin: plugin,
            worker: worker,
            llm: llm,
            started_at: started_at,
            usage: nil,
            last_text: ""
          },
          {:abort, %{reason: {:when_failed, reason}, turns: 0, usage: nil, text: ""}}
        )

        err
    end
  end

  # ── when gate ───────────────────────────────────────────────────────

  defp evaluate_when(_plugin, nil), do: {:run, []}

  defp evaluate_when(plugin, sql) when is_binary(sql) do
    case DB.read(plugin, sql, []) do
      {:ok, _cols, []} -> :skip
      {:ok, _cols, rows} -> {:run, rows}
      {:error, _} = err -> err
    end
  end

  # ── load + render ───────────────────────────────────────────────────

  defp render_prompt(_plugin, %Worker{load_sql: nil} = w, _on_event), do: {:ok, w.prompt}

  defp render_prompt(plugin, %Worker{load_sql: sql, prompt: tpl}, on_event) do
    case DB.read(plugin, sql, []) do
      {:ok, _cols, rows} ->
        on_event.({:loaded, %{rows: length(rows)}})
        {:ok, Template.render(tpl, rows)}

      {:error, _} = err ->
        err
    end
  end

  # ── loop ────────────────────────────────────────────────────────────

  defp loop(%{worker: %Worker{max_turns: cap}} = state, _msgs, turn) when turn > cap do
    state.on_event.({:abort, %{reason: :max_turns_exceeded, turns: cap}})

    {:abort,
     %{
       reason: :max_turns_exceeded,
       turns: cap,
       usage: state.usage,
       text: state.last_text
     }}
  end

  defp loop(state, messages, turn) do
    state.on_event.({:turn_start, turn})

    chat_opts = %{
      model: state.worker.model,
      system: state.worker.system,
      messages: messages,
      tools: state.tools,
      max_tokens: state.max_tokens
    }

    case state.llm.chat(chat_opts) do
      {:ok, %Response{} = resp} ->
        state = %{
          state
          | usage: Log.accumulate_usage(state.usage, resp.usage),
            last_text: response_text_or_keep(resp, state.last_text)
        }

        text = Response.text(resp)
        if text != "", do: state.on_event.({:assistant_text, text})

        case Response.tool_uses(resp) do
          [] ->
            state.on_event.({:stop, %{reason: resp.stop_reason, turns: turn}})

            {:stop,
             %{
               reason: resp.stop_reason,
               turns: turn,
               usage: state.usage,
               text: state.last_text
             }}

          tool_uses ->
            assistant_msg = %{role: :assistant, content: resp.content}

            case dispatch_all(state.plugin, tool_uses, state.on_event) do
              {:ok, result_blocks} ->
                user_msg = %{role: :user, content: result_blocks}
                next = messages ++ [assistant_msg, user_msg]
                loop(state, next, turn + 1)

              {:error, reason} ->
                state.on_event.({:abort, %{reason: reason, turns: turn}})

                {:abort,
                 %{
                   reason: reason,
                   turns: turn,
                   usage: state.usage,
                   text: state.last_text
                 }}
            end
        end

      {:error, reason} ->
        state.on_event.({:abort, %{reason: {:llm_error, reason}, turns: turn}})

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

  defp dispatch_all(plugin, tool_uses, on_event) do
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

  # ── logging ─────────────────────────────────────────────────────────

  defp log_run(state, outcome) do
    {kind, info} = outcome
    usage = info[:usage] || state.usage

    entry = %{
      worker_name: Atom.to_string(state.worker.name),
      provider: provider_name(state.llm),
      model: state.worker.model,
      started_at: state.started_at,
      ended_at: now_iso8601(),
      turns: info[:turns],
      stop_reason: stop_reason_to_text(kind, info[:reason]),
      input_tokens: usage && usage[:input_tokens],
      output_tokens: usage && usage[:output_tokens],
      cache_read_tokens: usage && usage[:cache_read_tokens],
      cache_creation_tokens: usage && usage[:cache_creation_tokens],
      service_tier: usage && usage[:service_tier],
      error: error_text(kind, info[:reason]),
      final_output: nil_if_blank(info[:text] || state.last_text)
    }

    case Log.record(state.plugin, entry) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.error(
          "worker log insert failed for #{state.plugin}.#{state.worker.name}: #{inspect(reason)}"
        )
    end
  end

  # `:stop` carries an Anthropic-style atom (:end_turn / :max_tokens / :stop_sequence).
  # `:abort` carries our internal categories (:max_turns_exceeded / anything else → :error).
  defp stop_reason_to_text(:stop, :end_turn), do: "end_turn"
  defp stop_reason_to_text(:stop, :max_tokens), do: "max_tokens"
  defp stop_reason_to_text(:stop, :stop_sequence), do: "stop_sequence"
  defp stop_reason_to_text(:stop, _other), do: "end_turn"
  defp stop_reason_to_text(:abort, :max_turns_exceeded), do: "max_turns_exceeded"
  defp stop_reason_to_text(:abort, _), do: "error"

  defp error_text(:stop, _), do: nil
  defp error_text(:abort, :max_turns_exceeded), do: nil
  defp error_text(:abort, reason), do: inspect(reason)

  defp provider_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.downcase()
  end

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # ── outcome → public return ─────────────────────────────────────────

  defp unwrap({:stop, %{reason: r, turns: t}}), do: {:ok, %{turns: t, stop_reason: r}}
  defp unwrap({:abort, %{reason: r}}), do: {:error, r}
end
